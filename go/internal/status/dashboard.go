package status

import (
	"fmt"
	"os/exec"
	"strings"
)

const stateURL = "http://127.0.0.1:8000/api/state"

func (r *Runner) chainStatus(chain string) {
	if _, err := exec.LookPath("curl"); err != nil {
		return
	}
	if _, err := exec.LookPath("jq"); err != nil {
		return
	}
	var filter string
	switch chain {
	case "monero":
		filter = `.monero.health // empty | select(.level == "green" or .level == "red") | [.level, ((.reasons | join("; ")) + " — next: " + .advice)] | @tsv`
	case "tari":
		filter = `.tari.health // empty | [.level, ((.reasons | join("; ")) + " — next: " + .advice)] | @tsv`
	default:
		return
	}
	body, _ := r.output("curl", "-fsS", "--max-time", "5", stateURL)
	verdict, _ := r.filter(body, "-r", filter)
	if verdict == "" {
		return
	}
	level, detail, ok := strings.Cut(verdict, "\t")
	if !ok {
		return
	}
	if chain == "monero" {
		if level == "green" {
			r.row(r.green, "✓", "monero chain", "at the tip, with peers")
		} else {
			r.row(r.red, "✗", "monero chain", "NOT following the chain: "+detail)
		}
		return
	}
	switch level {
	case "green":
		r.row(r.green, "✓", "tari chain", "no degraded signal confirmed")
	case "amber":
		r.row(r.yellow, "⚠", "tari chain", detail)
	default:
		r.row(r.red, "✗", "tari chain", "NOT following the chain: "+detail)
	}
}

func (r *Runner) dashboardSyncing() string {
	if _, err := exec.LookPath("jq"); err != nil {
		return ""
	}
	body, _ := r.output("curl", "-fsS", "--max-time", "3", stateURL)
	value, _ := r.filter(body, "-er", `.syncing | if type == "boolean" then tostring else empty end`)
	return value
}

func (r *Runner) syncProgress() {
	if _, err := exec.LookPath("jq"); err != nil {
		return
	}
	tariRequired := r.get("TARI_REQUIRED")
	if tariRequired == "" {
		tariRequired = "true"
	}
	body, err := r.output("curl", "-fsS", "--max-time", "3", stateURL)
	if err != nil {
		return
	}
	rows, err := r.filter(body, "-r", "--arg", "tari_required", tariRequired, `
        select(.syncing == true) | (.sync // {}) | to_entries[]
        | select(.value.state != "done")
        | select(.key != "tari" or $tari_required != "false")
        | [.key,
           (.value.state // "loading"),
           (.value.percent // 0),
           (.value.current // 0),
           (.value.target // 0),
           (.value.remaining // 0)]
        | @tsv`)
	if err != nil || rows == "" {
		return
	}
	r.log("Chain sync in progress — the miner is held until it completes:")
	for _, line := range strings.Split(rows, "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 6 || fields[0] == "" {
			continue
		}
		if fields[1] == "syncing" {
			r.row(r.yellow, "…", fields[0], fmt.Sprintf("%s%% (%s / %s blocks, %s to go)", fields[2], fields[3], fields[4], fields[5]))
		} else {
			r.row(r.yellow, "…", fields[0], "discovering the target height…")
		}
	}
}
