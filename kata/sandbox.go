package kata

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hashicorp/go-hclog"
)

// Sandbox tracks a running Kata VM that hosts one or more containers.
type Sandbox struct {
	ID           string
	AllocID      string
	refCount     atomic.Int32
	cleanupTimer *time.Timer
	cleaning     bool
}

// SandboxManager maintains the mapping from allocation ID to Kata VM sandbox.
type SandboxManager struct {
	mu           sync.Mutex
	sandboxes    map[string]*Sandbox
	ctr          Containerd
	logger       hclog.Logger
	cleanupDelay time.Duration
}

func NewSandboxManager(ctr Containerd, logger hclog.Logger, cleanupDelay time.Duration) *SandboxManager {
	return &SandboxManager{
		sandboxes:    make(map[string]*Sandbox),
		ctr:          ctr,
		logger:       logger.Named("sandbox"),
		cleanupDelay: cleanupDelay,
	}
}

func sandboxID(allocID string) string {
	return fmt.Sprintf("kata-%s-sandbox", allocID)
}

// GetOrCreate returns an existing sandbox for the allocation or boots a new
// Kata VM. The caller must eventually call Release for each GetOrCreate.
func (sm *SandboxManager) GetOrCreate(ctx context.Context, allocID, pauseImage, runtime, netNS, hostname string) (*Sandbox, error) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	if sb, ok := sm.sandboxes[allocID]; ok {
		if sb.cleaning {
			return nil, fmt.Errorf("sandbox %s is being cleaned up", sb.ID)
		}
		if sb.cleanupTimer != nil {
			sb.cleanupTimer.Stop()
			sb.cleanupTimer = nil
		}
		sb.refCount.Add(1)
		sm.logger.Info("reusing sandbox", "alloc_id", allocID, "sandbox_id", sb.ID, "refs", sb.refCount.Load())
		return sb, nil
	}

	id := sandboxID(allocID)
	sm.logger.Info("creating sandbox VM", "alloc_id", allocID, "sandbox_id", id)

	if err := sm.ctr.EnsureImage(ctx, pauseImage, false, "", ""); err != nil {
		return nil, fmt.Errorf("ensuring pause image: %w", err)
	}

	if err := sm.ctr.CreateContainer(ctx, &ContainerConfig{
		ID:       id,
		Image:    pauseImage,
		Runtime:  runtime,
		NetNS:    netNS,
		Hostname: hostname,
		Annotations: map[string]string{
			"io.kubernetes.cri-o.ContainerType": "sandbox",
		},
	}); err != nil {
		return nil, fmt.Errorf("creating sandbox container: %w", err)
	}

	if err := sm.ctr.CreateSandboxMetadata(ctx, id, runtime); err != nil {
		sm.ctr.DeleteContainer(ctx, id)
		return nil, fmt.Errorf("creating sandbox metadata: %w", err)
	}

	if err := sm.ctr.StartTaskDetached(ctx, id); err != nil {
		sm.ctr.DeleteSandboxMetadata(ctx, id)
		sm.ctr.DeleteContainer(ctx, id)
		return nil, fmt.Errorf("starting sandbox: %w", err)
	}

	sb := &Sandbox{ID: id, AllocID: allocID}
	sb.refCount.Store(1)
	sm.sandboxes[allocID] = sb

	sm.logger.Info("sandbox VM running", "alloc_id", allocID, "sandbox_id", id)
	return sb, nil
}

// Release decrements the sandbox reference count and schedules VM teardown
// when no more tasks are using it. The delay lets Nomad start poststop tasks
// inside the allocation's existing VM.
func (sm *SandboxManager) Release(_ context.Context, sandbox *Sandbox) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	sb, ok := sm.sandboxes[sandbox.AllocID]
	if !ok || sb != sandbox {
		return
	}

	remaining := sb.refCount.Add(-1)
	if remaining > 0 {
		sm.logger.Info("sandbox still in use", "alloc_id", sandbox.AllocID, "refs", remaining)
		return
	}

	if sm.cleanupDelay <= 0 {
		sm.cleanupLocked(sandbox, sb)
		return
	}

	sm.logger.Info("scheduling sandbox VM cleanup", "alloc_id", sandbox.AllocID, "sandbox_id", sb.ID, "delay", sm.cleanupDelay)
	sb.cleanupTimer = time.AfterFunc(sm.cleanupDelay, func() {
		sm.cleanup(sandbox, sb)
	})
}

func (sm *SandboxManager) cleanup(sandbox, expected *Sandbox) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.cleanupLocked(sandbox, expected)
}

func (sm *SandboxManager) cleanupLocked(sandbox, expected *Sandbox) {
	sb, ok := sm.sandboxes[sandbox.AllocID]
	if !ok || sb != sandbox || sb != expected || sb.refCount.Load() != 0 {
		return
	}

	if sb.cleaning {
		return
	}
	sb.cleaning = true
	sm.mu.Unlock()
	ctx := context.Background()
	sm.logger.Info("destroying sandbox VM", "alloc_id", sandbox.AllocID, "sandbox_id", sb.ID)
	err := sm.ctr.Cleanup(ctx, sb.ID)
	if err == nil {
		err = sm.ctr.DeleteSandboxMetadata(ctx, sb.ID)
	}
	sm.mu.Lock()
	if err != nil {
		sm.logger.Error("sandbox cleanup failed; allocation remains fenced", "alloc_id", sandbox.AllocID, "sandbox_id", sb.ID, "error", err)
		return
	}
	delete(sm.sandboxes, sandbox.AllocID)
}

// Recover rebuilds sandbox state from a recovered task handle, without
// creating anything in containerd. Used after driver restart.
func (sm *SandboxManager) Recover(allocID, sbID string) *Sandbox {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	if sb, ok := sm.sandboxes[allocID]; ok {
		if sb.cleaning {
			return nil
		}
		if sb.cleanupTimer != nil {
			sb.cleanupTimer.Stop()
			sb.cleanupTimer = nil
		}
		sb.refCount.Add(1)
		return sb
	}

	sb := &Sandbox{ID: sbID, AllocID: allocID}
	sb.refCount.Store(1)
	sm.sandboxes[allocID] = sb
	sm.logger.Info("recovered sandbox", "alloc_id", allocID, "sandbox_id", sbID)
	return sb
}
