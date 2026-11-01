package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configVersionPublish(args []string, input io.Reader) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
		return unsupported
	}
	if err := config.PublishConfigVersion(fields[0], string(fields[1]), string(fields[2])); err != nil {
		return unsupported
	}
	return nil
}
