package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestContainerRestartsFindings(t *testing.T) {
	tests := []struct {
		name   string
		before string
		after  string
		want   []Finding
	}{
		{
			"stable",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n",
			[]Finding{{"container-restarts", "ok", "No containers were observed restarting during the health check."}},
		},
		{
			"count advanced",
			"a\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n",
			"a\t/caddy\trunning\t8\t2026-10-20T00:00:01Z\n",
			[]Finding{{"container-restarts", "fail", "caddy is restarting or restarted during the health check — it may be crash-looping."}},
		},
		{
			"start changed",
			"a\t/0123456789ab_caddy\trunning\t0\t2026-10-20T00:00:01Z\n",
			"a\t/0123456789ab_caddy\trunning\t0\t2026-10-20T00:00:02Z\n",
			[]Finding{{"container-restarts", "fail", "caddy is restarting or restarted during the health check — it may be crash-looping."}},
		},
		{
			"first start",
			"a\t/caddy\tcreated\t0\t0001-01-01T00:00:00Z\n",
			"a\t/caddy\trunning\t0\t2026-10-20T00:00:02Z\n",
			[]Finding{{"container-restarts", "ok", "No containers were observed restarting during the health check."}},
		},
		{
			"replacement",
			"a\t/caddy\trunning\t0\t2026-10-20T00:00:01Z\n",
			"b\t/caddy\trunning\t1\t2026-10-20T00:00:02Z\n",
			[]Finding{{"container-restarts", "ok", "No containers were observed restarting during the health check."}},
		},
		{
			"before duplicates and after deduplication",
			"a\t/alpha\trestarting\t0\tnow\nb\t/alpha\trestarting\t0\tnow\n",
			"a\t/alpha\trestarting\t0\tnow\nc\t/beta\trestarting\t0\tnow\nd\t/beta\trestarting\t0\tnow\n",
			[]Finding{
				{"container-restarts", "fail", "alpha is restarting or restarted during the health check — it may be crash-looping."},
				{"container-restarts", "fail", "alpha is restarting or restarted during the health check — it may be crash-looping."},
				{"container-restarts", "fail", "beta is restarting or restarted during the health check — it may be crash-looping."},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := restartFixture(t, test.before, test.after)
			got, err := ContainerRestarts(dir)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("ContainerRestarts() = %#v, want %#v", got, test.want)
			}
			format, err := os.ReadFile(filepath.Join(dir, "format"))
			if err != nil {
				t.Fatal(err)
			}
			if string(format) != restartInspectFormat || !strings.ContainsRune(string(format), '\t') {
				t.Fatalf("inspect format = %q", format)
			}
		})
	}
}

func TestContainerRestartsReadFailures(t *testing.T) {
	tests := []struct {
		name, before, after string
		configure           func(*testing.T)
	}{
		{"compose failure", "", "", func(t *testing.T) { t.Setenv("RESTART_COMPOSE_CODE", "1") }},
		{"inspect failure", "a\t/caddy\trunning\t0\tnow\n", "", func(t *testing.T) { t.Setenv("RESTART_INSPECT_CODE", "1") }},
		{"malformed row", "not-a-row\n", "", nil},
		{"empty second snapshot", "a\t/caddy\trunning\t0\tnow\n", "", nil},
	}
	want := []Finding{{"container-restarts", "fail", "Container restart observation failed — the engine state could not be read twice."}}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := restartFixture(t, test.before, test.after)
			if test.configure != nil {
				test.configure(t)
			}
			got, err := ContainerRestarts(dir)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("ContainerRestarts() = %#v, %v", got, err)
			}
		})
	}
}

func TestContainerRestartsMissingEngine(t *testing.T) {
	dir := t.TempDir()
	writeRestartExecutable(t, filepath.Join(dir, "sleep"), "#!/bin/sh\nexit 0\n")
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "docker")
	got, err := ContainerRestarts(dir)
	want := []Finding{{"container-restarts", "fail", "Container restart observation failed — the engine state could not be read twice."}}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("ContainerRestarts() = %#v, %v", got, err)
	}
}

func TestRestartingContainerNamesQuietSleepFailureContinues(t *testing.T) {
	dir := restartFixture(t,
		"a\t/caddy\trunning\t0\tnow\n",
		"a\t/caddy\trestarting\t0\tnow\n",
	)
	t.Setenv("RESTART_SLEEP_CODE", "7")
	got, err := RestartingContainerNames(dir)
	if err != nil || !reflect.DeepEqual(got, []string{"caddy"}) {
		t.Fatalf("RestartingContainerNames() = %#v, %v", got, err)
	}
}

