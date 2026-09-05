package kata

import (
	"reflect"
	"testing"
	"time"

	v1 "github.com/containerd/cgroups/v3/cgroup1/stats"
	"github.com/containerd/containerd/api/types"
	"github.com/containerd/typeurl/v2"
)

func TestParseMetricProtoCgroupV1Mappings(t *testing.T) {
	tests := []struct {
		name  string
		stats *v1.Metrics
		want  containerMetrics
	}{
		{
			name: "all counters",
			stats: &v1.Metrics{
				CPU: &v1.CPUStat{
					Usage:      &v1.CPUUsage{Total: 500_001, User: 300_002, Kernel: 199_999},
					Throttling: &v1.Throttle{Periods: 99, ThrottledPeriods: 7, ThrottledTime: 50_003},
				},
				Memory: &v1.MemoryStat{
					Usage: &v1.MemoryEntry{Usage: 4096, Max: 8192, Limit: 16384},
					Swap:  &v1.MemoryEntry{Usage: 5120, Max: 10240},
					RSS:   2048, Cache: 512, MappedFile: 256,
				},
			},
			want: containerMetrics{CPUUsageNanos: 500_001, CPUUserNanos: 300_002, CPUSystemNanos: 199_999, ThrottledPeriods: 7, ThrottledTimeNanos: 50_003, MemoryUsageBytes: 4096, MemoryMaxUsageBytes: 8192, MemoryRSSBytes: 2048, MemoryCacheBytes: 512, MemorySwapBytes: 1024, MemoryMappedBytes: 256},
		},
		{name: "empty", stats: &v1.Metrics{}},
		{name: "empty nested counters", stats: &v1.Metrics{CPU: &v1.CPUStat{}, Memory: &v1.MemoryStat{}}},
		{name: "usage without throttling", stats: &v1.Metrics{CPU: &v1.CPUStat{Usage: &v1.CPUUsage{Total: 123}}}, want: containerMetrics{CPUUsageNanos: 123}},
		{name: "throttling without usage", stats: &v1.Metrics{CPU: &v1.CPUStat{Throttling: &v1.Throttle{ThrottledPeriods: 2, ThrottledTime: 3}}}, want: containerMetrics{ThrottledPeriods: 2, ThrottledTimeNanos: 3}},
		{name: "memory without swap", stats: &v1.Metrics{Memory: &v1.MemoryStat{Usage: &v1.MemoryEntry{Usage: 100, Max: 200}}}, want: containerMetrics{MemoryUsageBytes: 100, MemoryMaxUsageBytes: 200}},
		{name: "swap without memory usage", stats: &v1.Metrics{Memory: &v1.MemoryStat{Swap: &v1.MemoryEntry{Usage: 100}}}},
		{name: "swap accounting unavailable", stats: &v1.Metrics{Memory: &v1.MemoryStat{Usage: &v1.MemoryEntry{Usage: 100}, Swap: &v1.MemoryEntry{Usage: 0}}}, want: containerMetrics{MemoryUsageBytes: 100}},
		{name: "no swap used", stats: &v1.Metrics{Memory: &v1.MemoryStat{Usage: &v1.MemoryEntry{Usage: 100}, Swap: &v1.MemoryEntry{Usage: 100}}}, want: containerMetrics{MemoryUsageBytes: 100}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data, err := typeurl.MarshalAnyToProto(tt.stats)
			if err != nil {
				t.Fatal(err)
			}
			if data.TypeUrl != "io.containerd.cgroups.v1.Metrics" {
				t.Fatalf("unexpected runtime metrics URL: %s", data.TypeUrl)
			}
			before := time.Now().UTC()
			got, err := parseMetricProto(&types.Metric{Data: data})
			if err != nil {
				t.Fatal(err)
			}
			if got.Timestamp.Before(before) || got.Timestamp.After(time.Now().UTC()) {
				t.Fatal("invalid sample timestamp")
			}
			tt.want.Timestamp = got.Timestamp
			if !reflect.DeepEqual(*got, tt.want) {
				t.Fatalf("metrics = %+v, want %+v", *got, tt.want)
			}
			usage := got.ResourceUsage(nil).ResourceUsage
			mem := usage.MemoryStats
			if mem.Usage != tt.want.MemoryUsageBytes || mem.MaxUsage != tt.want.MemoryMaxUsageBytes || mem.RSS != tt.want.MemoryRSSBytes || mem.Cache != tt.want.MemoryCacheBytes || mem.Swap != tt.want.MemorySwapBytes || mem.MappedFile != tt.want.MemoryMappedBytes {
				t.Fatalf("Nomad memory mapping: %+v", mem)
			}
			cpu := usage.CpuStats
			if cpu.ThrottledPeriods != tt.want.ThrottledPeriods || cpu.ThrottledTime != tt.want.ThrottledTimeNanos {
				t.Fatalf("Nomad throttling mapping: %+v", cpu)
			}
		})
	}
}
