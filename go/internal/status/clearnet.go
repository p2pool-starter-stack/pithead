package status

import (
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"
)

func (r *Runner) clearnetBanner() {
	var names []string
	for _, chain := range []string{"monero", "tari"} {
		if r.get(strings.ToUpper(chain)+"_CLEARNET_SYNC") == "true" && !r.torAttested(chain) {
			if chain == "monero" {
				names = append(names, "Monero")
			} else {
				names = append(names, "Tari")
			}
		}
	}
	if len(names) == 0 {
		return
	}
	fmt.Fprintf(r.Err, "%s========================================================================%s\n", r.yellow, r.reset)
	fmt.Fprintf(r.Err, "%s[!] CLEARNET INITIAL SYNC OR TOR TRANSITION PENDING%s\n", r.yellow, r.reset)
	fmt.Fprintf(r.Err, "    %s P2P may expose this host's IP until the host verifies the Tor switch.\n", strings.Join(names, " + "))
	fmt.Fprintln(r.Err, "    Monero tx-broadcast stays on Tor; wallets are never exposed.")
	fmt.Fprintln(r.Err, "    The dashboard retries the transition automatically after sync.")
	fmt.Fprintf(r.Err, "%s========================================================================%s\n", r.yellow, r.reset)
}

func (r *Runner) torAttested(chain string) bool {
	stateDir, controlDir := r.getQuiet("CLEARNET_STATE_DIR"), r.getQuiet("CONTROL_DIR")
	if stateDir == "" {
		stateDir = filepath.Join(r.Dir, "data", "clearnet-state")
	}
	if controlDir == "" {
		controlDir = filepath.Join(r.Dir, "data", "control")
	}
	file, err := os.OpenFile(r.path(filepath.Join(stateDir, chain+".synced")), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return false
	}
	info, statErr := file.Stat()
	marker, readErr := io.ReadAll(io.LimitReader(file, 38))
	_ = file.Close()
	if statErr != nil || readErr != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 || !utf8.Valid(marker) {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 {
		return false
	}
	data, err := os.ReadFile(r.path(filepath.Join(controlDir, "results", "clearnet-"+chain+"-tor.json")))
	return err == nil && attestationMatches(strings.TrimSpace(string(marker)), stat.Ino, ctimeNS(stat), data)
}

func attestationMatches(marker string, inode uint64, ctime int64, data []byte) bool {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var result map[string]any
	if decoder.Decode(&result) != nil || decoder.Decode(new(any)) != io.EOF || len(result) != 4 || result["status"] != "verified" || result["marker"] != marker {
		return false
	}
	return numberMatches(result["inode"], new(big.Int).SetUint64(inode)) && numberMatches(result["ctime_ns"], big.NewInt(ctime))
}

func numberMatches(value any, expected *big.Int) bool {
	number, ok := value.(json.Number)
	if !ok {
		return false
	}
	if !strings.ContainsAny(number.String(), ".eE") {
		actual, ok := new(big.Int).SetString(number.String(), 10)
		return ok && actual.Cmp(expected) == 0
	}
	value64, err := strconv.ParseFloat(number.String(), 64)
	if err != nil {
		return false
	}
	actual := new(big.Rat).SetFloat64(value64)
	return actual != nil && actual.Cmp(new(big.Rat).SetInt(expected)) == 0
}
