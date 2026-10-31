package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func networkTool(name string) (string, error) {
	for _, part := range filepath.SplitList(os.Getenv("PATH")) {
		if part == "" || !filepath.IsAbs(part) {
			return "", ErrUnsupportedProbeInput
		}
	}
	path, err := exec.LookPath(name)
	if errors.Is(err, exec.ErrDot) {
		return "", ErrUnsupportedProbeInput
	}
	if err != nil {
		return "", nil
	}
	return path, nil
}

func ContainerRunning(name string) (bool, error) {
	if strings.ContainsRune(name, 0) {
		return false, ErrUnsupportedProbeInput
	}
	path, err := networkTool("docker")
	if err != nil || path == "" {
		return false, err
	}
	output, runErr := exec.Command(path, "ps", "-q", "--filter", "name=^"+name+"$", "--filter", "status=running").Output()
	if unsupportedLaunch(runErr) {
		return false, ErrUnsupportedProbeInput
	}
	value, err := probeValue(string(output))
	return value != "", err
}

func MiningStackRunning() (bool, error) {
	for _, name := range []string{"p2pool", "monerod", "xmrig-proxy"} {
		running, err := ContainerRunning(name)
		if err != nil || running {
			return running, err
		}
	}
	return false, nil
}

func TorRunning(appliance bool) (Finding, error) {
	running, err := ContainerRunning("tor")
	if err != nil {
		return Finding{}, err
	}
	if running {
		return Finding{"tor-running", "ok", "Tor container is running — the privacy backbone is up."}, nil
	}
	mining, err := MiningStackRunning()
	if err != nil {
		return Finding{}, err
	}
	if mining {
		message := "The Tor container is DOWN while the mining stack is still running — the privacy backbone is dead: clearnet dials are no longer fail-closed and off-box connections (Healthchecks, Telegram, XvB, peers) have lost their Tor path. Restart it ('./pithead restart tor'; set tor.auto_heal:true to self-heal), or bring the stack down ('./pithead down')."
		if appliance {
			message = "The Tor container is DOWN while the mining stack is still running — the privacy backbone is dead: clearnet dials are no longer fail-closed and off-box connections (Healthchecks, Telegram, XvB, peers) have lost their Tor path. There is no dashboard control that restarts Tor on its own."
		}
		return Finding{"tor-running", "fail", message}, nil
	}
	message := "Tor container isn't running — the stack is down (expected after './pithead down')."
	if appliance {
		message = "Tor container isn't running — the mining stack is down, which is expected while it is stopped."
	}
	return Finding{"tor-running", "info", message}, nil
}

type StratumListening struct {
	Stratum
	Appliance bool
}

func (stratum StratumListening) Finding() (Finding, error) {
	running, err := ContainerRunning("xmrig-proxy")
	if err != nil {
		return Finding{}, err
	}
	if !running {
		return Finding{"stratum-listening", "info", "Stratum listen check skipped — xmrig-proxy isn't running (normal during a sync hold)."}, nil
	}
	ss, err := networkTool("ss")
	if err != nil {
		return Finding{}, err
	}
	if ss == "" {
		return Finding{"stratum-listening", "info", "Stratum listen check skipped — no 'ss' command (Linux-only)."}, nil
	}
	port, err := stratum.EffectivePort()
	if err != nil {
		return Finding{}, err
	}
	port, err = probeValue(port)
	if err != nil {
		return Finding{}, err
	}
	listening, err := stratumListener(ss, port)
	if err != nil {
		return Finding{}, err
	}
	if listening {
		return Finding{"stratum-listening", "ok", "Stratum :" + port + " is listening — workers can connect."}, nil
	}
	message := "xmrig-proxy is running but NOTHING is listening on :" + port + " — workers can't connect. Check './pithead logs xmrig-proxy' and " + networkDocsURL + "/docs/workers.md."
	if stratum.Appliance {
		message = "xmrig-proxy is running but NOTHING is listening on :" + port + " — workers can't connect. Read the xmrig-proxy log from the dashboard's diagnostics view, and see " + networkDocsURL + "/docs/workers.md."
	}
	return Finding{"stratum-listening", "fail", message}, nil
}

func stratumListener(ss, port string) (bool, error) {
	grep, err := networkTool("grep")
	if err != nil || grep == "" {
		return false, ErrUnsupportedProbeInput
	}
	read, write, err := os.Pipe()
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	defer read.Close()
	defer write.Close()
	producer := exec.Command(ss, "-Hltn")
	consumer := exec.Command(grep, "-q", ":"+port+" ")
	producer.Stdout, consumer.Stdin = write, read
	var stdout, stderr bytes.Buffer
	consumer.Stdout, consumer.Stderr = &stdout, &stderr
	if err := consumer.Start(); err != nil {
		return false, ErrUnsupportedProbeInput
	}
	startErr := producer.Start()
	read.Close()
	write.Close()
	var producerErr error
	if startErr == nil {
		producerErr = producer.Wait()
	}
	consumerErr := consumer.Wait()
	if startErr != nil || unsupportedLaunch(producerErr) || unsupportedLaunch(consumerErr) || stdout.Len() != 0 || stderr.Len() != 0 {
		return false, ErrUnsupportedProbeInput
	}
	return producerErr == nil && consumerErr == nil, nil
}

type TorClearnetEgress struct {
	NetworkPrefix string
	Appliance     bool
}

func (tor TorClearnetEgress) Finding() (Finding, error) {
	running, err := ContainerRunning("tor")
	if err != nil {
		return Finding{}, err
	}
	if !running {
		return Finding{"tor-clearnet-egress", "info", "Tor clearnet-egress check skipped — the tor container isn't running."}, nil
	}
	curl, err := networkTool("curl")
	if err != nil {
		return Finding{}, err
	}
	if curl == "" {
		return Finding{"tor-clearnet-egress", "info", "Tor clearnet-egress check skipped — no curl."}, nil
	}
	prefix, err := probeValue(tor.NetworkPrefix)
	if err != nil {
		return Finding{}, err
	}
	if prefix == "" {
		prefix = "172.28.0"
	}
	output, runErr := exec.Command(curl, "-fsS", "--max-time", "15", "--socks5-hostname", prefix+".25:9050", "-o", "/dev/null", "https://www.google.com/generate_204").Output()
	if unsupportedLaunch(runErr) || len(output) != 0 {
		return Finding{}, ErrUnsupportedProbeInput
	}
	if runErr == nil {
		return Finding{"tor-clearnet-egress", "ok", "Tor clearnet egress works — Healthchecks, Telegram, and XvB can reach their services."}, nil
	}
	message := "Tor is up but a clearnet request through its SOCKS timed out — Healthchecks pings, Telegram, and XvB stats may be down while mining still works. Check with a second target; run './pithead restart tor' for manual recovery, or set tor.auto_heal:true in config.json for bounded circuit refresh before one restart."
	if tor.Appliance {
		message = "Tor is up but a clearnet request through its SOCKS timed out — Healthchecks pings, Telegram, and XvB stats may be down while mining still works. Check with a second target; run './pithead restart tor' for manual recovery."
	}
	return Finding{"tor-clearnet-egress", "warn", message}, nil
}
