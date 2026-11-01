package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRevenueContainerVerdict(t *testing.T) {
	tests := []struct {
		name, state, status, hold, want string
	}{
		{"monerod", "running", "Up 5 minutes (healthy)", "", "ok"},
		{"monerod", "", "Up 5 minutes (healthy)", "", "ok"},
		{"monerod", "exited", "Exited (0) 1 minute ago", "", "fail:monerod is down (Exited (0) 1 minute ago) — a chain node down means the slot is not healthy to commit"},
		{"monerod", "running", "Up 2 minutes (unhealthy)", "", "fail:monerod is not ready (Up 2 minutes (unhealthy)) — a chain node must be up and healthy to commit"},
		{"tari", "running", "Up 8 seconds (starting)", "", "fail:tari is not ready (Up 8 seconds (starting)) — a chain node must be up and healthy to commit"},
		{"wallet-rpc", "created", "", "", "fail:wallet-rpc is down (created) — a chain node down means the slot is not healthy to commit"},
		{"4556c4f42f1d_monerod", "exited", "Exited (0)", "", "fail:monerod is down (Exited (0)) — a chain node down means the slot is not healthy to commit"},
		{"notahexid12_monerod", "exited", "Exited (0)", "", "ok"},
		{"/monerod", "exited", "Exited (0)", "", "ok"},
		{"p2pool", "exited", "Up 2 minutes (unhealthy)", "", "ok"},
		{"p2pool", "", "Exited (0)", "", "ok"},
		{"p2pool", "restarting", "Restarting (1)", "", "fail:p2pool is not stopped for sync and is not running (Restarting (1))"},
		{"xmrig-proxy", "running", "Up 30 seconds (unhealthy)", "", "fail:xmrig-proxy is running but unhealthy (Up 30 seconds (unhealthy))"},
		{"xmrig-proxy", "running", "Up 30 seconds (starting)", "", "ok"},
		{"monerod", "exited", "Exited (0)", "1", "ok"},
		{"monerod", "created", "Created", "true", "fail:monerod is down (Created) — a chain node down means the slot is not healthy to commit"},
		{"monerod", "restarting", "Restarting (1)", "1", "fail:monerod is down (Restarting (1)) — a chain node down means the slot is not healthy to commit"},
		{"dashboard", "exited", "Exited (1)", "", "ok"},
	}
	for _, test := range tests {
		t.Run(test.name+"/"+test.state+"/"+test.hold, func(t *testing.T) {
			got, err := RevenueContainerVerdict(test.name, test.state, test.status, test.hold)
			if err != nil || got != test.want {
				t.Fatalf("RevenueContainerVerdict() = %q, %v; want %q", got, err, test.want)
			}
		})
	}
	if got, err := RevenueContainerVerdict("monerod\x00", "running", "Up", "0"); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("RevenueContainerVerdict(NUL) = %q, %v", got, err)
	}
}

func TestRevenuePSRow(t *testing.T) {
	tests := []struct {
		row                 string
		name, state, status string
	}{
		{"monerod\trunning\tUp 3m", "monerod", "running", "Up 3m"},
		{"monerod\t\tUp 3m", "monerod", "Up 3m", ""},
		{"\tmonerod\texited\tExited", "monerod", "exited", "Exited"},
		{"monerod\texited\tExited\t5m", "monerod", "exited", "Exited\t5m"},
		{"monerod\texited\t", "monerod", "exited", ""},
		{"monerod", "monerod", "", ""},
	}
	for _, test := range tests {
		name, state, status := revenuePSRow(test.row)
		if name != test.name || state != test.state || status != test.status {
			t.Errorf("revenuePSRow(%q) = %q, %q, %q", test.row, name, state, status)
		}
	}
}

func TestRevenueContainersFindings(t *testing.T) {
	fixture := newRevenueFixture(t)
	fixture.output(t, "dashboard\trunning\tUp 2m\n4556c4f42f1d_monerod\texited\tExited (0)\np2pool\texited\tExited (0)\ntari\trunning\tUp 2s (starting)\n")
	got, err := (RevenueContainers{}).Findings()
	want := []Finding{
		{"revenue-containers", "fail", "monerod is down (Exited (0)) — a chain node down means the slot is not healthy to commit"},
		{"revenue-containers", "fail", "tari is not ready (Up 2s (starting)) — a chain node must be up and healthy to commit"},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Findings() = %+v, %v; want %+v", got, err, want)
	}
	if args := fixture.args(t); args != "ps\n-a\n--format\n{{.Names}}\\t{{.State}}\\t{{.Status}}\n" {
		t.Fatalf("engine args = %q", args)
	}
}

