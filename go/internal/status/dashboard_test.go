package status

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestChainStatus(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", `#!/bin/sh
[ "$1" = -fsS ] && [ "$2" = --max-time ] && [ "$3" = "$EXPECT_TIMEOUT" ] && [ "$4" = "http://127.0.0.1:8000/api/state" ] || exit 91
printf '%s' "$CURL_OUTPUT"
exit "${CURL_EXIT:-0}"
`)
	writeTool(t, dir, "jq", `#!/bin/sh
input=$(/bin/cat)
[ "$input" = "$CURL_OUTPUT" ] || exit 92
printf '%s' "$JQ_OUTPUT"
exit "${JQ_EXIT:-0}"
`)
	t.Setenv("PATH", dir)
	t.Setenv("EXPECT_TIMEOUT", "5")
	t.Setenv("CURL_OUTPUT", `{"state":"fixture"}`)

	for _, tc := range []struct {
		name, chain, verdict, want string
	}{
		{"monero green", "monero", "green\tignored", "monero chain  at the tip, with peers"},
		{"monero red", "monero", "red\t0 outgoing peers — next: restart monerod", "monero chain  NOT following the chain: 0 outgoing peers — next: restart monerod"},
		{"tari green", "tari", "green\tignored", "tari chain    no degraded signal confirmed"},
		{"tari amber", "tari", "amber\t0 peer connections — next: wait", "tari chain    0 peer connections — next: wait"},
		{"tari red", "tari", "red\ttip unchanged — next: restart", "tari chain    NOT following the chain: tip unchanged — next: restart"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("JQ_OUTPUT", tc.verdict)
			var out bytes.Buffer
			runnerForTest(dir, &out).chainStatus(tc.chain)
			if !strings.Contains(out.String(), tc.want) {
				t.Fatalf("output = %q, want substring %q", out.String(), tc.want)
			}
		})
	}
}

func TestChainStatusFailuresAreSilent(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", "#!/bin/sh\nexit 1\n")
	writeTool(t, dir, "jq", "#!/bin/sh\nexit 1\n")
	t.Setenv("PATH", dir)
	var out bytes.Buffer
	r := runnerForTest(dir, &out)
	r.chainStatus("monero")
	r.chainStatus("unknown")
	if out.Len() != 0 {
		t.Fatalf("output = %q, want empty", out.String())
	}
}

func TestChainStatusUsesCurlOutputOnCurlFailure(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", "#!/bin/sh\nprintf partial-body\nexit 22\n")
	writeTool(t, dir, "jq", `#!/bin/sh
[ "$(/bin/cat)" = partial-body ] || exit 92
printf 'red\tpartial verdict'
exit 1
`)
	t.Setenv("PATH", dir)
	var out bytes.Buffer
	runnerForTest(dir, &out).chainStatus("monero")
	if !strings.Contains(out.String(), "monero chain  NOT following the chain: partial verdict") {
		t.Fatalf("output = %q", out.String())
	}
}

func TestDashboardSyncing(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", `#!/bin/sh
[ "$*" = "-fsS --max-time 3 http://127.0.0.1:8000/api/state" ] || exit 91
printf body
`)
	writeTool(t, dir, "jq", `#!/bin/sh
[ "$1" = -er ] || exit 92
[ "$(/bin/cat)" = body ] || exit 93
printf '%s' "$JQ_OUTPUT"
exit "${JQ_EXIT:-0}"
`)
	t.Setenv("PATH", dir)
	t.Setenv("JQ_OUTPUT", "false")
	r := runnerForTest(dir, &bytes.Buffer{})
	if got := r.dashboardSyncing(); got != "false" {
		t.Fatalf("dashboardSyncing() = %q, want false", got)
	}
	t.Setenv("JQ_EXIT", "1")
	if got := r.dashboardSyncing(); got != "false" {
		t.Fatalf("dashboardSyncing() with jq output and failure = %q, want false", got)
	}
}

func TestDashboardSyncingUsesPartialPipelineOutput(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", "#!/bin/sh\nprintf partial-body\nexit 22\n")
	writeTool(t, dir, "jq", `#!/bin/sh
[ "$(/bin/cat)" = partial-body ] || exit 92
printf true
exit 1
`)
	t.Setenv("PATH", dir)
	if got := runnerForTest(dir, &bytes.Buffer{}).dashboardSyncing(); got != "true" {
		t.Fatalf("dashboardSyncing() = %q, want true", got)
	}
}

func TestDashboardHelpersDoNotCallCurlWithoutJQ(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", "#!/bin/sh\nprintf called > curl-called\n")
	t.Setenv("PATH", dir)
	var out bytes.Buffer
	r := runnerForTest(dir, &out)
	r.chainStatus("monero")
	r.dashboardSyncing()
	r.syncProgress()
	if _, err := os.Stat(filepath.Join(dir, "curl-called")); !os.IsNotExist(err) {
		t.Fatalf("curl was called without jq: %v", err)
	}
}

func TestSyncProgress(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", `#!/bin/sh
[ "$*" = "-fsS --max-time 3 http://127.0.0.1:8000/api/state" ] || exit 91
printf body
`)
	writeTool(t, dir, "jq", `#!/bin/sh
[ "$1" = -r ] && [ "$2" = --arg ] && [ "$3" = tari_required ] && [ "$4" = false ] || exit 92
[ "$(/bin/cat)" = body ] || exit 93
printf 'monero\tsyncing\t42.5\t425\t1000\t575\ntari\tloading\t0\t0\t0\t0\n'
`)
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("TARI_REQUIRED=false\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	var out bytes.Buffer
	runnerForTest(dir, &out).syncProgress()
	want := "[pithead] Chain sync in progress — the miner is held until it completes:\n" +
		"  … monero        42.5% (425 / 1000 blocks, 575 to go)\n" +
		"  … tari          discovering the target height…\n"
	if out.String() != want {
		t.Fatalf("output = %q, want %q", out.String(), want)
	}
}

func TestSyncProgressFailureIsSilent(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "curl", "#!/bin/sh\nprintf body\n")
	writeTool(t, dir, "jq", "#!/bin/sh\nexit 1\n")
	t.Setenv("PATH", dir)
	var out bytes.Buffer
	runnerForTest(dir, &out).syncProgress()
	if out.Len() != 0 {
		t.Fatalf("output = %q, want empty", out.String())
	}
}

func runnerForTest(dir string, out *bytes.Buffer) *Runner {
	return &Runner{Dir: dir, Program: "./pithead", EnvFile: ".env", Out: out, Err: &bytes.Buffer{}}
}

func writeTool(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
}
