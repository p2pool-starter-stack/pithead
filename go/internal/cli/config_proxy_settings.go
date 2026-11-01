package cli

import (
	"bytes"
	"io"
	"os"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configProxySettings(args []string, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 || args[0] == "-" {
		return unsupported
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return unsupported
	}
	settings, err := config.ParseProxySettings(raw)
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	result.WriteString(strconv.Itoa(settings.Assigned))
	result.WriteByte(0)
	for _, value := range settings.Values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	result.WriteString(settings.Reason)
	result.WriteByte(0)
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
