package doctor

import (
	"errors"
	"os/exec"
	"strings"
)

func Dependencies(appliance bool) ([]Finding, error) {
	tools := []struct {
		name, missingDIY, missingAppliance string
		version                            bool
	}{
		{"jq", "jq not found — install it (Ubuntu: 'sudo apt-get install -y jq').", "jq is not present, so doctor cannot read this machine's configuration. The appliance image ships it, so this system copy is faulty.", true},
		{"openssl", "openssl not found — install it (Ubuntu: 'sudo apt-get install -y openssl').", "openssl is not present, so the dashboard certificate cannot be checked. The appliance image ships it, so this system copy is faulty.", false},
		{"docker", "docker not found — install Docker and the compose v2 plugin.", "The container engine is not present, so the mining stack cannot start. The appliance image ships it, so this system copy is faulty.", true},
	}
	findings := make([]Finding, 0, 4)
	for _, tool := range tools {
		finding := Finding{ID: "dependency-" + tool.name, Status: "fail", Message: tool.missingDIY}
		if appliance {
			finding.Message = tool.missingAppliance
		}
		if _, err := exec.LookPath(tool.name); err == nil {
			finding.Status = "ok"
			finding.Message = tool.name + " found."
			if tool.version {
				version, err := toolVersion(tool.name)
				if err != nil {
					return nil, err
				}
				finding.Message = tool.name + " found (" + version + ")."
			}
		}
		findings = append(findings, finding)
	}
	compose := Finding{"dependency-compose", "ok", "docker compose (v2 plugin) found."}
	if err := exec.Command("docker", "compose", "version").Run(); err != nil {
		if unsupportedLaunch(err) {
			return nil, ErrUnsupportedProbeInput
		}
		compose.Status = "fail"
		compose.Message = "docker compose (v2 plugin) not found — install 'docker-compose-v2'."
		if appliance {
			compose.Message = "The container engine's compose plugin is not present, so the mining stack cannot start. The appliance image ships it, so this system copy is faulty."
		}
	}
	return append(findings, compose), nil
}

func toolVersion(name string) (string, error) {
	output, err := exec.Command(name, "--version").Output()
	if strings.ContainsRune(string(output), 0) || unsupportedLaunch(err) {
		return "", ErrUnsupportedProbeInput
	}
	if err != nil {
		output = append(output, "unknown version\n"...)
	}
	return strings.TrimRight(string(output), "\n"), nil
}

func unsupportedLaunch(err error) bool {
	if err == nil {
		return false
	}
	var status *exec.ExitError
	var missing *exec.Error
	return !errors.As(err, &status) && !errors.As(err, &missing)
}
