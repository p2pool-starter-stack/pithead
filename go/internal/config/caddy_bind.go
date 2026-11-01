package config

import "strings"

func CaddyBindAddresses(bridges, prefix string, candidates []string) string {
	filtered := make([]string, 0, len(candidates)+2)
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if strings.Contains(bridges, " "+candidate+" ") {
			continue
		}
		if prefix != "" && candidate == prefix+".1" {
			continue
		}
		if !strings.Contains(candidate, ":") && !caddyIPv4Literal(candidate) {
			continue
		}
		filtered = append(filtered, candidate)
	}
	filtered = append(filtered, "127.0.0.1", "::1")
	return strings.Join(filtered, " ")
}

func caddyIPv4Literal(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] != '.' && (value[i] < '0' || value[i] > '9') {
			return false
		}
	}
	return true
}