func TestRestartingContainerNamesUnsupportedInputs(t *testing.T) {
	tests := []struct {
		name, ids, before, after string
		configure                func(*testing.T, string)
	}{
		{"glob id", "*", "", "", nil},
		{"unicode id", "caf\u00e9", "", "", nil},
		{
			"sleep diagnostics", "a", "a\t/caddy\trunning\t0\tnow\n", "a\t/caddy\trunning\t0\tnow\n",
			func(t *testing.T, _ string) { t.Setenv("RESTART_SLEEP_STDERR", "warning") },
		},
		{
			"sleep stdout", "a", "a\t/caddy\trunning\t0\tnow\n", "a\t/caddy\trunning\t0\tnow\n",
			func(t *testing.T, _ string) { t.Setenv("RESTART_SLEEP_STDOUT", "unexpected") },
		},
		{
			"count overflow", "a", "a\t/caddy\trunning\t9223372036854775808\tnow\n", "a\t/caddy\trunning\t9223372036854775809\tnow\n", nil,
		},
		{
			"empty normalized name", "a", "a\t/\trestarting\t0\tnow\n", "a\t/\trestarting\t0\tnow\n", nil,
		},
		{
			"missing sleep", "a", "a\t/caddy\trunning\t0\tnow\n", "a\t/caddy\trunning\t0\tnow\n",
			func(t *testing.T, dir string) {
				if err := os.Remove(filepath.Join(dir, "bin", "sleep")); err != nil {
					t.Fatal(err)
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := restartFixture(t, test.before, test.after)
			t.Setenv("RESTART_IDS", test.ids)
			if test.configure != nil {
				test.configure(t, dir)
			}
			got, err := RestartingContainerNames(dir)
			if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("RestartingContainerNames() = %#v, %v", got, err)
			}
		})
	}
}

func TestContainerRestartsUnsupportedCommands(t *testing.T) {
	tests := []struct {
		name      string
		configure func(*testing.T, string)
	}{
		{
			"engine without shebang",
			func(t *testing.T, dir string) {
				writeRestartExecutable(t, filepath.Join(dir, "bin", "docker"), "exit 0\n")
			},
		},
		{
			"nul compose output",
			func(t *testing.T, _ string) { t.Setenv("RESTART_NUL", "compose") },
		},
		{
			"nul inspect output",
			func(t *testing.T, _ string) { t.Setenv("RESTART_NUL", "inspect") },
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := restartFixture(t, "a\t/caddy\trunning\t0\tnow\n", "a\t/caddy\trunning\t0\tnow\n")
			test.configure(t, dir)
			got, err := ContainerRestarts(dir)
			if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("ContainerRestarts() = %#v, %v", got, err)
			}
		})
	}
}

func restartFixture(t *testing.T, before, after string) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	engine := `#!/bin/sh
if [ "$1" = compose ]; then
	if [ "${RESTART_NUL-}" = compose ]; then printf '\000'; exit 0; fi
    printf '%s' "${RESTART_IDS-a}"
    exit "${RESTART_COMPOSE_CODE-0}"
fi
printf '%s' "$3" >"$RESTART_DIR/format"
	if [ "${RESTART_NUL-}" = inspect ]; then printf '\000'; exit 0; fi
if [ -e "$RESTART_DIR/seen" ]; then
    printf '%s' "$RESTART_AFTER"
else
    : >"$RESTART_DIR/seen"
    printf '%s' "$RESTART_BEFORE"
fi
exit "${RESTART_INSPECT_CODE-0}"
`
	sleep := `#!/bin/sh
printf '%s' "${RESTART_SLEEP_STDOUT-}"
printf '%s' "${RESTART_SLEEP_STDERR-}" >&2
exit "${RESTART_SLEEP_CODE-0}"
`
	writeRestartExecutable(t, filepath.Join(bin, "docker"), engine)
	writeRestartExecutable(t, filepath.Join(bin, "sleep"), sleep)
	t.Setenv("PATH", bin)
	t.Setenv("PITHEAD_ENGINE", "docker")
	t.Setenv("RESTART_DIR", dir)
	t.Setenv("RESTART_IDS", "a")
	t.Setenv("RESTART_BEFORE", before)
	t.Setenv("RESTART_AFTER", after)
	return dir
}

func writeRestartExecutable(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}
