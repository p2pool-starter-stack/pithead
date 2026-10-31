//go:build parity

package doctor

import (
	"strings"
	"testing"
)

func TestLANPublishedParity(t *testing.T) {
	for _, binds := range [][]string{nil, {"", "127.0.0.1", ""}, {"0.0.0.0", "::", "*"}, {"127.0.0.1\n\n", "127.0.0.2", " "}, {"\n", "0.0.0.0\r\n", "127.0.0.1\nvalue"}, {"0.0.0.0", "", "::", "ignored"}} {
		t.Run(strings.Join(binds, "/"), func(t *testing.T) {
			fixture := newLANFixture(t)
			fixture.Binds = binds
			result := runLANBash(t, fixture, "published")
			published, err := LANPublished(binds)
			want := ""
			if len(published) != 0 {
				want = strings.Join(published, "\n") + "\n"
			}
			if err != nil || result.code != 0 || result.stdout != want || result.stderr != "" {
				t.Fatalf("published: Go %q, %v; Bash %+v", want, err, result)
			}
		})
	}
}

func TestLANContainerParity(t *testing.T) {
	fixture := newLANFixture(t)
	for _, port := range []string{"18081", "18083", "18142", "018142", "", "other"} {
		result := runLANBash(t, fixture, "container", port)
		if result.code != 0 || result.stdout != lanContainer(port)+"\n" || result.stderr != "" {
			t.Fatalf("container %q: %+v", port, result)
		}
	}
}

func TestLANReasonParity(t *testing.T) {
	for _, engine := range []string{"docker", "podman", "", "other"} {
		t.Run(engine, func(t *testing.T) {
			fixture := newLANFixture(t)
			t.Setenv("PITHEAD_ENGINE", engine)
			for _, code := range []string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "", "01", "x\ny"} {
				result := runLANBash(t, fixture, "reason", code)
				message, err := LANReason(code)
				if err != nil || result.code != 0 || result.stdout != message || result.stderr != "" {
					t.Fatalf("reason %q: Go %q, %v; Bash %+v", code, message, err, result)
				}
			}
		})
	}
}

func TestLANBootAppliesParity(t *testing.T) {
	for _, osType := range []string{"Linux", "Darwin", "", "linux"} {
		for _, engine := range []string{"docker", "podman"} {
			for _, appliance := range []bool{false, true} {
				for _, systemctl := range []bool{false, true} {
					t.Run(osType+engine+boolText(appliance)+boolText(systemctl), func(t *testing.T) {
						fixture := newLANFixture(t)
						fixture.OS, fixture.Appliance = osType, appliance
						t.Setenv("PITHEAD_ENGINE", engine)
						if systemctl {
							lanTool(t, fixture, "systemctl")
						}
						result := runLANBash(t, fixture, "boot")
						applies, err := LANBootApplies(osType, appliance)
						if err != nil || (result.code == 0) != applies || result.code > 1 || result.stdout != "" || result.stderr != "" || lanCalls(t, fixture, true) != "" {
							t.Fatalf("boot: Go %t, %v; Bash %+v", applies, err, result)
						}
					})
				}
			}
		}
	}
}

func boolText(value bool) string {
	if value {
		return "true"
	}
	return "false"
}
