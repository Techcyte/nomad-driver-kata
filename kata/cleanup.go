package kata

import (
	"context"
	"time"
)

// cleanupTimeout bounds runtime teardown independently of the poststop delay.
const cleanupTimeout = 30 * time.Second

func cleanupContainer(ctx context.Context, ctr Containerd, id string) error {
	ctx, cancel := context.WithTimeout(ctx, cleanupTimeout)
	defer cancel()
	return ctr.Cleanup(ctx, id)
}
