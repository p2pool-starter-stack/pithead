package cli

import (
	"fmt"
	"io"
	"os"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configValidation(args []string, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 2 || args[1] == "-" {
		return unsupported
	}
	raw, err := os.ReadFile(args[1])
	if err != nil {
		return unsupported
	}
	reason, warning, err := config.ValidateSection(raw, args[0])
	if err != nil {
		return unsupported
	}
	if reason == "" {
		return nil
	}
	if _, err := fmt.Fprintln(output, reason); err != nil {
		return unsupported
	}
	if warning {
		return &ExitError{Code: 2}
	}
	return &ExitError{Code: 1}
}
