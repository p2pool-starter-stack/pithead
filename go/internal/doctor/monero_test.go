package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type moneroFixture struct {
	dir       string
	running   string
	peers     string
	info      string
	header    string
	dockerLog string
	curlLog   string
}

func newMoneroFixture(t *testing.T) moneroFixture {
	t.Helper()
	dir := t.TempDir()
	fixture := moneroFixture{
		dir:       dir,
		running:   filepath.Join(dir, "running"),
		peers:     filepath.Join(dir, "peers"),
		info:      filepath.Join(dir, "info"),
		header:    filepath.Join(dir, "header"),
		dockerLog: filepath.Join(dir, "docker.log"),
		curlLog:   filepath.Join(dir, "curl.log"),
	}
	for path, value := range map[string]string{
		fixture.running: "container-id\n",
		fixture.peers:   `{"outgoing":4,"incoming":2}`,
		fixture.info:    `{"status":"OK","synchronized":true}`,
		fixture.header:  `{"result":{"block_header":{"timestamp":1000}}}`,
	} {
		if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeMoneroTool(t, dir, "docker", `#!/bin/sh
printf '%s\n' "$@" >> "$MONERO_DOCKER_LOG"
if [ "$1" = "ps" ]; then
    /bin/cat "$MONERO_RUNNING"
    exit "${MONERO_PS_EXIT:-0}"
fi
/bin/cat "$MONERO_PEERS"
exit "${MONERO_PEER_EXIT:-0}"
`)
	writeMoneroTool(t, dir, "curl", `#!/bin/sh
printf '%s\n' "$@" >> "$MONERO_CURL_LOG"
for arg do last=$arg; done
case "$last" in
    */get_info) /bin/cat "$MONERO_INFO"; exit "${MONERO_INFO_EXIT:-0}" ;;
    */json_rpc) /bin/cat "$MONERO_HEADER"; exit "${MONERO_HEADER_EXIT:-0}" ;;
esac
exit 64
`)
	writeMoneroTool(t, dir, "jq", "#!/bin/sh\nexit 0\n")
	t.Setenv("PATH", dir)
	t.Setenv("MONERO_RUNNING", fixture.running)
	t.Setenv("MONERO_PEERS", fixture.peers)
	t.Setenv("MONERO_INFO", fixture.info)
	t.Setenv("MONERO_HEADER", fixture.header)
	t.Setenv("MONERO_DOCKER_LOG", fixture.dockerLog)
	t.Setenv("MONERO_CURL_LOG", fixture.curlLog)
	return fixture
}

func writeMoneroTool(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}

func (fixture moneroFixture) set(t *testing.T, path, value string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestMoneroRPCFindingsAndArguments(t *testing.T) {
	fixture := newMoneroFixture(t)
	rpc := MoneroRPC{User: "doctor-user\n", Password: "doctor-pass\n", URL: "http://monero.invalid\n", Now: 1100}
	got, err := rpc.Findings()
	want := []Finding{
		{"monerod-peers-and-tip", "ok", "monerod peers: 4 out / 2 in, last block 100s ago."},
		{"monerod-synchronized", "ok", "monerod reports synchronized with the Monero network."},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Findings() result mismatch: error=%v", err)
	}
	dockerArgs, err := os.ReadFile(fixture.dockerLog)
	if err != nil {
		t.Fatal(err)
	}
	wantDocker := "ps\n-q\n--filter\nname=^monerod$\n--filter\nstatus=running\nexec\nmonerod\n/usr/local/bin/monerod-peers.sh\n"
	if string(dockerArgs) != wantDocker {
		t.Fatal("docker argument order mismatch")
	}
	curlArgs, err := os.ReadFile(fixture.curlLog)
	if err != nil {
		t.Fatal(err)
	}
	args := string(curlArgs)
	if strings.Count(args, "-u\n") != 2 || strings.Count(args, "--digest\n") != 2 ||
		!strings.Contains(args, "http://monero.invalid/get_info\n") || !strings.Contains(args, "http://monero.invalid/json_rpc\n") ||
		!strings.Contains(args, "Content-Type: application/json\n") || !strings.Contains(args, "get_last_block_header") {
		t.Fatal("curl argument order mismatch")
	}
}

func TestMoneroRPCPeerAndTipFindings(t *testing.T) {
	tests := []struct {
		name      string
		peers     string
		header    string
		appliance bool
		want      []Finding
	}{
		{"no-reading", `{}`, `{"result":{"block_header":{"timestamp":1000}}}`, false, []Finding{{"monerod-peers-and-tip", "info", "monerod peers: no reading (the in-container helper gave none), last block 1901s ago."}, {"monerod-peers-and-tip", "warn", "monerod's last block is 1901s old — a stalled node mines on a stale tip; if it stays like this, './pithead restart monerod' re-dials."}}},
		{"zero-peers", `{"outgoing":0,"incoming":3}`, `{"result":{"block_header":{"timestamp":2900}}}`, false, []Finding{{"monerod-peers-and-tip", "warn", "monerod peers: 0 out / 3 in, last block 1s ago — an isolated or stalled node mines on a stale tip; if it stays like this, './pithead restart monerod' re-dials."}}},
		{"appliance-stale", `{"outgoing":4,"incoming":3}`, `{"result":{"block_header":{"timestamp":1000}}}`, true, []Finding{{"monerod-peers-and-tip", "warn", "monerod peers: 4 out / 3 in, last block 1901s ago — the node may be isolated or stale; check its container logs in the dashboard."}}},
		{"future-tip", `{"outgoing":4,"incoming":3}`, `{"result":{"block_header":{"timestamp":4000}}}`, false, []Finding{{"monerod-peers-and-tip", "ok", "monerod peers: 4 out / 3 in, last block -1099s ago."}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newMoneroFixture(t)
			fixture.set(t, fixture.peers, test.peers)
			fixture.set(t, fixture.header, test.header)
			got, err := (MoneroRPC{URL: "http://monero.invalid", Now: 2901, Appliance: test.appliance}).PeersAndTip()
			if err != nil || !reflect.DeepEqual(got, test.want) {
				t.Fatalf("PeersAndTip() = %+v, %v; want %+v", got, err, test.want)
			}
		})
	}
}

func TestMoneroRPCGatesAndPartialResponses(t *testing.T) {
	t.Run("not-running", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		fixture.set(t, fixture.running, "")
		got, err := (MoneroRPC{User: "\x00"}).Findings()
		if err != nil || got != nil {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("missing-tool-before-config", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		if err := os.Remove(filepath.Join(fixture.dir, "jq")); err != nil {
			t.Fatal(err)
		}
		got, err := (MoneroRPC{User: "\x00"}).Findings()
		want := []Finding{{"monerod-synchronized", "info", "Monero sync check skipped — needs curl and jq."}}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("empty-info", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		fixture.set(t, fixture.info, "\n")
		got, err := (MoneroRPC{}).Findings()
		want := []Finding{{"monerod-synchronized", "info", "Monero sync check skipped — monerod's RPC did not answer (the container table above shows whether it is still starting)."}}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("nonzero-partial-info", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		fixture.set(t, fixture.info, `{"status":"BUSY","synchronized":false}`)
		t.Setenv("MONERO_INFO_EXIT", "7")
		got, err := (MoneroRPC{Now: 1100, Appliance: true}).Findings()
		if err != nil || len(got) != 2 || got[0].Status != "ok" || got[1].Status != "warn" {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("failed-helper-is-no-reading", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		fixture.set(t, fixture.peers, "not-json")
		t.Setenv("MONERO_PEER_EXIT", "9")
		got, err := (MoneroRPC{URL: "http://monero.invalid", Now: 1100}).PeersAndTip()
		if err != nil || len(got) != 1 || got[0].Status != "info" {
			t.Fatalf("PeersAndTip() = %+v, %v", got, err)
		}
	})
}

func TestMoneroRPCUnsupportedInputs(t *testing.T) {
	t.Run("direct-raw-arguments", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		_, err := (MoneroRPC{User: "user\n", Password: "pass\n", URL: "http://monero.invalid\n", Now: 1100}).PeersAndTip()
		if err != nil {
			t.Fatal(err)
		}
		args, err := os.ReadFile(fixture.curlLog)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(args), "user\n:pass\n") || !strings.Contains(string(args), "http://monero.invalid\n/json_rpc") {
			t.Fatal("direct arguments were normalized")
		}
	})
	t.Run("multiple-json", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		fixture.set(t, fixture.info, `{"status":"OK","synchronized":true} {"status":"OK","synchronized":true}`)
		got, err := (MoneroRPC{}).Findings()
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("nul-partial", func(t *testing.T) {
		fixture := newMoneroFixture(t)
		fixture.set(t, fixture.info, "{\x00}")
		t.Setenv("MONERO_INFO_EXIT", "7")
		got, err := (MoneroRPC{}).Findings()
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("missing-direct-tool", func(t *testing.T) {
		dir := t.TempDir()
		t.Setenv("PATH", dir)
		got, err := (MoneroRPC{}).PeersAndTip()
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("PeersAndTip() = %+v, %v", got, err)
		}
	})
}

func TestMoneroJSONNumberSemantics(t *testing.T) {
	if got, err := moneroPeerCounts(`{"outgoing":1e2,"incoming":2.0}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroPeerCounts() = %q, %v", got, err)
	}
	if got, err := moneroPeerCounts(`{"outgoing":-1,"incoming":2}`); err != nil || got != "" {
		t.Fatalf("moneroPeerCounts(negative) = %q, %v", got, err)
	}
	if got, err := moneroPeerCounts(`{"outgoing":-0,"incoming":2}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroPeerCounts(negative zero) = %q, %v", got, err)
	}
	if got, err := moneroPeerCounts(`{"outgoing":1.5,"incoming":2}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroPeerCounts(fraction) = %q, %v", got, err)
	}
	if got, err := moneroPeerCounts(`{"outgoing":9007199254740992,"incoming":2}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroPeerCounts(precision boundary) = %q, %v", got, err)
	}
	if got, err := moneroTimestamp(`{"result":{"block_header":{"timestamp":1e3}}}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroTimestamp() = %q, %v", got, err)
	}
	if got, err := moneroTimestamp(`{"result":{"block_header":{"timestamp":1.5}}}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroTimestamp(fraction) = %q, %v", got, err)
	}
	if got, err := moneroTimestamp(`{"result":{"block_header":{"timestamp":199900.0}}}`); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("moneroTimestamp(decimal) = %q, %v", got, err)
	}
}

func TestMoneroJSONEncodingFallback(t *testing.T) {
	for _, value := range []string{
		`{"status":"OK","synchronized":true,"extra":"\ud800"}`,
		`{"status":"\u004fK","synchronized":true}`,
		"{\"status\":\"OK\",\"synchronized\":true,\"extra\":\"\xff\"}",
		`{"status":"OK","synchronized":true,"extra":NaN}`,
		`{"status":"OK","synchronized":true,"extra":Infinity}`,
		`not-json`,
	} {
		if got, err := moneroSynchronized(value); got || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatal("expected JSON encoding fallback")
		}
	}
}
