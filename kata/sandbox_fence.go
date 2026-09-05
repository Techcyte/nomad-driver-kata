package kata

import (
	"fmt"
	"os"
	"path/filepath"
)

func (sm *SandboxManager) fence(sandbox *Sandbox) error {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sandbox.cleaning = true
	return sm.recordCleanup(sandbox.AllocID)
}

func (sm *SandboxManager) cleanupPath(allocID string) string {
	return filepath.Join(sm.stateDir, allocID, "sandbox-cleanup")
}

func (sm *SandboxManager) cleanupPending(allocID string) bool {
	if sm.stateDir == "" {
		return false
	}
	_, err := os.Stat(sm.cleanupPath(allocID))
	return !os.IsNotExist(err)
}

func (sm *SandboxManager) recordCleanup(allocID string) error {
	if sm.stateDir == "" {
		return nil
	}
	path := sm.cleanupPath(allocID)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("creating cleanup state directory: %w", err)
	}
	return os.WriteFile(path, nil, 0600)
}

func (sm *SandboxManager) clearCleanup(allocID string) error {
	if sm.stateDir == "" {
		return nil
	}
	err := os.Remove(sm.cleanupPath(allocID))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
