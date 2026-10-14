package kata

import "io"

// execInput reports EOF after all input bytes have been handed to the copier.
type execInput struct {
	reader io.Reader
	eof    chan struct{}
	ended  bool
}

func (s *execInput) Read(p []byte) (int, error) {
	if s.ended {
		return 0, io.EOF
	}
	n, err := s.reader.Read(p)
	if err == io.EOF {
		if n > 0 {
			return n, nil
		}
		s.ended = true
		close(s.eof)
	}
	return n, err
}
