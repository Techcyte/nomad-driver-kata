package kata

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/hashicorp/go-hclog"
)

type failedSignal struct {
	Containerd
}

func (c *failedSignal) KillTask(ctx context.Context, id, signal string) error {
	return context.DeadlineExceeded
}

func TestStopTaskReportsFailedForceKill(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	if _, _, err := d.StartTask(cfg); err != nil {
		t.Fatal(err)
	}
	d.ctr = &failedSignal{Containerd: rec}
	if err := d.StopTask(cfg.ID, 0, "SIGTERM"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("StopTask = %v, want signal failure", err)
	}
}

type failedSandboxStart struct {
	Containerd
}

func (c *failedSandboxStart) StartTaskDetached(ctx context.Context, id string) error {
	return errors.New("sandbox start rejected")
}

func TestFailedSandboxStartRetainsFailedCleanup(t *testing.T) {
	rec := newRecorder()
	mgr := NewSandboxManager(&failedSandboxStart{Containerd: &failedCleanup{Containerd: rec}}, hclog.NewNullLogger(), 0)
	mgr.stateDir = t.TempDir()
	if _, err := mgr.GetOrCreate(context.Background(), "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "", nil); err == nil {
		t.Fatal("sandbox startup succeeded")
	}
	if !mgr.cleanupPending("alloc-1") {
		t.Fatal("failed sandbox-start cleanup did not persist fence")
	}
	if rec.called("DeleteSandboxMetadata") {
		t.Fatal("failed sandbox-start cleanup deleted metadata")
	}
}

func TestFailedStartupReportsCleanupFailure(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	d.sandboxMgr.stateDir = d.stateDir
	failure := errors.New("start rejected")
	c := &startupContainerd{Containerd: &failedCleanup{Containerd: rec}, entered: make(chan struct{}), release: make(chan struct{}), err: failure}
	close(c.release)
	// The previous-attempt cleanup succeeds; the failed-start cleanup fails.
	d.ctr = &startupCleanup{Containerd: c}
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	_, _, err := d.StartTask(cfg)
	if !errors.Is(err, failure) || !d.sandboxMgr.cleanupPending(cfg.AllocID) {
		t.Fatalf("startup error = %v; failed cleanup must fence allocation", err)
	}
}

type startupCleanup struct {
	Containerd
	calls int
}

func (c *startupCleanup) Cleanup(ctx context.Context, id string) error {
	c.calls++
	if c.calls == 1 {
		return nil
	}
	return c.Containerd.Cleanup(ctx, id)
}

func TestMarkSandboxDeadPreservesMetadataOnCleanupFailure(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	d.ctr = &failedCleanup{Containerd: rec}
	if err := d.markSandboxDead("alloc-1"); err == nil {
		t.Fatal("sandbox death hid runtime cleanup failure")
	}
	if !d.sandboxDead("alloc-1") {
		t.Fatal("failed cleanup lost dead sandbox marker")
	}
	if rec.called("DeleteSandboxMetadata") {
		t.Fatal("failed runtime cleanup deleted sandbox metadata")
	}
}

func TestSandboxCleanupClearsFenceAfterSuccess(t *testing.T) {
	mgr := NewSandboxManager(newRecorder(), hclog.NewNullLogger(), 0)
	mgr.stateDir = t.TempDir()
	sb, err := mgr.GetOrCreate(context.Background(), "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := mgr.Release(context.Background(), sb); err != nil {
		t.Fatal(err)
	}
	if mgr.cleanupPending("alloc-1") {
		t.Fatal("successful cleanup retained fence")
	}
}

func TestSandboxCleanupDoesNotProceedWithoutFence(t *testing.T) {
	rec := newRecorder()
	mgr := NewSandboxManager(rec, hclog.NewNullLogger(), 0)
	mgr.stateDir = t.TempDir()
	sb, err := mgr.GetOrCreate(context.Background(), "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mgr.stateDir, "alloc-1"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := mgr.Release(context.Background(), sb); err == nil {
		t.Fatal("cleanup hid fence persistence failure")
	}
	if rec.called("Cleanup") {
		t.Fatal("runtime teardown started without persistent fence")
	}
}

func TestSandboxReleaseReportsCleanupFailure(t *testing.T) {
	mgr := NewSandboxManager(&failedCleanup{Containerd: newRecorder()}, hclog.NewNullLogger(), 0)
	sb, err := mgr.GetOrCreate(context.Background(), "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := mgr.Release(context.Background(), sb); err == nil {
		t.Fatal("Release hid cleanup failure")
	}
	if err := mgr.Release(context.Background(), sb); err == nil {
		t.Fatal("repeated Release hid incomplete cleanup")
	}
	if sb.refCount.Load() != 0 {
		t.Fatal("repeated release corrupted reference count")
	}
}

func TestSandboxCleanupFenceSurvivesManagerRestart(t *testing.T) {
	rec := newRecorder()
	mgr := NewSandboxManager(&failedCleanup{Containerd: rec}, hclog.NewNullLogger(), 0)
	mgr.stateDir = t.TempDir()
	sb, err := mgr.GetOrCreate(context.Background(), "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	mgr.Release(context.Background(), sb)
	restarted := NewSandboxManager(rec, hclog.NewNullLogger(), 0)
	restarted.stateDir = mgr.stateDir
	if _, err := restarted.GetOrCreate(context.Background(), "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "", nil); err == nil {
		t.Fatal("manager restart allowed reuse after failed cleanup")
	}
	if restarted.Recover("alloc-1", sb.ID) != nil {
		t.Fatal("manager restart allowed recovery after failed cleanup")
	}
}

func TestStartTaskRejectsFailedPreviousCleanup(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	d.ctr = &failedCleanup{Containerd: rec}
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	if handle, _, err := d.StartTask(cfg); err == nil || handle != nil {
		t.Fatalf("StartTask = (%v, %v), want failed cleanup and no handle", handle, err)
	}
	if rec.called("CreateContainer") {
		t.Fatal("created container after failed cleanup")
	}
}

type cleanupDeadline struct {
	Containerd
	bounded bool
}

func (c *cleanupDeadline) Cleanup(ctx context.Context, id string) error {
	_, c.bounded = ctx.Deadline()
	return nil
}

func TestDestroyTaskBoundsCleanup(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	if _, _, err := d.StartTask(cfg); err != nil {
		t.Fatal(err)
	}
	h, _ := d.tasks.Get(cfg.ID)
	<-h.doneCh
	c := &cleanupDeadline{Containerd: rec}
	d.ctr = c
	if err := d.DestroyTask(cfg.ID, false); err != nil {
		t.Fatal(err)
	}
	if !c.bounded {
		t.Fatal("task cleanup was not given a deadline")
	}
}

func TestDestroyTaskRetainsHandleOnCleanupFailure(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	if _, _, err := d.StartTask(cfg); err != nil {
		t.Fatal(err)
	}
	h, _ := d.tasks.Get(cfg.ID)
	<-h.doneCh
	d.ctr = &failedCleanup{Containerd: rec}
	if err := d.DestroyTask(cfg.ID, false); err == nil {
		t.Fatal("DestroyTask hid cleanup failure")
	}
	if _, ok := d.tasks.Get(cfg.ID); !ok {
		t.Fatal("DestroyTask discarded handle after cleanup failure")
	}
	if h.sandbox.refCount.Load() != 1 {
		t.Fatal("DestroyTask released sandbox after cleanup failure")
	}
	d.ctr = rec
	if err := d.DestroyTask(cfg.ID, false); err != nil {
		t.Fatalf("cleanup retry: %v", err)
	}
}
