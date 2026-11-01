package cli

import (
	"bytes"
	"io"
	"os"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configNetworkSettings(args []string, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 3 || args[0] == "-" {
		return unsupported
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return unsupported
	}
	plan, err := config.ParseNetworkSettings(raw, config.NetworkSettingsInput{
		ConfigPath: args[0], MoneroMode: args[1], TariMode: args[2],
	})
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	result.WriteString(strconv.Itoa(plan.Assigned))
	result.WriteByte(0)
	for _, value := range plan.Values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	result.WriteString(plan.Reason)
	result.WriteByte(0)
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
