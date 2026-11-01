package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configCaddyAuth(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var value string
	switch args[0] {
	case "auth":
		if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
			return unsupported
		}
		value, err = config.CaddyAuthBlock(string(fields[0]), string(fields[1]))
	case "boot":
		if len(fields) != 3 || len(fields[2]) != 0 || !bytes.Equal(fields[1], []byte("0")) {
			return unsupported
		}
		value = config.CaddyBootCapability(string(fields[0]))
	default:
		return unsupported
	}
	if err != nil {
		return unsupported
	}
	if _, err := output.Write(append([]byte(value), 0)); err != nil {
		return unsupported
	}
	return nil
}
