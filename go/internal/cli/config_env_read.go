package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configEnvRead(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 4 || len(fields[3]) != 0 {
		return unsupported
	}
	var value, reason string
	switch args[0] {
	case "decode":
		if !bytes.Equal(fields[2], []byte("0")) {
			return unsupported
		}
		value, reason = config.DecodeEnvValue(string(fields[0]), string(fields[1]))
	case "get":
		if !bytes.Equal(fields[1], []byte("0")) {
			return unsupported
		}
		var ok bool
		value, reason, ok = config.EnvGetFile(fields[0], string(fields[2]))
		if !ok {
			return unsupported
		}
	default:
		return unsupported
	}
	result := []byte(value + "\x00" + reason + "\x000\x00")
	if written, err := output.Write(result); err != nil || written != len(result) {
		return unsupported
	}
	return nil
}
