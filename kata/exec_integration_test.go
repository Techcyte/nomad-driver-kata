package kata

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/hashicorp/go-hclog"
)

func TestExecOutputDrain(t *testing.T) {
	containerID := os.Getenv("KATA_EXEC_CONTAINER")
	if containerID == "" {
		t.Skip("requires a running Kata container")
	}
	client, err := NewContainerdClient(os.Getenv("CONTAINERD_SOCK"), "default", hclog.NewNullLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	const size = 4 * 1024 * 1024
	for _, tc := range []struct {
		name   string
		script string
		out    int
		err    int
	}{
		{"stdout", "head -c 4194304 /dev/zero | tr '\\000' o; exit 42", size, 0},
		{"stderr", "head -c 4194304 /dev/zero | tr '\\000' e >&2; exit 42", 0, size},
		{"both", "(head -c 4194304 /dev/zero | tr '\\000' o) & head -c 4194304 /dev/zero | tr '\\000' e >&2; wait; exit 42", size, size},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			output, code, err := client.Exec(ctx, containerID, "drain-"+tc.name, []string{"/bin/sh", "-c", tc.script})
			if err != nil {
				t.Fatal(err)
			}
			if code != 42 || len(output) != tc.out+tc.err || strings.Count(output, "o") != tc.out || strings.Count(output, "e") != tc.err {
				t.Fatalf("exit=%d bytes=%d stdout=%d stderr=%d; want exit=42 stdout=%d stderr=%d", code, len(output), strings.Count(output, "o"), strings.Count(output, "e"), tc.out, tc.err)
			}
		})
	}
}
