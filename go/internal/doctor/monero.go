package doctor

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"unicode/utf8"
)

type MoneroRPC struct {
	User      string
	Password  string
	URL       string
	Now       int64
	Appliance bool
}

func (rpc MoneroRPC) Findings() ([]Finding, error) {
	running, err := ContainerRunning("monerod")
	if err != nil || !running {
		return nil, err
	}
	curl, err := networkTool("curl")
	if err != nil {
		return nil, err
	}
	jq, err := networkTool("jq")
	if err != nil {
		return nil, err
	}
	if curl == "" || jq == "" {
		return []Finding{{"monerod-synchronized", "info", "Monero sync check skipped — needs curl and jq."}}, nil
	}
	rpc.User, err = probeValue(rpc.User)
	if err != nil {
		return nil, err
	}
	rpc.Password, err = probeValue(rpc.Password)
	if err != nil {
		return nil, err
	}
	rpc.URL, err = probeValue(rpc.URL)
	if err != nil {
		return nil, err
	}
	if rpc.URL == "" {
		rpc.URL = "http://127.0.0.1:18081"
	}
	body, err := rpc.curl(curl, false)
	if err != nil {
		return nil, err
	}
	if body == "" {
		return []Finding{{"monerod-synchronized", "info", "Monero sync check skipped — monerod's RPC did not answer (the container table above shows whether it is still starting)."}}, nil
	}
	findings, err := rpc.PeersAndTip()
	if err != nil {
		return nil, err
	}
	synced, err := moneroSynchronized(body)
	if err != nil {
		return nil, err
	}
	if synced {
		return append(findings, Finding{"monerod-synchronized", "ok", "monerod reports synchronized with the Monero network."}), nil
	}
	message := "monerod is running but reports NOT synchronized — normal during initial sync; if it stays like this on a previously-synced node (peers lost after a Tor restart), './pithead restart monerod' re-dials and recovers in about a minute."
	if rpc.Appliance {
		message = "monerod is running but reports NOT synchronized — normal during initial sync. If it stays like this on a node that was synced before, its peers were lost after a Tor restart; there is no dashboard control that restarts monerod on its own."
	}
	return append(findings, Finding{"monerod-synchronized", "warn", message}), nil
}

func (rpc MoneroRPC) PeersAndTip() ([]Finding, error) {
	if strings.ContainsRune(rpc.User+rpc.Password+rpc.URL, 0) {
		return nil, ErrUnsupportedProbeInput
	}
	counts, err := rpc.PeerCounts()
	if err != nil {
		return nil, err
	}
	curl, err := networkTool("curl")
	if err != nil || curl == "" {
		return nil, ErrUnsupportedProbeInput
	}
	body, err := rpc.curl(curl, true)
	if err != nil {
		return nil, err
	}
	timestamp, err := moneroTimestamp(body)
	if err != nil {
		return nil, err
	}
	age, note := int64(0), ""
	if timestamp != "" {
		value, _ := strconv.ParseInt(timestamp, 10, 64)
		age = rpc.Now - value
		note = fmt.Sprintf(", last block %ds ago", age)
	}
	fields := strings.Fields(counts)
	if len(fields) == 0 {
		findings := []Finding{{"monerod-peers-and-tip", "info", "monerod peers: no reading (the in-container helper gave none)" + note + "."}}
		if timestamp != "" && age > 1800 {
			findings = append(findings, rpc.staleFinding("monerod's last block is "+strconv.FormatInt(age, 10)+"s old"))
		}
		return findings, nil
	}
	out, in := fields[0], "?"
	if len(fields) > 1 {
		in = fields[1]
	}
	isolated := out == "0" || timestamp != "" && age > 1800
	message := "monerod peers: " + out + " out / " + in + " in" + note
	if isolated {
		if rpc.Appliance {
			message += " — the node may be isolated or stale; check its container logs in the dashboard."
		} else {
			message += " — an isolated or stalled node mines on a stale tip; if it stays like this, './pithead restart monerod' re-dials."
		}
		return []Finding{{"monerod-peers-and-tip", "warn", message}}, nil
	}
	return []Finding{{"monerod-peers-and-tip", "ok", message + "."}}, nil
}

