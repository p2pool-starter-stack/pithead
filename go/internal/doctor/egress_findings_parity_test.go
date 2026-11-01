//go:build parity

package doctor

import (
	"errors"
	"strconv"
	"testing"
)

func TestEgressFindingsOptOutParity(t *testing.T) {
	for _, enabled := range []string{"false", "FALSE", "0", "no", "off", "invalid"} {
		t.Run(enabled, func(t *testing.T) {
			fixture := newEgressFixture(t)
			fixture.Enabled = enabled
			compareEgressFindings(t, fixture)
		})
	}
}

func TestEgressFindingsTorGateParity(t *testing.T) {
	for _, test := range []struct {
		name   string
		output string
		code   int
	}{
		{"missing-docker", "", 0},
		{"stopped", "", 0},
		{"failed", "", 1},
		{"partial-failure", "cid\n", 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newEgressFixture(t)
			if test.name != "missing-docker" {
				egressTool(t, fixture, "docker")
				egressResponse(t, fixture, "docker", "tor", test.output, test.code)
			}
			if test.name == "partial-failure" {
				egressReadback(t, fixture, "", "")
			}
			compareEgressFindings(t, fixture)
		})
	}
}

func TestEgressFindingsDockerCodesParity(t *testing.T) {
	for _, code := range []int{0, 1, 2, 3, 4, 5} {
		for _, appliance := range []bool{false, true} {
			name := strconv.Itoa(code) + "/appliance=" + strconv.FormatBool(appliance)
			t.Run(name, func(t *testing.T) {
				fixture := newEgressFixture(t)
				fixture.OS, fixture.Appliance = "Darwin", appliance
				egressTool(t, fixture, "docker")
				egressResponse(t, fixture, "docker", "tor", "cid\n", 0)
				configureEgressCode(t, fixture, code)
				compareEgressFindings(t, fixture)
			})
		}
	}
}

func TestEgressFindingsEnabledNormalizationParity(t *testing.T) {
	for _, enabled := range []string{"", "true", "TRUE", "1", "yes", "on"} {
		t.Run(strconv.Quote(enabled), func(t *testing.T) {
			fixture := newEgressFixture(t)
			fixture.Enabled, fixture.OS = enabled, "Darwin"
			egressTool(t, fixture, "docker")
			egressResponse(t, fixture, "docker", "tor", "cid\n", 0)
			configureEgressCode(t, fixture, 0)
			compareEgressFindings(t, fixture)
		})
	}
}

func TestEgressFindingsBootParity(t *testing.T) {
	for _, test := range []struct {
		name      string
		os        string
		appliance bool
		systemctl bool
		enabled   int
	}{
		{"enabled", "Linux", false, true, 0},
		{"disabled", "Linux", false, true, 1},
		{"missing-systemctl", "Linux", false, false, 0},
		{"non-linux", "Darwin", false, true, 1},
		{"empty-os", "", false, true, 1},
		{"appliance", "Linux", true, true, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newEgressFixture(t)
			fixture.OS, fixture.Appliance = test.os, test.appliance
			egressTool(t, fixture, "docker")
			egressResponse(t, fixture, "docker", "tor", "cid\n", 0)
			configureEgressCode(t, fixture, 0)
			if test.systemctl {
				egressTool(t, fixture, "systemctl")
				egressResponse(t, fixture, "systemctl", "enabled", "suppressed output\n", test.enabled)
			}
			compareEgressFindings(t, fixture)
		})
	}
}

func TestEgressFindingsPodmanFallback(t *testing.T) {
	fixture := newEgressFixture(t)
	fixture.OS = "Darwin"
	t.Setenv("PITHEAD_ENGINE", "podman")
	egressTool(t, fixture, "docker")
	egressResponse(t, fixture, "docker", "tor", "cid\n", 0)
	if _, err := fixture.Findings(); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("Podman fallback = %v", err)
	}
}

func TestEgressFindingFormatterParity(t *testing.T) {
	for _, engine := range []string{"docker", "podman"} {
		for _, appliance := range []bool{false, true} {
			for _, code := range []int{0, 1, 2, 3, 4, 5, 9} {
				name := engine + "/appliance=" + strconv.FormatBool(appliance) + "/" + strconv.Itoa(code)
				t.Run(name, func(t *testing.T) {
					fixture := newEgressFixture(t)
					fixture.OS, fixture.Appliance = "Darwin", appliance
					egressTool(t, fixture, "docker")
					egressResponse(t, fixture, "docker", "tor", "cid\n", 0)
					t.Setenv("PITHEAD_ENGINE", engine)
					t.Setenv("EGRESS_RC", strconv.Itoa(code))
					result := runEgressBash(t, fixture, "report")
					assertHostFindings(t, result, []Finding{fixture.finding(code, engine)})
				})
			}
		}
	}
}

func configureEgressCode(t *testing.T, fixture egressFixture, code int) {
	t.Helper()
	switch code {
	case 0:
		egressReadback(t, fixture, egressFullRules(t, fixture), egressForward)
	case 1:
		egressReadback(t, fixture, "", egressForward)
	case 2:
		return
	case 3:
		egressReadback(t, fixture, "", egressForward)
		egressResponse(t, fixture, "iptables", "all", "partial\n", 1)
	case 4:
		egressReadback(t, fixture, egressFullRules(t, fixture), "")
	case 5:
		user := "-A DOCKER-USER -j ACCEPT\n" + egressFullRules(t, fixture)
		egressReadback(t, fixture, user, egressForward)
	}
}
