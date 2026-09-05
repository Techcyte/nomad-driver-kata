package kata

import (
	"bytes"
	"sync"
)

// execOutput combines the independently copied stdout and stderr streams.
type execOutput struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (o *execOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buffer.Write(p)
}

func (o *execOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buffer.String()
}
