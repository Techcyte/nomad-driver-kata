package kata

import (
	"io"
	"strings"
	"testing"
	"testing/iotest"
)

func TestExecInputEOF(t *testing.T) {
	for _, reader := range []io.Reader{strings.NewReader("input"), iotest.DataErrReader(strings.NewReader("input"))} {
		input := &execInput{reader: reader, eof: make(chan struct{})}
		buffer := make([]byte, 32)
		n, err := input.Read(buffer)
		if n != 5 || err != nil || string(buffer[:n]) != "input" {
			t.Fatalf("read = %q, %v", buffer[:n], err)
		}
		select {
		case <-input.eof:
			t.Fatal("EOF signaled before copier writes final bytes")
		default:
		}
		for range 2 {
			n, err = input.Read(buffer)
			if n != 0 || err != io.EOF {
				t.Fatalf("EOF read = %d, %v", n, err)
			}
			select {
			case <-input.eof:
			default:
				t.Fatal("EOF not signaled")
			}
		}
	}
}
