package kata

import (
	"context"
	"testing"
	"time"

	"github.com/hashicorp/go-hclog"
)

type blockedCleanup struct {
	Containerd
	entered chan struct{}
	release chan struct{}
}

func (c *blockedCleanup) Cleanup(ctx context.Context, id string) {
	close(c.entered)
	<-c.release
}

func TestSandboxCleanupDoesNotBlockOtherAllocations(t *testing.T) {
	c := &blockedCleanup{Containerd: newRecorder(), entered: make(chan struct{}), release: make(chan struct{})}
	mgr := NewSandboxManager(c, hclog.NewNullLogger(), 0)
	ctx := context.Background()
	sb, err := mgr.GetOrCreate(ctx, "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", "")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		mgr.Release(ctx, sb)
		close(done)
	}()
	<-c.entered
	defer func() { close(c.release); <-done }()
	if _, err := mgr.GetOrCreate(ctx, "alloc-1", "pause:3.9", "io.containerd.kata.v2", "", ""); err == nil {
		t.Fatal("allocation reused sandbox during cleanup")
	}
	if recovered := mgr.Recover("alloc-1", sb.ID); recovered != nil {
		t.Fatal("allocation recovered sandbox during cleanup")
	}
	result := make(chan error, 1)
	go func() {
		_, err := mgr.GetOrCreate(ctx, "alloc-2", "pause:3.9", "io.containerd.kata.v2", "", "")
		result <- err
	}()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("unrelated allocation blocked by sandbox cleanup")
	}
}
