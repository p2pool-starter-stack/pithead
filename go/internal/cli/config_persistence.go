package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configPersistence(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) == 2 && args[0] == "credentials" && args[1] == "publish" {
		return configCredentialsPublish(input)
	}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var rendered []byte
	switch args[0] {
	case "credentials":
		if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
			return unsupported
		}
		rendered, err = config.PersistNodeCredentials(fields[0], string(fields[1]), string(fields[2]))
	case "appliance":
		if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
			return unsupported
		}
		rendered, err = config.ApplyApplianceDefaults(fields[0], fields[1])
	default:
		return unsupported
	}
	if err != nil {
		return unsupported
	}
	rendered = append(rendered, 0)
	if _, err := output.Write(rendered); err != nil {
		return unsupported
	}
	return nil
}
