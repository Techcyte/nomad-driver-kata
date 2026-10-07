package kata

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/hashicorp/nomad/api"
	"github.com/hashicorp/nomad/helper/pluginutils/hclutils"
)

func TestTaskFileLimitDecoding(t *testing.T) {
	if os.Getenv("NOMAD_ADDR") == "" {
		t.Skip("dedicated Nomad parser required")
	}
	client, err := api.NewClient(api.DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	job, err := client.Jobs().ParseHCL(`job "limits" {
 group "workspace" {
 task "docker" {
 driver = "kata"
 config {
 image = "docker:29-dind"
 ulimit = "${ { nofile = "65536:65536" } }"
 }
 }
 }
}`, true)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(job.TaskGroups[0].Tasks[0].Config)
	if err != nil {
		t.Fatal(err)
	}
	var cfg TaskConfig
	hclutils.NewConfigParser(taskConfigSpec).ParseJson(t, string(data), &cfg)
	if cfg.Ulimit["nofile"] != "65536:65536" {
		t.Fatalf("limits: %+v", cfg.Ulimit)
	}
}
