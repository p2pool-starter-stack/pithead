package config

import (
	"bytes"
	"encoding/json"
)

func deriveDashboardWorkers(plan *DashboardPlan, root node) error {
	fleetPort, err := dashboardAlternativeNode(root, "workers.api_port", node{value: json.Number("8080")})
	if err != nil {
		return err
	}
	if plan.values[dashboardWorkerAPIPort], err = dashboardScalar(fleetPort); err != nil {
		return err
	}
	if plan.values[dashboardWorkerAPIAuth], err = dashboardAlternative(root, "workers.api_auth", "none"); err != nil {
		return err
	}
	if plan.values[dashboardWorkerAPIToken], err = dashboardAlternative(root, "workers.api_token", ""); err != nil {
		return err
	}
	plan.values[dashboardWorkerAPITokensJSON], err = dashboardWorkerTokens(root, fleetPort)
	return err
}

func dashboardAlternativeNode(root node, path string, fallback node) (node, error) {
	value, err := dashboardPath(root, path)
	if err != nil {
		return node{}, err
	}
	if isNull(value) || value.value == false {
		return cloneNode(fallback), nil
	}
	return value, nil
}

func dashboardWorkerTokens(root node, fleetPort node) (string, error) {
	workers, err := dashboardAlternativeNode(root, "workers.list", node{array: []node{}})
	if err != nil || workers.array == nil {
		return "", ErrUnsupportedDashboard
	}

	type endpoint struct {
		name  string
		host  string
		port  node
		token string
	}
	endpoints := make([]endpoint, 0, len(workers.array))
	seen := make(map[string]struct{}, len(workers.array))
	for _, worker := range workers.array {
		if worker.object == nil {
			return "", ErrUnsupportedDashboard
		}
		name, err := dashboardWorkerString(worker, "name")
		if err != nil {
			return "", err
		}
		host, err := dashboardWorkerString(worker, "host")
		if err != nil {
			return "", err
		}
		token, err := dashboardWorkerString(worker, "api_token")
		if err != nil {
			return "", err
		}
		if name == "" || host == "" || token == "" {
			continue
		}
		if _, exists := seen[name]; exists {
			continue
		}
		port, err := dashboardWorkerPort(worker, fleetPort)
		if err != nil {
			return "", err
		}
		seen[name] = struct{}{}
		endpoints = append(endpoints, endpoint{name, host, port, token})
	}

	var output bytes.Buffer
	output.WriteByte('{')
	for index, endpoint := range endpoints {
		if index > 0 {
			output.WriteByte(',')
		}
		if err := writeJQString(&output, endpoint.name); err != nil {
			return "", ErrUnsupportedDashboard
		}
		output.WriteString(`:{"host":`)
		if err := writeJQString(&output, endpoint.host); err != nil {
			return "", ErrUnsupportedDashboard
		}
		output.WriteString(`,"port":`)
		if err := writeDashboardCompact(&output, endpoint.port); err != nil {
			return "", err
		}
		output.WriteString(`,"token":`)
		if err := writeJQString(&output, endpoint.token); err != nil {
			return "", ErrUnsupportedDashboard
		}
		output.WriteByte('}')
	}
	output.WriteByte('}')
	return output.String(), nil
}

func dashboardWorkerString(worker node, key string) (string, error) {
	value, ok := objectValue(worker, key)
	if !ok || isNull(value) || value.value == false {
		return "", nil
	}
	text, ok := value.value.(string)
	if !ok || !dashboardSupportedString(text) {
		return "", ErrUnsupportedDashboard
	}
	return text, nil
}

func dashboardWorkerPort(worker node, fallback node) (node, error) {
	value, ok := objectValue(worker, "port")
	if !ok || isNull(value) || value.value == false {
		return cloneNode(fallback), nil
	}
	var output bytes.Buffer
	if err := writeDashboardCompact(&output, value); err != nil {
		return node{}, err
	}
	return value, nil
}

func writeDashboardCompact(output *bytes.Buffer, current node) error {
	rendered, err := prettyJQ(current)
	if err != nil || json.Compact(output, rendered) != nil {
		return ErrUnsupportedDashboard
	}
	return nil
}
