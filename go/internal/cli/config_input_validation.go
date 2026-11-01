package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configInputValidation(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 3 || !bytes.Equal(fields[1], []byte("0")) || len(fields[2]) != 0 {
		return unsupported
	}
	stage, reason, err := config.ValidateInput(fields[0])
	if err != nil {
		return unsupported
	}
	result := append([]byte(stage), 0)
	result = append(result, reason...)
	result = append(result, 0)
	written, err := output.Write(result)
	if err != nil || written != len(result) {
		return unsupported
	}
	return nil
}