func (rpc MoneroRPC) PeerCounts() (string, error) {
	docker, err := networkTool("docker")
	if err != nil || docker == "" {
		return "", ErrUnsupportedProbeInput
	}
	output, runErr := exec.Command(docker, "exec", "monerod", "/usr/local/bin/monerod-peers.sh").Output()
	if unsupportedLaunch(runErr) || bytes.IndexByte(output, 0) >= 0 {
		return "", ErrUnsupportedProbeInput
	}
	if runErr != nil {
		return "", nil
	}
	jq, err := networkTool("jq")
	if err != nil || jq == "" {
		return "", ErrUnsupportedProbeInput
	}
	value, err := moneroPeerCounts(string(output))
	if err != nil {
		return "", err
	}
	return value, nil
}

func (rpc MoneroRPC) curl(path string, header bool) (string, error) {
	args := []string{"-fsS", "--max-time", "8"}
	if rpc.User != "" {
		args = append(args, "--digest", "-u", rpc.User+":"+rpc.Password)
	}
	if header {
		args = append(args, "-H", "Content-Type: application/json", "-d", `{"jsonrpc":"2.0","id":"0","method":"get_last_block_header"}`, rpc.URL+"/json_rpc")
	} else {
		args = append(args, rpc.URL+"/get_info")
	}
	output, runErr := exec.Command(path, args...).Output()
	if unsupportedLaunch(runErr) || bytes.IndexByte(output, 0) >= 0 {
		return "", ErrUnsupportedProbeInput
	}
	return strings.TrimRight(string(output), "\n"), nil
}

func (rpc MoneroRPC) staleFinding(subject string) Finding {
	message := subject + " — a stalled node mines on a stale tip; if it stays like this, './pithead restart monerod' re-dials."
	if rpc.Appliance {
		message = subject + " — the node may be stale; check its container logs in the dashboard."
	}
	return Finding{"monerod-peers-and-tip", "warn", message}
}

func moneroSynchronized(value string) (bool, error) {
	decoded, valid, err := moneroJSON(value)
	if err != nil || !valid {
		return false, err
	}
	object, ok := decoded.(map[string]any)
	if !ok {
		return false, nil
	}
	status, statusOK := object["status"].(string)
	synchronized, synchronizedOK := object["synchronized"].(bool)
	return statusOK && synchronizedOK && status == "OK" && synchronized, nil
}

func moneroPeerCounts(value string) (string, error) {
	decoded, valid, err := moneroJSON(value)
	if err != nil || !valid {
		return "", err
	}
	object, ok := decoded.(map[string]any)
	if !ok {
		return "", nil
	}
	out, outOK, err := moneroCount(object["outgoing"])
	if err != nil || !outOK {
		return "", err
	}
	in, inOK, err := moneroCount(object["incoming"])
	if err != nil || !inOK {
		return "", err
	}
	return out + " " + in, nil
}

func moneroTimestamp(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	decoded, valid, err := moneroJSON(value)
	if err != nil || !valid {
		return "", err
	}
	object, ok := decoded.(map[string]any)
	if !ok {
		return "", nil
	}
	result, ok := object["result"].(map[string]any)
	if !ok {
		return "", nil
	}
	header, ok := result["block_header"].(map[string]any)
	if !ok {
		return "", nil
	}
	number, ok := header["timestamp"].(json.Number)
	if !ok {
		return "", nil
	}
	text := number.String()
	if strings.HasPrefix(text, "-") {
		return "", nil
	}
	if !digits(text) {
		return "", ErrUnsupportedProbeInput
	}
	if len(text) > 10 {
		return "", nil
	}
	valueInt, err := strconv.ParseInt(text, 10, 64)
	if err != nil || valueInt <= 0 || valueInt > 9999999999 {
		return "", nil
	}
	return text, nil
}

func moneroCount(value any) (string, bool, error) {
	number, ok := value.(json.Number)
	if !ok {
		return "", false, nil
	}
	text := number.String()
	if strings.HasPrefix(text, "-") {
		if !digits(strings.TrimPrefix(text, "-")) || text == "-0" {
			return "", false, ErrUnsupportedProbeInput
		}
		return "", false, nil
	}
	if !digits(text) {
		return "", false, ErrUnsupportedProbeInput
	}
	integer, err := strconv.ParseUint(text, 10, 64)
	if err != nil || integer > 9007199254740991 {
		return "", false, ErrUnsupportedProbeInput
	}
	return text, true, nil
}

func moneroJSON(value string) (any, bool, error) {
	if !utf8.ValidString(value) || strings.Contains(value, `\u`) {
		return nil, false, ErrUnsupportedProbeInput
	}
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	var decoded any
	if err := decoder.Decode(&decoded); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, false, nil
		}
		return nil, false, ErrUnsupportedProbeInput
	}
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return decoded, true, nil
	}
	return nil, false, ErrUnsupportedProbeInput
}
