package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configEnvMemory(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var values []string
	switch args[0] {
	case "settings":
		if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
			return unsupported
		}
		tari, monero, err := config.MemorySettings(fields[1], string(fields[0]))
		if err != nil {
			return unsupported
		}
		values = []string{tari, monero}
	case "limit":
		if len(fields) != 3 || len(fields[2]) != 0 {
			return unsupported
		}
		limit, err := config.TariMemoryLimit(string(fields[0]), string(fields[1]))
		if err != nil {
			return unsupported
		}
		values = []string{limit}
	default:
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
