package overview

import (
	"errors"
	"math/big"
	"strings"
)

func buildEgressBadge(request Request) (any, error) {
	values, err := arguments(request.Args, 1)
	if err != nil {
		return nil, err
	}
	summary, err := object(values[0])
	if err != nil {
		return nil, err
	}
	level, ok := summary["level"].(string)
	if !ok {
		return nil, errors.New("invalid egress level")
	}
	label, ok := summary["label"].(string)
	if !ok {
		return nil, errors.New("invalid egress label")
	}
	leaks, ok := summary["leaks"]
	if !ok {
		return nil, errors.New("missing leaks")
	}
	variant := "warn"
	text := "⚠️ " + label
	if level == "ok" {
		variant = "ok"
		text = "🛡️ Tor-only egress"
	} else if truthy(leaks) {
		variant = "bad"
	}
	return map[string]any{"variant": variant, "text": text, "title": label}, nil
}

func buildVisibleUpdate(request Request) (any, error) {
	values, err := arguments(request.Args, 2)
	if err != nil {
		return nil, err
	}
	if !truthy(values[0]) {
		return nil, nil
	}
	update, err := object(values[0])
	if err != nil {
		return nil, err
	}
	running, ok := values[1].(string)
	if !ok {
		if truthy(values[1]) {
			return nil, errors.New("invalid running version")
		}
		return update, nil
	}
	latestValue := member(update, "latest", nil)
	latest, ok := latestValue.(string)
	if !ok {
		if truthy(latestValue) {
			return nil, errors.New("invalid latest version")
		}
		return update, nil
	}
	runningVersion, runningOK := semver(running)
	latestVersion, latestOK := semver(latest)
	if runningOK && latestOK && compareSemver(latestVersion, runningVersion) <= 0 {
		return nil, nil
	}
	return update, nil
}

func semver(value string) ([3]*big.Int, bool) {
	var result [3]*big.Int
	core := strings.TrimSpace(value)
	core = strings.TrimLeft(core, "vV")
	core = strings.SplitN(core, "-", 2)[0]
	core = strings.SplitN(core, "+", 2)[0]
	parts := strings.Split(core, ".")
	if len(parts) < 3 {
		return result, false
	}
	for index := range result {
		if parts[index] == "" || strings.Trim(parts[index], "0123456789") != "" {
			return result, false
		}
		result[index], _ = new(big.Int).SetString(parts[index], 10)
	}
	return result, true
}

func compareSemver(left, right [3]*big.Int) int {
	for index := range left {
		if comparison := left[index].Cmp(right[index]); comparison != 0 {
			return comparison
		}
	}
	return 0
}
