package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configMasked(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
		return unsupported
	}
	rendered, err := config.MaskConfig(fields[0], fields[1])
	if err != nil {
		return unsupported
	}
	rendered = append(rendered, 0)
	if written, err := output.Write(rendered); err != nil || written != len(rendered) {
		return unsupported
	}
	return nil
}
