package cli

import "strings"

func selectedFallbackEnv(env []string, binary string) []string {
	filtered := make([]string, 0, len(env)+2)
	native := false
	for _, entry := range env {
		if entry == "PITHEAD_IMPL=go" {
			native = true
		}
		if strings.HasPrefix(entry, "PITHEAD_GO_REFERENCE=") ||
			strings.HasPrefix(entry, "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=") ||
			strings.HasPrefix(entry, "_PITHEAD_GO_HYBRID=") ||
			strings.HasPrefix(entry, "_pithead_go_hybrid_binary=") {
			continue
		}
		filtered = append(filtered, entry)
	}
	if native {
		filtered = append(fallbackEnv(filtered), "_PITHEAD_GO_HYBRID=1")
		return configDocumentFallbackEnv(filtered, binary)
	}
	return filtered
}
