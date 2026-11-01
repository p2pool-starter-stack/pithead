package cli

import (
	"bytes"
	"io"
	"os"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configDefaults(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) < 2 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	boundary := bytes.LastIndexByte(raw, '\n')
	if boundary < 0 || !bytes.Equal(raw[boundary+1:], []byte("0")) {
		return unsupported
	}
	defaults, err := config.NewDefaults(raw[:boundary])
	if err != nil {
		return unsupported
	}
	var rendered []byte
	switch {
	case args[0] == "defaults" && len(args) == 3:
		rendered, err = defaults.Render(args[1], args[2])
	case args[0] == "default" && len(args) == 4:
		rendered, err = defaults.DefaultOf(args[1], args[2], args[3])
	case args[0] == "install" && len(args) == 2:
		rendered, err = defaults.NewInstall(args[1])
	case args[0] == "get" && len(args) == 4 && args[2] != "-":
		var document []byte
		document, err = os.ReadFile(args[2])
		if err == nil {
			rendered, err = defaults.Get(args[1], document, args[3])
		}
	default:
		return unsupported
	}
	if err != nil {
		return unsupported
	}
	if _, err := output.Write(rendered); err != nil {
		return unsupported
	}
	return nil
}
