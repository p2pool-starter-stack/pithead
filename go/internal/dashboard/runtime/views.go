package runtime

import (
	"encoding/json"
	"errors"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/infra"
)

func infrastructureSections(data, metrics map[string]any) (map[string]any, error) {
	monero, err := infrastructureSection("build_monero", data, metrics)
	if err != nil {
		return nil, err
	}
	node, ok := monero.(map[string]any)
	if !ok {
		return nil, errors.New("invalid native Monero section")
	}
	sections := map[string]any{"build_monero": monero}
	for _, operation := range []string{"build_system", "build_tari", "build_proxy_summary"} {
		sections[operation], err = infrastructureSection(operation, data)
		if err != nil {
			return nil, err
		}
	}
	sections["build_sync"], err = infrastructureSection("build_sync", metrics, node["db_size"])
	return sections, err
}

func infrastructureSection(operation string, args ...any) (any, error) {
	request := infra.Request{Operation: operation}
	for _, value := range args {
		raw, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		request.Args = append(request.Args, raw)
	}
	return infra.Build(request)
}