func TestRevenueContainersHoldAndReadSemantics(t *testing.T) {
	fixture := newRevenueFixture(t)
	fixture.output(t, "monerod\texited\tExited (0)\nunknown\trunning\tUp\n")
	got, err := (RevenueContainers{MigrationHold: true}).Findings()
	want := []Finding{
		{"revenue-containers", "info", "A data migration is pending — chain services are deliberately held until this slot commits."},
		{"revenue-containers", "ok", "Revenue containers are healthy or holding for sync — none crashed."},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Findings() = %+v, %v; want %+v", got, err, want)
	}
	fixture.output(t, "monerod\t\tUp 5m (healthy)\nmonerod\texited\tExited\t5m\n")
	got, err = (RevenueContainers{}).Findings()
	want = []Finding{
		{"revenue-containers", "fail", "monerod is down (Up 5m (healthy)) — a chain node down means the slot is not healthy to commit"},
		{"revenue-containers", "fail", "monerod is down (Exited\t5m) — a chain node down means the slot is not healthy to commit"},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Findings(read semantics) = %+v, %v; want %+v", got, err, want)
	}
}

func TestRevenueContainersRuntimeBoundaries(t *testing.T) {
	t.Run("docker", func(t *testing.T) {
		fixture := newRevenueEngineFixture(t, "docker")
		fixture.output(t, "monerod\trunning\tUp 2m (healthy)\n")
		got, err := (RevenueContainers{}).Findings()
		want := []Finding{{"revenue-containers", "ok", "Revenue containers are healthy or holding for sync — none crashed."}}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("missing", func(t *testing.T) {
		t.Setenv("PITHEAD_ENGINE", "podman")
		t.Setenv("PATH", t.TempDir())
		got, err := (RevenueContainers{MigrationHold: true}).Findings()
		if err != nil || got != nil {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("empty", func(t *testing.T) {
		fixture := newRevenueFixture(t)
		fixture.output(t, "\n\n")
		got, err := (RevenueContainers{MigrationHold: true}).Findings()
		if err != nil || got != nil {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("stderr", func(t *testing.T) {
		fixture := newRevenueFixture(t)
		fixture.output(t, "monerod\trunning\tUp 2m (healthy)\n")
		t.Setenv("REVENUE_STDERR", "ignored diagnostic")
		got, err := (RevenueContainers{}).Findings()
		want := []Finding{{"revenue-containers", "ok", "Revenue containers are healthy or holding for sync — none crashed."}}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("nonzero", func(t *testing.T) {
		fixture := newRevenueFixture(t)
		fixture.output(t, "monerod\texited\tExited (1)\n")
		t.Setenv("REVENUE_EXIT", "7")
		got, err := (RevenueContainers{}).Findings()
		if err != nil || got != nil {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("nul", func(t *testing.T) {
		newRevenueFixture(t)
		t.Setenv("REVENUE_NUL", "1")
		got, err := (RevenueContainers{}).Findings()
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("launch", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "podman")
		if err := os.WriteFile(path, []byte("invalid executable"), 0o755); err != nil {
			t.Fatal(err)
		}
		t.Setenv("PITHEAD_ENGINE", "podman")
		t.Setenv("PATH", dir)
		got, err := (RevenueContainers{}).Findings()
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
	t.Run("relative-path", func(t *testing.T) {
		t.Setenv("PITHEAD_ENGINE", "podman")
		t.Setenv("PATH", "relative")
		got, err := (RevenueContainers{}).Findings()
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Findings() = %+v, %v", got, err)
		}
	})
}

type revenueFixture struct {
	argsPath string
}

func newRevenueFixture(t *testing.T) revenueFixture {
	t.Helper()
	return newRevenueEngineFixture(t, "podman")
}

func newRevenueEngineFixture(t *testing.T, engine string) revenueFixture {
	t.Helper()
	dir := t.TempDir()
	args := filepath.Join(dir, "args")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" >\"$REVENUE_ARGS\"\nprintf '%s' \"$REVENUE_STDERR\" >&2\nif [ \"$REVENUE_NUL\" = 1 ]; then printf '\\000'; else printf '%s' \"$REVENUE_STDOUT\"; fi\nexit \"${REVENUE_EXIT:-0}\"\n"
	if err := os.WriteFile(filepath.Join(dir, engine), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PITHEAD_ENGINE", engine)
	t.Setenv("PATH", dir)
	t.Setenv("REVENUE_ARGS", args)
	return revenueFixture{argsPath: args}
}

func (fixture revenueFixture) output(t *testing.T, output string) {
	t.Helper()
	t.Setenv("REVENUE_STDOUT", output)
}

func (fixture revenueFixture) args(t *testing.T) string {
	t.Helper()
	value, err := os.ReadFile(fixture.argsPath)
	if err != nil {
		t.Fatal(err)
	}
	return strings.ReplaceAll(string(value), "\r\n", "\n")
}
