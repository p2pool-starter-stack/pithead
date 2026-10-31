package doctor

import (
	"io"
	"os/exec"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

func BootEnabled() (bool, error) {
	if host.Engine() == "podman" {
		return systemctlEnabled("podman.socket")
	}
	enabled, err := systemctlEnabled("docker.service")
	if enabled || err != nil {
		return enabled, err
	}
	return systemctlEnabled("docker.socket")
}

func systemctlEnabled(unit string) (bool, error) {
	command := exec.Command("systemctl", "is-enabled", unit)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	err := command.Run()
	if unsupportedLaunch(err) {
		return false, ErrUnsupportedProbeInput
	}
	return err == nil, nil
}

func BootPersistence(appliance bool) (Finding, error) {
	enabled, err := BootEnabled()
	if err != nil {
		return Finding{}, err
	}
	if enabled {
		return Finding{"container-engine-boot", "ok", "Docker is enabled to start at boot — the stack will come back after a reboot."}, nil
	}
	message := "The container engine is NOT enabled to start at boot — after a power loss/reboot the stack won't restart. Fix: 'sudo systemctl enable --now docker' (docker) or 'sudo systemctl enable --now podman.socket' (podman)."
	if appliance {
		message = "The container engine is NOT enabled to start at boot — after a power loss or reboot the mining stack won't restart. This machine enables it at install time, so this system copy is faulty."
	}
	return Finding{"container-engine-boot", "warn", message}, nil
}
