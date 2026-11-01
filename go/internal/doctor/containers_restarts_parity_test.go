//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func containerParityRestartRow(id, name, state, count, started string) string {
	return strings.Join([]string{id, name, state, count, started}, "\t") + "\n"
}

func TestContainerParityRestarts(t *testing.T) {
	row := containerParityRestartRow
	stable := row("a", "/caddy", "running", "1", "start")
	for _, engine := range []string{"docker", "podman"} {
		for _, test := range []struct{ name, before, after string }{
			{"stable", stable, stable},
			{"count-advanced", stable, row("a", "/caddy", "running", "2", "start")},
			{"started-changed", stable, row("a", "/caddy", "running", "1", "later")},
			{"backoff-before", row("a", "/caddy", "restarting", "1", "start"), stable},
			{"backoff-after", stable, row("a", "/caddy", "restarting", "1", "start")},
			{"replacement", stable, row("b", "/caddy", "running", "2", "later")},
			{"replacement-backoff", stable, row("b", "/caddy", "restarting", "2", "later")},
			{"first-start", row("a", "/caddy", "created", "0", "0001-01-01T00:00:00Z"), stable},
			{"old-name", stable, row("a", "/renamed", "running", "2", "later")},
			{"compose-name", row("a", "/abcdef123456_caddy", "restarting", "1", "start"), stable},
			{"duplicate-before", row("a", "/caddy", "restarting", "1", "start") + row("b", "/caddy", "restarting", "1", "start"), stable},
			{"after-dedup", stable, row("a", "/caddy", "restarting", "2", "later") + row("b", "/caddy", "restarting", "2", "later")},
			{"leading-tabs", "\t" + stable, "\t" + stable},
			{"last-field", row("a", "/caddy", "running", "1", "start\textra"), stable},
		} {
			t.Run(engine+"/"+test.name, func(t *testing.T) {
				input := newContainerParityFixture(t, engine)
				input.write(t, "inspect1.value", test.before)
				input.write(t, "inspect2.value", test.after)
				compareContainerFindings(t, input, "restarts")
			})
		}
	}
}

func TestContainerParityRestartGates(t *testing.T) {
	for _, name := range []string{"empty-before", "empty-after", "bad-before", "bad-after", "ids1", "ids2", "inspect1", "inspect2", "no-engine", "sleep-failed"} {
		t.Run(name, func(t *testing.T) {
			input := newContainerParityFixture(t, "docker")
			switch name {
			case "empty-before":
				input.write(t, "ids1.value", "")
			case "empty-after":
				input.write(t, "ids2.value", "")
			case "bad-before":
				input.write(t, "inspect1.value", "not-a-row\n")
			case "bad-after":
				input.write(t, "inspect2.value", "not-a-row\n")
			case "no-engine":
				if err := os.Remove(filepath.Join(input.dir, "docker")); err != nil {
					t.Fatal(err)
				}
			case "sleep-failed":
				input.write(t, "sleep.code", "1")
			default:
				input.write(t, name+".code", "1")
			}
			compareContainerFindings(t, input, "restarts")
		})
	}
}

func TestContainerParityRestartFallbacks(t *testing.T) {
	for _, ids := range []string{"*", "a\u2003b"} {
		t.Run(ids, func(t *testing.T) {
			input := newContainerParityFixture(t, "docker")
			input.write(t, "ids1.value", ids)
			_, err := ContainerRestarts(input.dir)
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("error = %v; want unsupported shell splitting", err)
			}
		})
	}
}
