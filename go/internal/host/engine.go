package host

import (
	"os"
	"os/exec"
)

func Engine() string {
	if engine := os.Getenv("PITHEAD_ENGINE"); engine == "docker" || engine == "podman" {
		return engine
	}
	if _, err := exec.LookPath("docker"); err == nil {
		return "docker"
	}
	if _, err := exec.LookPath("podman"); err == nil {
		return "podman"
	}
	return "docker"
}
