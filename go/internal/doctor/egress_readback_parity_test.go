//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/firewall"
)

func TestEgressReadbackCodes(t *testing.T) {
	for _, test := range []struct {
		name, user, forward, fail string
		want                      int
	}{
		{"enforced", egressDrop, egressForward, "", 0},
		{"absent-drop", "-N DOCKER-USER\n", egressForward, "", 1},
		{"user-unreadable", egressDrop, egressForward, "user", 1},
		{"sudo-refused", egressDrop, egressForward, "all", 3},
		{"forward-missing", egressDrop, "-A FORWARD -j OTHER\n", "", 4},
		{"forward-unreadable", egressDrop, egressForward, "forward", 4},
		{"foreign-first", "-A DOCKER-USER -j ACCEPT\n" + egressDrop, egressForward, "", 5},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newEgressFixture(t)
			egressReadback(t, fixture, test.user, test.forward)
			if test.fail != "" {
				egressResponse(t, fixture, "iptables", test.fail, "partial output", 1)
			}
			compareEgressReadback(t, fixture, test.want)
		})
	}
	t.Run("backend-missing", func(t *testing.T) {
		compareEgressReadback(t, newEgressFixture(t), 2)
	})
	t.Run("sudo-missing", func(t *testing.T) {
		fixture := newEgressFixture(t)
		egressTool(t, fixture, "iptables")
		if err := os.Remove(filepath.Join(fixture.lan.Bin, "sudo")); err != nil {
			t.Fatal(err)
		}
		compareEgressReadback(t, fixture, 3)
	})
}

func TestEgressReadbackForeignRules(t *testing.T) {
	for _, test := range []struct {
		rule string
		want int
	}{
		{"-A DOCKER-USER -s 10.0.0.0/8 -j ACCEPT", 0},
		{"-A DOCKER-USER -s 172.0.0.0/8 -j ACCEPT", 5},
		{"-A DOCKER-USER -s 172.28.0.128/25 -j RETURN", 5},
		{"-A DOCKER-USER ! -s 172.0.0.0/8 -j ACCEPT", 0},
		{"-A DOCKER-USER ! -s 10.0.0.0/8 -j ACCEPT", 5},
		{"-A DOCKER-USER -s 10.0.0.0/8 -j CUSTOM", 0},
		{"-A DOCKER-USER -j CUSTOM", 5},
		{"-A DOCKER-USER -j DROP", 0},
		{"-A DOCKER-USER -j LOG", 0},
		{"-A DOCKER-USER -s invalid -j ACCEPT", 5},
		{"-A DOCKER-USER -s 10.0.0.0/8 -s 192.168.0.0/16 -j DROP", 5},
		{`-A DOCKER-USER -m string --string "! -s 10.0.0.0/8 x" -j ACCEPT`, 5},
		{`-A DOCKER-USER -m comment --comment "-s" -s 10.0.0.0/8 -j ACCEPT`, 0},
		{`-A DOCKER-USER -m comment --comment "unterminated -j DROP`, 5},
	} {
		t.Run(test.rule, func(t *testing.T) {
			fixture := newEgressFixture(t)
			egressReadback(t, fixture, test.rule+"\n"+egressDrop, egressForward)
			compareEgressReadback(t, fixture, test.want)
		})
	}
}

func TestEgressReadbackForwardOrder(t *testing.T) {
	for _, test := range []struct {
		forward string
		want    int
	}{
		{"-P FORWARD DROP\n-A FORWARD -j LOG\n" + egressForward, 0},
		{"-A FORWARD -s 10.0.0.0/8 -j ACCEPT\n" + egressForward, 0},
		{"-A FORWARD -j ACCEPT\n" + egressForward, 4},
		{egressForward + "-A FORWARD -j ACCEPT\n", 0},
		{"-A FORWARD -s 172.28.0.0/24 -j DOCKER-USER\n", 4},
		{"-A FORWARD -j DOCKER-USER -m comment --comment extra\n", 4},
		{"-j DOCKER-USER -A FORWARD\n", 4},
		{"-A FORWARD -j REJECT\n" + egressForward, 0},
	} {
		t.Run(test.forward, func(t *testing.T) {
			fixture := newEgressFixture(t)
			egressReadback(t, fixture, egressDrop, test.forward)
			compareEgressReadback(t, fixture, test.want)
		})
	}
}

