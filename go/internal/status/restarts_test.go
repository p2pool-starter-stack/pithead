package status

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRestartingNames(t *testing.T) {
	tests := []struct {
		name   string
		before string
		after  string
		want   []string
	}{
		{
			"stable",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n",
			nil,
		},
		{
			"count advanced",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n",
			"a\t/caddy\trunning\t8\t2026-10-20T00:00:01Z\n",
			[]string{"caddy"},
		},
		{
			"start changed",
			"a\t/0123456789ab_caddy\trunning\t0\t2026-10-20T00:00:01Z\n",
			"a\t/0123456789ab_caddy\trunning\t0\t2026-10-20T00:00:02Z\n",
			[]string{"caddy"},
		},
		{
			"first start",
			"a\t/caddy\tcreated\t0\t0001-01-01T00:00:00Z\n",
			"a\t/caddy\trunning\t0\t2026-10-20T00:00:02Z\n",
			nil,
		},
		{
			"replacement",
			"a\t/caddy\trunning\t0\t2026-10-20T00:00:01Z\n",
			"b\t/caddy\trunning\t1\t2026-10-20T00:00:02Z\n",
			nil,
		},
		{
			"restarting order and deduplication",
			"a\t/0123456789ab_alpha\trestarting\t7\t2026-10-20T00:00:01Z\nb\t/beta\trunning\t0\t2026-10-20T00:00:01Z\n",
			"a\t/0123456789ab_alpha\trestarting\t7\t2026-10-20T00:00:01Z\nb\t/beta\trestarting\t0\t2026-10-20T00:00:01Z\n",
			[]string{"alpha", "beta"},
		},
		{
			"signed count overflow is not an increase",
			"a\t/caddy\trunning\t9223372036854775808\t2026-10-20T00:00:01Z\n",
			"a\t/caddy\trunning\t9223372036854775809\t2026-10-20T00:00:01Z\n",
			nil,
		},
		{
			"start change still detects signed count overflow",
			"a\t/caddy\trunning\t9223372036854775808\t2026-10-20T00:00:01Z\n",
			"a\t/caddy\trunning\t9223372036854775809\t2026-10-20T00:00:02Z\n",
			[]string{"caddy"},
		},
		{
			"read assigns extra fields to started",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\textra\n",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\textra\n",
			nil,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner, log := restartRunner(t, test.before, test.after)
			got, err := runner.restartingNames()
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("got %#v, want %#v", got, test.want)
			}
			calls, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(calls), "sleep 3\n") {
				t.Fatalf("sleep call missing from %q", calls)
			}
		})
	}
}

func TestRestartingNamesFailures(t *testing.T) {
	tests := []struct {
		name   string
		before string
		after  string
	}{
		{"malformed row", "not-a-row\n", ""},
		{"empty second snapshot", "a\t/caddy\trunning\t0\tnow\n", ""},
		{"empty field", "a\t\trunning\t0\tnow\n", ""},
		{"invalid id", "fixture-id\t/caddy\trunning\t0\tnow\n", ""},
		{"invalid count", "a\t/caddy\trunning\t-1\tnow\n", ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner, _ := restartRunner(t, test.before, test.after)
			if _, err := runner.restartingNames(); err == nil {
				t.Fatal("expected restart observation error")
			}
		})
	}
}

func TestRestartingNamesEmptyStackSkipsSleep(t *testing.T) {
	runner, log := restartRunner(t, "", "")
	got, err := runner.restartingNames()
	if err != nil || len(got) != 0 {
		t.Fatalf("got %#v, %v", got, err)
	}
	content, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(content), "sleep") {
		t.Fatalf("unexpected sleep call in %q", content)
	}
}

func TestContainerEnginePrecedence(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"docker", "podman"} {
		writeExecutable(t, filepath.Join(dir, name), "#!/bin/sh\nexit 0\n")
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("PITHEAD_ENGINE", "")
	if got := containerEngine(); got != "docker" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("PITHEAD_ENGINE", "podman")
	if got := containerEngine(); got != "podman" {
		t.Fatalf("got %q", got)
	}
	t.Setenv("PITHEAD_ENGINE", "invalid")
	if got := containerEngine(); got != "docker" {
		t.Fatalf("got %q", got)
	}
}

func restartRunner(t *testing.T, before, after string) (*Runner, string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "before"), []byte(before), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "after"), []byte(after), 0o600); err != nil {
		t.Fatal(err)
	}
	engine := `#!/bin/sh
set -eu
printf '%s %s\n' "$(basename "$0")" "$*" >>"$RESTART_LOG"
if [ "$1" = compose ]; then
    if [ -s "$RESTART_DIR/before" ]; then printf 'a b\n'; fi
    exit 0
fi
n=before
if [ -f "$RESTART_DIR/seen" ]; then n=after; else : >"$RESTART_DIR/seen"; fi
cat "$RESTART_DIR/$n"
`
	writeExecutable(t, filepath.Join(bin, "docker"), engine)
	writeExecutable(t, filepath.Join(bin, "podman"), engine)
	writeExecutable(t, filepath.Join(bin, "sleep"), "#!/bin/sh\nprintf 'sleep %s\\n' \"$*\" >>\"$RESTART_LOG\"\n")
	log := filepath.Join(dir, "calls")
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("PITHEAD_ENGINE", "docker")
	t.Setenv("RESTART_DIR", dir)
	t.Setenv("RESTART_LOG", log)
	return &Runner{Dir: dir}, log
}

func writeExecutable(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}
