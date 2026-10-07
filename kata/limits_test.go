package kata

import (
	"context"
	"testing"

	"github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/opencontainers/runtime-spec/specs-go"
)

func TestProcessLimitReplacesDefault(t *testing.T) {
	spec := &oci.Spec{Process: &specs.Process{Rlimits: []specs.POSIXRlimit{
		{Type: "RLIMIT_NOFILE", Soft: 1024, Hard: 1024},
		{Type: "RLIMIT_CORE", Soft: 0, Hard: 0},
	}}}
	want := specs.POSIXRlimit{Type: "RLIMIT_NOFILE", Soft: 65536, Hard: 65536}
	if err := withProcessLimit(want)(context.Background(), nil, &containers.Container{}, spec); err != nil {
		t.Fatal(err)
	}
	if len(spec.Process.Rlimits) != 2 || spec.Process.Rlimits[0] != want || spec.Process.Rlimits[1].Type != "RLIMIT_CORE" {
		t.Fatalf("limits: %+v", spec.Process.Rlimits)
	}
	limit := specs.POSIXRlimit{Type: "RLIMIT_NPROC", Soft: 100, Hard: 100}
	if err := withProcessLimit(limit)(context.Background(), nil, &containers.Container{}, spec); err != nil {
		t.Fatal(err)
	}
	if len(spec.Process.Rlimits) != 3 || spec.Process.Rlimits[2] != limit {
		t.Fatalf("limits: %+v", spec.Process.Rlimits)
	}
}
