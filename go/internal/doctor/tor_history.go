package doctor

import (
	"bytes"
	"crypto/rand"
	"math/big"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

var torRecoveryTargets = [...]string{
	"https://www.google.com/generate_204",
	"https://www.cloudflare.com/cdn-cgi/trace",
}

type TorCircuitHistory struct {
	Mount          string
	MountAvailable bool
	Prefix         string
	Appliance      bool
}

func TorStateSaturated(path string) (bool, error) {
	if strings.ContainsRune(path, 0) {
		return false, ErrUnsupportedProbeInput
	}
	sudo, err := networkTool("sudo")
	if err != nil {
		return false, err
	}
	if sudo == "" {
		return false, ErrUnsupportedProbeInput
	}
	for _, args := range [][]string{
		{"test", "-f", path},
		{"test", "!", "-L", path},
		{"grep", "-qx", "CircuitBuildAbandonedCount 1000", path},
		{"grep", "-qx", "TotalBuildTimes 1000", path},
	} {
		matched, runErr := torProbeCommand(sudo, args...)
		if runErr != nil || !matched {
			return false, runErr
		}
	}
	matched, err := torProbeCommand(sudo, "grep", "-q", "^CircuitBuildTimeBin ", path)
	if err != nil {
		return false, err
	}
	return !matched, nil
}

func TorRecoveryEgressDown(prefix string) (bool, error) {
	curl, err := networkTool("curl")
	if err != nil {
		return false, err
	}
	if curl == "" {
		return false, nil
	}
	prefix, err = probeValue(prefix)
	if err != nil {
		return false, err
	}
	if prefix == "" {
		prefix = "172.28.0"
	}
	for _, target := range torRecoveryTargets {
		auth, authErr := torRecoveryAuth()
		if authErr != nil {
			return false, authErr
		}
		command := exec.Command(curl, "-sS", "--max-time", "15", "--proxy-user", auth+":isolate", "--socks5-hostname", prefix+".25:9050", "-o", "/dev/null", target)
		output, runErr := command.Output()
		if unsupportedLaunch(runErr) || len(output) != 0 {
			return false, ErrUnsupportedProbeInput
		}
		if runErr == nil {
			return false, nil
		}
	}
	return true, nil
}

func (history TorCircuitHistory) Findings() ([]Finding, error) {
	running, err := ContainerRunning("tor")
	if err != nil || !running {
		return nil, err
	}
	allowed, err := torHistorySudoAllowed()
	if err != nil || !allowed || !history.MountAvailable {
		return nil, err
	}
	mount, err := probeValue(history.Mount)
	if err != nil {
		return nil, err
	}
	saturated, err := TorStateSaturated(mount + "/state")
	if err != nil || !saturated {
		return nil, err
	}
	down, err := TorRecoveryEgressDown(history.Prefix)
	if err != nil || !down {
		return nil, err
	}
	message := "Tor's circuit-build-time history is saturated and clearnet egress is down — NEWNYM cannot clear it. Run './pithead tor-recover check', then './pithead tor-recover apply'."
	if history.Appliance {
		message = "Tor's circuit-build-time history is saturated and clearnet egress is down. When auto-heal is enabled, its final step requests host-gated state recovery; otherwise enable auto-heal or ask an operator to run the recovery check."
	}
	return []Finding{{"tor-circuit-history", "fail", message}}, nil
}

func torProbeCommand(path string, args ...string) (bool, error) {
	output, err := exec.Command(path, args...).CombinedOutput()
	if unsupportedLaunch(err) || len(output) != 0 {
		return false, ErrUnsupportedProbeInput
	}
	return err == nil, nil
}

func torRecoveryAuth() (string, error) {
	first, err := rand.Int(rand.Reader, big.NewInt(32768))
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	second, err := rand.Int(rand.Reader, big.NewInt(32768))
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	return "tor-recover-" + strconv.Itoa(os.Getpid()) + "-" + first.String() + "-" + second.String(), nil
}

func torHistorySudoAllowed() (bool, error) {
	id, err := networkTool("id")
	if err != nil {
		return false, err
	}
	if id == "" {
		return false, ErrUnsupportedProbeInput
	}
	var diagnostics bytes.Buffer
	command := exec.Command(id, "-u")
	command.Stderr = &diagnostics
	output, runErr := command.Output()
	if unsupportedLaunch(runErr) || diagnostics.Len() != 0 {
		return false, ErrUnsupportedProbeInput
	}
	uid, valueErr := probeValue(string(output))
	if valueErr != nil {
		return false, valueErr
	}
	if uid == "0" {
		return true, nil
	}
	sudo, err := networkTool("sudo")
	if err != nil || sudo == "" {
		return false, err
	}
	output, runErr = exec.Command(sudo, "-n", "true").Output()
	if unsupportedLaunch(runErr) || len(output) != 0 {
		return false, ErrUnsupportedProbeInput
	}
	return runErr == nil, nil
}
