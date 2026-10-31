package status

import (
	"fmt"
	"os/exec"
	"sort"
	"strings"
)

func (r *Runner) services() int {
	ps := exec.Command("docker", "compose", "ps")
	ps.Dir, ps.Stdout, ps.Stderr = r.Dir, r.Out, r.Err
	_ = ps.Run()
	fmt.Fprintln(r.Out)
	r.log("Service health check:")
	expected, _ := r.output("docker", "compose", "config", "--services")
	profiles := r.get("COMPOSE_PROFILES")
	if expected == "" {
		r.warn("Could not read the service list from compose — is Docker running?")
		return 1
	}
	services := strings.Split(expected, "\n")
	sort.Strings(services)
	problems := 0
	proxyState, poolState := "", ""
	nodeDown := false
	restarting, err := r.restartingNames()
	if err != nil {
		r.row(r.red, "✗", "containers", "restart observation failed")
		problems++
	}
	chainHold := r.migrationHold()
	for _, service := range services {
		if service == "" || service == "monerod" && !strings.Contains(","+profiles+",", ",local_node,") || service == "tari" && !strings.Contains(","+profiles+",", ",local_tari,") {
			continue
		}
		cid, _ := r.output("docker", "compose", "ps", "-aq", service)
		cid = strings.SplitN(cid, "\n", 2)[0]
		state, health := "missing", "none"
		if cid != "" {
			info, err := r.output("docker", "inspect", "--format", "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", cid)
			if err != nil {
				info += "unknown none"
			}
			state = strings.SplitN(info, " ", 2)[0]
			parts := strings.Split(info, " ")
			health = parts[len(parts)-1]
		}
		if contains(restarting, service) {
			r.row(r.red, "✗", service, "restarting (possible crash loop — check logs)")
			problems++
			continue
		}
		if chainHold && contains([]string{"monerod", "tari", "wallet-rpc", "tari-wallet"}, service) && (state == "missing" || stopped(state)) {
			r.row(r.yellow, "⚠", service, state+" — intentionally held until this slot commits its data migration")
			continue
		}
		if service == "monerod" || service == "tari" {
			if state != "running" || health != "healthy" && health != "none" {
				nodeDown = true
			}
		}
		if service == "xmrig-proxy" && stopped(state) {
			proxyState = state
			continue
		}
		if service == "p2pool" && stopped(state) {
			poolState = state
			continue
		}
		switch state {
		case "running":
			switch health {
			case "healthy", "none":
				r.row(r.green, "✓", service, "running")
			case "starting":
				r.row(r.yellow, "…", service, "starting (health check pending)")
			default:
				r.row(r.yellow, "⚠", service, "running but UNHEALTHY")
				problems++
			}
		case "restarting":
			r.row(r.red, "✗", service, "restarting (possible crash loop — check logs)")
			problems++
		default:
			r.row(r.red, "✗", service, state)
			problems++
		}
	}
	r.chainStatus("monero")
	r.chainStatus("tari")
	syncFlag := ""
	if poolState+proxyState != "" {
		syncFlag = r.dashboardSyncing()
	}
	for _, held := range [][2]string{{"p2pool", poolState}, {"xmrig-proxy", proxyState}} {
		if held[1] == "" {
			continue
		}
		why := "held until the required chains finish syncing — check the dashboard"
		if nodeDown {
			why = "a node is down, so workers were rejected to fail over to backups"
		} else if syncFlag == "false" {
			why = "the dashboard reports no chain sync in progress — check the dashboard and the container logs"
		}
		r.row(r.yellow, "⚠", held[0], held[1]+" — likely intentional: "+why)
	}
	r.syncProgress()
	fmt.Fprintln(r.Out)
	r.clearnetBanner()
	if onion := r.onionStatus(); onion != "" {
		r.log("Dashboard onion (remote access): " + onion)
	}
	r.announceStratumAuth()
	r.announceStratumTLS()
	if problems != 0 {
		r.warn(fmt.Sprintf("%d service(s) need attention (see above).", problems))
		return 1
	}
	r.log("All expected services are up.")
	return 0
}

func stopped(state string) bool {
	return state == "created" || state == "exited" || state == "stopped"
}

func contains(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}
