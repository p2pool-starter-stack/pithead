package cli

import (
	"fmt"
	"io"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configDocumentFallbackEnv(env []string, binary string) []string {
	filtered := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if !strings.HasPrefix(entry, "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=") {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, "PITHEAD_GO_CONFIG_DOCUMENT_BINARY="+binary)
}

func configDocument(args []string, output io.Writer) error {
	if len(args) != 2 {
		return &ExitError{Code: 125}
	}
	reason, err := config.ValidateDocumentFile(args[0], args[1] == "request")
	if err != nil {
		return &ExitError{Code: 125}
	}
	if reason != "" {
		if _, err := fmt.Fprintln(output, reason); err != nil {
			return &ExitError{Code: 125}
		}
		return &ExitError{Code: 1}
	}
	return nil
}
