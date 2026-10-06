package kata

import (
	"fmt"
	"math"
	"runtime"
	"strconv"

	"github.com/hashicorp/nomad/plugins/base"

	"github.com/hashicorp/nomad/plugins/drivers"
)

func sandboxCPUCount(config *base.Config) int {
	if config.AgentConfig != nil && config.AgentConfig.Driver != nil && config.AgentConfig.Driver.Topology != nil {
		if count := config.AgentConfig.Driver.Topology.NumCores(); count > 0 {
			return count
		}
	}
	return runtime.NumCPU()
}

func sandboxResources(cfg *drivers.TaskConfig, vcpus int, overheadMB int64) (map[string]string, error) {
	memoryMB, err := strconv.ParseInt(cfg.Env["NOMAD_ALLOC_MEMORY_LIMIT"], 10, 64)
	if err != nil || memoryMB <= 0 {
		return nil, fmt.Errorf("positive NOMAD_ALLOC_MEMORY_LIMIT required from Nomad client")
	}
	if vcpus <= 0 || overheadMB < 0 || memoryMB > (math.MaxInt64>>20)-overheadMB {
		return nil, fmt.Errorf("invalid sandbox CPU or memory budget")
	}
	return map[string]string{
		"io.kubernetes.cri.sandbox-memory":     strconv.FormatInt((memoryMB+overheadMB)<<20, 10),
		"io.kubernetes.cri.sandbox-cpu-period": "100000",
		"io.kubernetes.cri.sandbox-cpu-quota":  strconv.FormatInt(int64(vcpus)*100000, 10),
	}, nil
}
