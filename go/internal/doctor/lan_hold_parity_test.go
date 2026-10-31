//go:build parity

package doctor

import (
	"errors"
	"strings"
	"testing"
)

func TestLANHoldRunningParity(t *testing.T) {
	for _, policy := range []string{"no", "always", "unless-stopped", "", "no\n\n", "on-failure\nextra"} {
		t.Run(policy, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanTool(t, fixture, "systemctl")
			lanTool(t, fixture, "docker")
			lanResponse(t, fixture, "docker", "monerod-policy", policy, 0)
			lanResponse(t, fixture, "docker", "monerod-running", "cid\n", 0)
			lanResponse(t, fixture, "docker", "tari-policy", "always", 0)
			lanResponse(t, fixture, "docker", "tari-running", "cid\n", 0)
			compareLANFindings(t, fixture, "hold", "18081", "18083", "18142", "18142", "other")
		})
	}
}

func TestLANHoldStoppedParity(t *testing.T) {
	for _, test := range []struct {
		name, output    string
		failed, inspect int
	}{
		{"boot-failed", "", 0, 0},
		{"refused", "78\n", 1, 0},
		{"refused-partial", "78\n", 1, 1},
		{"ordinary-exit", "42\n\n", 1, 0},
		{"inspect-empty-failure", "", 1, 1},
		{"inspect-partial-failure", "19\n", 1, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanTool(t, fixture, "systemctl")
			lanTool(t, fixture, "docker")
			lanResponse(t, fixture, "docker", "monerod-policy", "no\n", 0)
			lanResponse(t, fixture, "docker", "monerod-running", "", 0)
			lanResponse(t, fixture, "systemctl", "failed", "", test.failed)
			lanResponse(t, fixture, "docker", "monerod-code", test.output, test.inspect)
			compareLANFindings(t, fixture, "hold", "18081", "18083")
		})
	}
}

func TestLANHoldGatesParity(t *testing.T) {
	for _, gate := range []string{"no-ports", "non-linux", "appliance", "podman", "missing-systemctl", "missing-docker", "failed-inspect"} {
		t.Run(gate, func(t *testing.T) {
			fixture := newLANFixture(t)
			ports := []string{"18081"}
			if gate != "missing-systemctl" {
				lanTool(t, fixture, "systemctl")
			}
			if gate != "missing-docker" {
				lanTool(t, fixture, "docker")
				lanResponse(t, fixture, "docker", "monerod-policy", "partial", 1)
			}
			switch gate {
			case "no-ports":
				ports = nil
			case "non-linux":
				fixture.OS = "Darwin"
			case "appliance":
				fixture.Appliance = true
			case "podman":
				t.Setenv("PITHEAD_ENGINE", "podman")
			}
			compareLANFindings(t, fixture, "hold", ports...)
		})
	}
}

func TestLANHoldFallbacks(t *testing.T) {
	for _, test := range []struct{ tool, key, output string }{
		{"docker", "monerod-policy", "no\x00"},
		{"docker", "monerod-running", "cid\x00"},
		{"docker", "monerod-code", "78\x00"},
		{"systemctl", "failed", "visible output\n"},
	} {
		t.Run(test.tool+test.key, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanTool(t, fixture, "systemctl")
			lanTool(t, fixture, "docker")
			lanResponse(t, fixture, "docker", "monerod-policy", "no", 0)
			lanResponse(t, fixture, "docker", "monerod-running", "", 0)
			lanResponse(t, fixture, test.tool, test.key, test.output, 0)
			if test.tool == "systemctl" {
				result := runLANBash(t, fixture, "hold", "18081")
				if result.code != 0 || !strings.HasPrefix(result.stderr, test.output) || !strings.HasPrefix(result.stdout, "fail\tmonerod is down:") {
					t.Fatalf("visible-output witness: %+v", result)
				}
			}
			if _, err := fixture.Hold([]string{"18081"}); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("fallback: %v", err)
			}
		})
	}
}
