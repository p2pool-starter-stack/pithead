package doctor

import (
	"os/exec"
	"strings"
)

func lanReadDocker(args ...string) (string, bool, error) {
	path, err := networkTool("docker")
	if err != nil || path == "" {
		return "", false, err
	}
	output, runErr := exec.Command(path, args...).Output()
	if unsupportedLaunch(runErr) {
		return "", false, ErrUnsupportedProbeInput
	}
	value, err := probeValue(string(output))
	return value, runErr == nil, err
}

func lanSystemctl(visible bool, args ...string) (bool, error) {
	path, err := networkTool("systemctl")
	if err != nil || path == "" {
		return false, err
	}
	command := exec.Command(path, args...)
	var output []byte
	var runErr error
	if visible {
		output, runErr = command.Output()
	} else {
		runErr = command.Run()
	}
	if unsupportedLaunch(runErr) || len(output) != 0 {
		return false, ErrUnsupportedProbeInput
	}
	return runErr == nil, nil
}

func (guard LANGuard) Hold(ports []string) ([]Finding, error) {
	applies, err := LANBootApplies(guard.OS, guard.Appliance)
	if err != nil || !applies {
		return nil, err
	}
	var findings []Finding
	seen := make(map[string]bool)
	for _, port := range ports {
		if strings.ContainsRune(port, 0) {
			return nil, ErrUnsupportedProbeInput
		}
		container := lanContainer(port)
		if seen[container] {
			continue
		}
		seen[container] = true
		policy, success, err := lanReadDocker("inspect", "-f", "{{.HostConfig.RestartPolicy.Name}}", container)
		if err != nil {
			return nil, err
		}
		if !success {
			continue
		}
		running, err := ContainerRunning(container)
		if err != nil {
			return nil, err
		}
		if running {
			if policy != "no" {
				message := container + " publishes a LAN port with restart policy '" + policy + "', so after a reboot Docker starts it before the LAN-only source rule is back. Run './pithead up'."
				if guard.Appliance {
					message = container + " could start after a restart before the rule that limits its LAN port is back."
				}
				findings = append(findings, Finding{"lan-guard-hold", "fail", message})
			}
			continue
		}
		failed, err := lanSystemctl(true, "is-failed", "--quiet", lanBootUnit)
		if err != nil {
			return nil, err
		}
		var why string
		if failed {
			why = "held since boot, because " + lanBootUnit + " failed and the LAN-only source rule is not in place (see 'journalctl -u " + lanBootUnit + "')"
		} else {
			code, _, err := lanReadDocker("inspect", "-f", "{{.State.ExitCode}}", container)
			if err != nil {
				return nil, err
			}
			if code == "78" {
				why = "it refused to start because the LAN-only source rule was not in place"
			} else {
				code, _, err = lanReadDocker("inspect", "-f", "{{.State.ExitCode}}", container)
				if err != nil {
					return nil, err
				}
				why = "it exited (code " + code + "), and with LAN access on Docker does not restart it; " + lanCheckTimer + " starts it within 2 minutes while the LAN-only source rule is live"
			}
		}
		message := container + " is down: " + why + ". Run './pithead up' to start it."
		if guard.Appliance {
			message = container + " is down; it is started again within 2 minutes if the LAN-only source rule is live."
		}
		findings = append(findings, Finding{"lan-guard-hold", "fail", message})
	}
	return findings, nil
}
