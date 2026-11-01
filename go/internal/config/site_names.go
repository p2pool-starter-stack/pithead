package config

import (
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

func ApplianceSiteNames(base, bridges, prefix, exposePublic string, candidates []string) (string, error) {
	names := base
	for _, candidate := range candidates {
		if strings.Contains(" "+names+" ", " "+candidate+" ") || strings.Contains(bridges, " "+candidate+" ") {
			continue
		}
		if exposePublic != "true" {
			public, err := host.PublicIP(candidate)
			if err != nil {
				return "", err
			}
			if public {
				continue
			}
		}
		if prefix != "" && candidate == prefix+".1" {
			continue
		}
		names += " " + candidate
	}
	return names, nil
}

func ApplianceCertAltString(names []string) string {
	values := make([]string, len(names))
	for index, name := range names {
		kind := "IP:"
		if !strings.Contains(name, ":") {
			for _, ch := range []byte(name) {
				if ch != '.' && (ch < '0' || ch > '9') {
					kind = "DNS:"
					break
				}
			}
		}
		values[index] = kind + name
	}
	return strings.Join(values, ",")
}
