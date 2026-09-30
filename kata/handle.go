package kata

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/nomad/plugins/drivers"
)

type taskHandle struct {
	containerID string
	sandboxID   string
	sandbox     *Sandbox
	allocID     string
	taskName    string

	ctr    Containerd
	logger hclog.Logger

	startedAt   time.Time
	completedAt time.Time
	exitResult  *drivers.ExitResult

	startupCh     chan error
	doneCh        chan struct{}
	onSandboxDead func(string)
	mu            sync.RWMutex
}

// run starts the containerd task with IO piped to log files.
// Blocks until the task exits.
func (h *taskHandle) run(stdoutPath, stderrPath string) {
	defer close(h.doneCh)
	var startup sync.Once
	notifyStartup := func(err error) {
		startup.Do(func() {
			if h.startupCh != nil {
				h.startupCh <- err
			}
		})
	}

	stdout, stderr, err := h.openLogs(stdoutPath, stderrPath)
	if err != nil {
		h.logger.Error("failed to open log files", "error", err)
		h.setExit(1, err)
		notifyStartup(err)
		return
	}
	if stdout != nil {
		defer stdout.Close()
	}
	if stderr != nil {
		defer stderr.Close()
	}

	exitCode, err := h.ctr.RunTask(context.Background(), h.containerID, stdout, stderr, func() {
		notifyStartup(nil)
	})
	notifyStartup(err)
	h.recordExit(exitCode, err)
}

// monitorRecovered re-attaches to a running task for log streaming after
// driver restart. Blocks until the task exits.
func (h *taskHandle) monitorRecovered(stdoutPath, stderrPath string) {
	defer close(h.doneCh)

	stdout, stderr, err := h.openLogs(stdoutPath, stderrPath)
	if err != nil {
		h.logger.Error("failed to open log files", "error", err)
		h.setExit(0, nil)
		return
	}
	if stdout != nil {
		defer stdout.Close()
	}
	if stderr != nil {
		defer stderr.Close()
	}

	exitCode, err := h.ctr.MonitorTask(context.Background(), h.containerID, stdout, stderr)
	h.recordExit(exitCode, err)
}

func (h *taskHandle) recordExit(code int, err error) {
	if (code != 0 || err != nil) && h.onSandboxDead != nil {
		running, stateErr := h.ctr.TaskState(context.Background(), h.sandboxID)
		if !running && (stateErr == nil || sandboxTransportFailed(stateErr)) {
			h.onSandboxDead(h.allocID)
		}
	}
	h.setExit(code, err)
}

func sandboxTransportFailed(err error) bool {
	message := err.Error()
	return strings.Contains(message, "ttrpc: closed") ||
		strings.Contains(message, "transport is closing") ||
		strings.Contains(message, "connection is shut down")
}

func (h *taskHandle) openLogs(stdoutPath, stderrPath string) (*os.File, *os.File, error) {
	var stdout, stderr *os.File
	var err error

	if stdoutPath != "" {
		stdout, err = openLog(stdoutPath)
		if err != nil {
			return nil, nil, err
		}
	}

	if stderrPath != "" {
		stderr, err = openLog(stderrPath)
		if err != nil {
			if stdout != nil {
				stdout.Close()
			}
			return nil, nil, err
		}
	}

	return stdout, stderr, nil
}

func openLog(path string) (*os.File, error) {
	flags := os.O_WRONLY | os.O_CREATE | os.O_APPEND
	info, err := os.Stat(path)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if err == nil && info.Mode()&os.ModeNamedPipe != 0 {
		// Keep a reader present while Nomad replaces its log monitor.
		flags = os.O_RDWR
	}
	return os.OpenFile(path, flags, 0600)
}

func (h *taskHandle) setExit(code int, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.completedAt = time.Now()
	h.exitResult = &drivers.ExitResult{ExitCode: code}
	if err != nil {
		h.exitResult.Err = err
	}
}

func (h *taskHandle) IsRunning() bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.exitResult == nil
}

func (h *taskHandle) ExitResult() *drivers.ExitResult {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.exitResult
}

func (h *taskHandle) TaskStatus() *drivers.TaskStatus {
	h.mu.RLock()
	defer h.mu.RUnlock()

	state := drivers.TaskStateRunning
	if h.exitResult != nil {
		state = drivers.TaskStateExited
	}

	return &drivers.TaskStatus{
		ID:          h.containerID,
		Name:        h.taskName,
		State:       state,
		StartedAt:   h.startedAt,
		CompletedAt: h.completedAt,
		ExitResult:  h.exitResult,
	}
}
