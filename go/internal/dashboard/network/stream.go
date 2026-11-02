package network

import (
	"bufio"
	"bytes"
	"io"
)

func RunStream(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), maxRequestBytes+1)
	for scanner.Scan() {
		if err := Run(bytes.NewReader(scanner.Bytes()), output); err != nil {
			return err
		}
	}
	return scanner.Err()
}
