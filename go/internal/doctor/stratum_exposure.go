package doctor

import (
	"bytes"
	"errors"
	"os/exec"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

type StratumExposure struct {
	Stratum
	Password  string
	TLS       string
	Appliance bool
}

func (exposure StratumExposure) Findings() ([]Finding, error) {
	bind, port, available, err := exposure.inputs()
	if err != nil {
		return nil, err
	}
	if !available {
		return []Finding{{"stratum-exposure", "info", "Skipped public-IP exposure check (no 'ip' command; Linux-only)."}}, nil
	}
	public, err := exposure.publicIPs()
	if err != nil {
		return nil, err
	}
	narrowed, err := exposureNarrowed(bind, public)
	if err != nil {
		return nil, err
	}
	if narrowed {
		return []Finding{{"stratum-exposure", "ok", "Stratum :" + port + " bound to " + bind + " (not all interfaces) — not publicly exposed."}}, nil
	}
	if public == "" {
		return []Finding{{"stratum-exposure", "ok", "No public IP on host interfaces — stratum :" + port + " isn't directly internet-exposed."}}, nil
	}
	password, err := probeValue(exposure.Password)
	if err != nil {
		return nil, err
	}
	tls, err := probeValue(exposure.TLS)
	if err != nil {
		return nil, err
	}
	tlsEnabled, err := exposureTLS(tls)
	if err != nil {
		return nil, err
	}
	return []Finding{exposure.finding(port, password != "", tlsEnabled)}, nil
}

func (exposure StratumExposure) Warnings() ([]string, error) {
	bind, port, available, err := exposure.inputs()
	if err != nil {
		return nil, err
	}
	if !available {
		return nil, nil
	}
	public, err := exposure.publicIPs()
	if err != nil {
		return nil, err
	}
	narrowed, err := exposureNarrowed(bind, public)
	if err != nil {
		return nil, err
	}
	if narrowed {
		return nil, nil
	}
	public = strings.TrimRight(public, "\n")
	if public == "" {
		return nil, nil
	}
	public = strings.ReplaceAll(public, "\n", ", ")
	message := "This host appears to have a public IP (" + public + "). The stratum port " + port + " is unauthenticated by default and cleartext — firewall it to your LAN, set p2pool.stratum_bind to a LAN IP / 127.0.0.1, and/or require a p2pool.stratum_password. See " + networkDocsURL + "/docs/workers.md#firewall."
	if strings.Contains(message, "\\") {
		return nil, ErrUnsupportedProbeInput
	}
	return []string{message}, nil
}

func (exposure StratumExposure) inputs() (string, string, bool, error) {
	bind, err := exposure.EffectiveBind()
	if err != nil {
		return "", "", false, err
	}
	port, err := exposure.EffectivePort()
	if err != nil {
		return "", "", false, err
	}
	port, err = probeValue(port)
	if err != nil {
		return "", "", false, err
	}
	ip, err := networkTool("ip")
	if err != nil {
		return "", "", false, err
	}
	if ip == "" {
		return bind, port, false, nil
	}
	return bind, port, true, nil
}

func (exposure StratumExposure) publicIPs() (string, error) {
	public, err := host.PublicIPs()
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	return strings.TrimRight(public, "\n"), nil
}

func addressLine(addresses, target string) bool {
	for _, address := range strings.Split(addresses, "\n") {
		for _, pattern := range strings.Split(target, "\n") {
			if address == pattern {
				return true
			}
		}
	}
	return false
}

func exposureNarrowed(bind, public string) (bool, error) {
	if bind == "0.0.0.0" || bind == "" {
		return false, nil
	}
	if strings.HasPrefix(bind, "-") || len(public) > 512 {
		return false, ErrUnsupportedProbeInput
	}
	grep, err := networkTool("grep")
	if err != nil || grep == "" {
		return false, ErrUnsupportedProbeInput
	}
	return !addressLine(public, bind), nil
}

func exposureTLS(value string) (bool, error) {
	tr, err := networkTool("tr")
	if err != nil || tr == "" {
		return false, ErrUnsupportedProbeInput
	}
	command := exec.Command(tr, "[:upper:]", "[:lower:]")
	command.Stdin = strings.NewReader(value)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	runErr := command.Run()
	var exitErr *exec.ExitError
	if runErr != nil && (!errors.As(runErr, &exitErr) || exitErr.ExitCode() < 0) {
		return false, ErrUnsupportedProbeInput
	}
	if stderr.Len() != 0 || bytes.IndexByte(stdout.Bytes(), 0) >= 0 {
		return false, ErrUnsupportedProbeInput
	}
	switch strings.TrimRight(stdout.String(), "\n") {
	case "true", "1", "yes", "on":
		return true, nil
	default:
		return false, nil
	}
}

func (exposure StratumExposure) finding(port string, password, tls bool) Finding {
	if password && tls {
		return Finding{"stratum-exposure", "info", "This host appears to have a public IP. Stratum :" + port + " has a password and TLS available; rigs not switched to TLS still connect in cleartext. Restrict access at your router to your network."}
	}
	if password {
		message := "This host appears to have a public IP. Stratum :" + port + " requires a password but is still cleartext — firewall it to your LAN, narrow p2pool.stratum_bind, and enable p2pool.stratum_tls on the stack and TLS on each rig. See " + networkDocsURL + "/docs/workers.md#firewall."
		if exposure.Appliance {
			message = "This machine appears to have a public IP. Stratum :" + port + " requires a password but is still cleartext. Block that port at your router so only your network can reach it. Open Configuration to narrow the listen address or enable stratum TLS, then complete the confirmation step and switch each rig to TLS."
		}
		return Finding{"stratum-exposure", "warn", message}
	}
	if tls {
		message := "This host appears to have a public IP. Stratum :" + port + " offers TLS, but rigs not switched to TLS still connect in cleartext without authentication — firewall it to your LAN, narrow p2pool.stratum_bind, and require a p2pool.stratum_password. See " + networkDocsURL + "/docs/workers.md#firewall."
		if exposure.Appliance {
			message = "This machine appears to have a public IP. Stratum :" + port + " offers TLS, but rigs not switched to TLS still connect in cleartext without authentication. Block that port at your router so only your network can reach it. Open Configuration to narrow the listen address or require a stratum password, then complete the confirmation step and switch each rig to TLS."
		}
		return Finding{"stratum-exposure", "warn", message}
	}
	message := "This host appears to have a public IP. The stratum port " + port + " is unauthenticated by default and cleartext — firewall it to your LAN, set p2pool.stratum_bind to a LAN IP / 127.0.0.1, and/or require a p2pool.stratum_password. See " + networkDocsURL + "/docs/workers.md#firewall."
	if exposure.Appliance {
		message = "This machine appears to have a public IP, and the stratum port " + port + " is unauthenticated and cleartext by default — anything on the internet can reach it. Block that port at your router so only your network can reach it. Open Configuration to narrow the listen address or require a stratum password, then complete the confirmation step."
	}
	return Finding{"stratum-exposure", "warn", message}
}
