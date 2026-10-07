package kata

import (
	"context"

	"github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/opencontainers/runtime-spec/specs-go"
)

func withProcessLimit(limit specs.POSIXRlimit) oci.SpecOpts {
	return func(_ context.Context, _ oci.Client, _ *containers.Container, spec *oci.Spec) error {
		for i, existing := range spec.Process.Rlimits {
			if existing.Type == limit.Type {
				spec.Process.Rlimits[i] = limit
				return nil
			}
		}
		spec.Process.Rlimits = append(spec.Process.Rlimits, limit)
		return nil
	}
}
