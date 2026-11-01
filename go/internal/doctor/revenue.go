package doctor

import (
	"os/exec"
	"regexp"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

var composeRevenueName = regexp.MustCompile(`^[0-9a-f]{12}_(.+)$`)

type RevenueContainers struct {
	MigrationHold bool
}

func RevenueContainerVerdict(name, state, status, chainHold string) (string, error) {
	if strings.ContainsRune(name+state+status+chainHold, 0) {
		return "", ErrUnsupportedProbeInput
	}
	if match := composeRevenueName.FindStringSubmatch(name); match != nil {
		name = match[1]
	}
	running := state == "running" || state == "" && strings.HasPrefix(status, "Up")
	if revenueChainContainer(name) {
		if chainHold == "1" && revenueContainerStopped(state, status) {
			return "ok", nil
		}
		if strings.Contains(status, "(unhealthy)") || strings.Contains(status, "(starting)") {
			return "fail:" + name + " is not ready (" + status + ") — a chain node must be up and healthy to commit", nil
		}
		if running {
			return "ok", nil
		}
		detail := status
		if detail == "" {
			detail = state
		}
		return "fail:" + name + " is down (" + detail + ") — a chain node down means the slot is not healthy to commit", nil
	}
	if revenueMinerContainer(name) {
		if revenueContainerStopped(state, status) {
			return "ok", nil
		}
		if strings.Contains(status, "(unhealthy)") {
			return "fail:" + name + " is running but unhealthy (" + status + ")", nil
		}
		if running {
			return "ok", nil
		}
		detail := status
		if detail == "" {
			detail = state
		}
		return "fail:" + name + " is not stopped for sync and is not running (" + detail + ")", nil
	}
	return "ok", nil
}

func (containers RevenueContainers) Findings() ([]Finding, error) {
	engine, err := networkTool(host.Engine())
	if err != nil || engine == "" {
		return nil, err
	}
	output, runErr := exec.Command(engine, "ps", "-a", "--format", `{{.Names}}\t{{.State}}\t{{.Status}}`).Output()
	if unsupportedLaunch(runErr) {
		return nil, ErrUnsupportedProbeInput
	}
	rows, err := probeValue(string(output))
	if err != nil {
		return nil, err
	}
	if runErr != nil {
		return nil, nil
	}
	if rows == "" {
		return nil, nil
	}
	findings := make([]Finding, 0, 2)
	hold := "0"
	if containers.MigrationHold {
		hold = "1"
		findings = append(findings, Finding{"revenue-containers", "info", "A data migration is pending — chain services are deliberately held until this slot commits."})
	}
	failed := false
	for _, row := range strings.Split(rows, "\n") {
		name, state, status := revenuePSRow(row)
		if name == "" {
			continue
		}
		verdict, verdictErr := RevenueContainerVerdict(name, state, status, hold)
		if verdictErr != nil {
			return nil, verdictErr
		}
		if strings.HasPrefix(verdict, "fail:") {
			findings = append(findings, Finding{"revenue-containers", "fail", strings.TrimPrefix(verdict, "fail:")})
			failed = true
		}
	}
	if !failed {
		findings = append(findings, Finding{"revenue-containers", "ok", "Revenue containers are healthy or holding for sync — none crashed."})
	}
	return findings, nil
}

func revenueContainerStopped(state, status string) bool {
	if state == "created" || state == "exited" || state == "stopped" {
		return true
	}
	return state == "" && (strings.HasPrefix(status, "Created") || strings.HasPrefix(status, "Exited") || strings.HasPrefix(status, "Stopped"))
}

func revenueChainContainer(name string) bool {
	return strings.Contains(" monerod tari wallet-rpc tari-wallet ", " "+name+" ")
}

func revenueMinerContainer(name string) bool {
	return strings.Contains(" p2pool xmrig-proxy ", " "+name+" ")
}

func revenuePSRow(row string) (string, string, string) {
	row = strings.TrimLeft(row, "\t")
	name, row := revenueReadField(row)
	state, status := revenueReadField(row)
	return name, state, strings.TrimRight(status, "\t")
}

func revenueReadField(row string) (string, string) {
	index := strings.IndexByte(row, '\t')
	if index < 0 {
		return row, ""
	}
	return row[:index], strings.TrimLeft(row[index:], "\t")
}
