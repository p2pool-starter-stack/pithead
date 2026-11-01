package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configCredentialsPublish(input io.Reader) error {
	unsupported := &ExitError{Code: 125}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 6 || len(fields[5]) != 0 || !bytes.Equal(fields[4], []byte("0")) {
		return unsupported
	}
	if err := config.PublishNodeCredentials(fields[0], string(fields[1]), string(fields[2]), string(fields[3])); err != nil {
		return unsupported
	}
	return nil
}
