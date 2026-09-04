package kata

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type startupContainerd struct {
	Containerd
	entered chan struct{}
	release chan struct{}
	exit    chan struct{}
	err     error
}

func (c *startupContainerd) RunTask(ctx context.Context, id string, stdout, stderr *os.File, started func()) (int, error) {
	close(c.entered)
	<-c.release
	if c.err != nil {
		return -1, c.err
	}
	started()
	<-c.exit
	return 42, nil
}

func TestStartTaskWaitsForStartupNotExit(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	c := &startupContainerd{Containerd: rec, entered: make(chan struct{}), release: make(chan struct{}), exit: make(chan struct{})}
	d.ctr = c
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	result := make(chan error, 1)
	go func() {
		_, _, err := d.StartTask(cfg)
		result <- err
	}()
	<-c.entered
	select {
	case err := <-result:
		t.Fatalf("StartTask returned before startup: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(c.release)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("StartTask did not return after startup")
	}
	close(c.exit)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	exits, err := d.WaitTask(ctx, cfg.ID)
	if err != nil {
		t.Fatal(err)
	}
	status := <-exits
	if status == nil || status.ExitCode != 42 || status.Err != nil {
		t.Fatalf("exit status = %#v, want 42 without error", status)
	}
}

func TestStartTaskPropagatesRuntimeStartupFailure(t *testing.T) {
	d, rec := testDriverWithRecorder(t)
	failure := errors.New("runtime start failed")
	c := &startupContainerd{Containerd: rec, entered: make(chan struct{}), release: make(chan struct{}), err: failure}
	close(c.release)
	d.ctr = c
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	handle, _, err := d.StartTask(cfg)
	if !errors.Is(err, failure) || handle != nil {
		t.Fatalf("startup = (%v, %v), want runtime failure and no handle", handle, err)
	}
	if _, ok := d.tasks.Get(cfg.ID); ok {
		t.Fatal("failed startup retained task")
	}
}

func TestStartTaskReportsLogOpenFailure(t *testing.T) {
	d, _ := testDriverWithRecorder(t)
	cfg := testTaskConfig(t, &TaskConfig{Image: "alpine:latest"})
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, nil, 0600); err != nil {
		t.Fatal(err)
	}
	cfg.StdoutPath = filepath.Join(file, "stdout")

	handle, _, err := d.StartTask(cfg)
	if err == nil {
		t.Fatal("StartTask succeeded despite failing to open task logs")
	}
	if handle != nil {
		t.Fatal("failed startup returned a handle")
	}
	if _, ok := d.tasks.Get(cfg.ID); ok {
		t.Fatal("failed startup retained a task handle")
	}
}
