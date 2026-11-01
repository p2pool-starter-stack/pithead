package cli

import (
	"bytes"
	"io"
	"os"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configStratum(args []string, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 || args[0] == "-" {
		return unsupported
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return unsupported
	}
	endpoint, err := config.ParseStratumEndpoint(raw)
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range []string{endpoint.Stage, endpoint.Bind, endpoint.Port, endpoint.Reason} {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
