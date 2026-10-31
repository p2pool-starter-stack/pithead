package doctor

import (
	"os"
	"path/filepath"
)

type Deployment struct {
	Dir       string
	EnvFile   string
	Completed string
	Appliance bool
}

func (deployment Deployment) Findings() ([]Finding, error) {
	dir, err := probeDirectory(deployment.Dir)
	if err != nil {
		return nil, err
	}
	envFile := deployment.EnvFile
	if envFile == "" {
		envFile = ".env"
	}
	if invalidProbePath(envFile) {
		return nil, ErrUnsupportedProbeInput
	}
	path := envFile
	if !filepath.IsAbs(path) {
		path = dir + string(os.PathSeparator) + path
	}
	info, statErr := os.Stat(path)
	if statErr != nil || !info.Mode().IsRegular() {
		message := "No " + envFile + " found — the stack has not been set up. Run './pithead setup'. (Skipping env-dependent checks.)"
		if deployment.Appliance {
			message = "The stack has not been set up — finish setup from this machine's setup page. (Skipping the checks that depend on it.)"
		}
		return []Finding{{"environment-file", "warn", message}}, nil
	}
	findings := []Finding{{"environment-file", "ok", envFile + " present."}}
	completed, err := probeValue(deployment.Completed)
	if err != nil {
		return nil, err
	}
	if completed == "true" {
		return append(findings, Finding{"deployment-completed", "ok", "DEPLOYMENT_COMPLETED=true — setup finished."}), nil
	}
	message := "DEPLOYMENT_COMPLETED is not true — setup may be incomplete. Run './pithead setup'."
	if deployment.Appliance {
		message = "Setup did not finish, so parts of this machine may be unconfigured. Its setup page closes once the machine is provisioned, so no dashboard surface resumes it — correcting this needs console access."
	}
	return append(findings, Finding{"deployment-completed", "warn", message}), nil
}
