package kata

import (
	"testing"

	"github.com/hashicorp/nomad/plugins/drivers"
)

func TestSandboxResourcesUseAllocationBudget(t *testing.T) {
	for _, taskLimit := range []int64{128, 8192} {
		cfg := &drivers.TaskConfig{
			Env:       map[string]string{"NOMAD_ALLOC_MEMORY_LIMIT": "8320"},
			Resources: &drivers.Resources{LinuxResources: &drivers.LinuxResources{MemoryLimitBytes: taskLimit << 20}},
		}
		annotations, err := sandboxResources(cfg, 8, 256)
		if err != nil {
			t.Fatal(err)
		}
		if got := annotations["io.kubernetes.cri.sandbox-memory"]; got != "8992587776" {
			t.Fatalf("sandbox memory = %q, want 8576 MiB", got)
		}
		if got := annotations["io.kubernetes.cri.sandbox-cpu-quota"]; got != "800000" {
			t.Fatalf("sandbox CPU quota = %q, want 8 vCPUs", got)
		}
	}
}

func TestSandboxResourcesRejectMissingAllocationBudget(t *testing.T) {
	if _, err := sandboxResources(&drivers.TaskConfig{}, 8, 256); err == nil {
		t.Fatal("expected missing allocation budget error")
	}
}