func TestEgressReadbackSyncExceptions(t *testing.T) {
	for _, test := range []string{"none", "one", "all", "missing", "inactive", "duplicate", "late", "conditional", "host-prefix", "option-order", "leading-jump", "custom-config"} {
		t.Run(test, func(t *testing.T) {
			fixture := newEgressFixture(t)
			fixture.Active = "172.28.0.26"
			exception := egressRule("-s 172.28.0.26 -j ACCEPT")
			user, want := exception+egressDrop, 0
			switch test {
			case "none":
				fixture.Active, user = "", egressDrop
			case "all":
				fixture.Active = "172.28.0.26\n172.28.0.27\n172.28.0.28\n172.28.0.29\n"
				user = egressFullRules(t, fixture)
			case "missing":
				user, want = egressDrop, 1
			case "inactive":
				fixture.Active, want = "", 1
			case "duplicate":
				user, want = exception+exception+egressDrop, 1
			case "late":
				user, want = egressDrop+exception, 1
			case "conditional":
				user, want = egressRule("-s 172.28.0.26 -p tcp -j ACCEPT")+egressDrop, 1
			case "host-prefix":
				user = egressRule("-s 172.28.0.26/32 -j ACCEPT") + egressDrop
			case "option-order":
				user = "-m comment --comment \"pithead-tor-egress\" -j ACCEPT -s 172.28.0.26 -A DOCKER-USER\n" + egressDrop
			case "leading-jump":
				user = "-j ACCEPT -m comment --comment \"pithead-tor-egress\" -s 172.28.0.26 -A DOCKER-USER\n" + egressDrop
				want = 1
			case "custom-config":
				fixture.Prefix, fixture.Subnet, fixture.Active = "10.77.3", "10.77.3.0/24", "10.77.3.28"
				user = egressFullRules(t, fixture)
			}
			egressReadback(t, fixture, user, egressForward)
			compareEgressReadback(t, fixture, want)
		})
	}
}

func TestEgressReadbackTaggedCoverage(t *testing.T) {
	for _, test := range []struct {
		body string
		want int
	}{
		{"-m conntrack --ctstate RELATED,ESTABLISHED --ctdir REPLY -j ACCEPT", 0},
		{"-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", 1},
		{"-s 172.28.0.25/32 -j ACCEPT", 0},
		{"-s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT", 0},
		{"-s 172.28.0.0/24 -d 0.0.0.0/0 -j ACCEPT", 1},
		{"-s 172.28.0.0/24 -p tcp -m conntrack --ctstate ESTABLISHED -j REJECT --reject-with tcp-reset", 0},
		{"-s 172.28.0.0/24 -p tcp -j ACCEPT", 1},
	} {
		t.Run(test.body, func(t *testing.T) {
			fixture := newEgressFixture(t)
			egressReadback(t, fixture, egressRule(test.body)+egressDrop, egressForward)
			compareEgressReadback(t, fixture, test.want)
		})
	}
}

func TestEgressReadbackFallbacks(t *testing.T) {
	for _, test := range []string{"podman", "nul", "octal-prefix", "missing-sort", "missing-tr", "missing-paste", "bare-tool"} {
		t.Run(test, func(t *testing.T) {
			fixture := newEgressFixture(t)
			user := egressDrop
			switch test {
			case "podman":
				t.Setenv("PITHEAD_ENGINE", "podman")
			case "nul":
				user = strings.ReplaceAll(user, "DROP", "DR\x00OP")
			case "octal-prefix":
				user = "-A DOCKER-USER -s 10.0.0.0/08 -j ACCEPT\n" + egressDrop
			case "bare-tool":
				if err := os.Remove(filepath.Join(fixture.lan.Bin, "sort")); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(fixture.lan.Bin, "sort"), []byte("exit 0\n"), 0o755); err != nil {
					t.Fatal(err)
				}
			default:
				if err := os.Remove(filepath.Join(fixture.lan.Bin, strings.TrimPrefix(test, "missing-"))); err != nil {
					t.Fatal(err)
				}
			}
			egressReadback(t, fixture, user, egressForward)
			if code, err := firewall.TorEnforced(fixture.TorConfig); code != 0 || !errors.Is(err, firewall.ErrUnsupportedInput) {
				t.Fatalf("fallback: %d, %v", code, err)
			}
		})
	}
}
