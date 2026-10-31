package doctor

import (
	"errors"
	"os"
	"os/exec"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

func ContainerEngine(appliance bool) (Finding, error) {
	if override := os.Getenv("PITHEAD_ENGINE"); override != "docker" && override != "podman" {
		for _, name := range []string{"docker", "podman"} {
			_, err := exec.LookPath(name)
			if errors.Is(err, exec.ErrDot) {
				return Finding{}, ErrUnsupportedProbeInput
			}
			if err == nil {
				break
			}
		}
	}
	engine := host.Engine()
	if engine == "docker" {
		if _, err := exec.LookPath(engine); err != nil {
			if errors.Is(err, exec.ErrDot) {
				return Finding{}, ErrUnsupportedProbeInput
			}
			return Finding{"container-engine", "info", "Skipped — docker is not installed."}, nil
		}
	}
	err := exec.Command(engine, "info").Run()
	if unsupportedLaunch(err) || errors.Is(err, exec.ErrDot) {
		return Finding{}, ErrUnsupportedProbeInput
	}
	if err == nil {
		if engine == "podman" {
			return Finding{"container-engine", "ok", "Container engine (podman) is reachable."}, nil
		}
		return Finding{"container-engine", "ok", "Docker daemon is reachable."}, nil
	}
	message := "Docker daemon is not reachable — start it (e.g. 'sudo systemctl start docker') and ensure your user is in the 'docker' group."
	if engine == "podman" {
		message = "Container engine (podman) is not reachable — check 'systemctl status podman.socket' (rootful podman has no daemon; the socket serves the API)."
	}
	if appliance {
		message = "The container engine is not reachable, so the mining stack cannot run. This machine starts it at boot, so this system copy is faulty."
	}
	return Finding{"container-engine", "fail", message}, nil
}
