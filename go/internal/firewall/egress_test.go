package firewall

import (
	"errors"
	"testing"
)

func TestEgressRuntimeReturnCodes(t *testing.T) {
	drop := "-A DOCKER-USER -m comment --comment " + EgressTag + " -s 172.28.0.0/24 -j DROP"
	for _, test := range []struct {
		user, forward, fails string
		want                 int
	}{
		{drop, "-A FORWARD -j DOCKER-USER", "", 0},
		{drop, "", "initial", 3},
		{drop, "", "docker", 1},
		{"", "", "", 1},
		{drop, "", "forward", 4},
		{"-A DOCKER-USER -j ACCEPT\n" + drop, "-A FORWARD -j DOCKER-USER", "", 5},
	} {
		t.Run(test.user+test.fails, func(t *testing.T) {
			dir, _ := iptablesTools(t, "", test.user, test.forward, test.fails)
			for _, tool := range []string{"sort", "tr", "paste"} {
				writeTool(t, dir, tool, "exit 0")
			}
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", "docker")
			if code, err := TorEnforced(TorConfig{}); err != nil || code != test.want {
				t.Fatalf("TorEnforced: %d, %v; want %d", code, err, test.want)
			}
		})
	}
}

func TestEgressRuntimeGates(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	t.Setenv("PITHEAD_ENGINE", "docker")
	if code, err := TorEnforced(TorConfig{Active: "\x00"}); code != 2 || err != nil {
		t.Fatalf("missing backend before config: %d, %v", code, err)
	}
	t.Setenv("PITHEAD_ENGINE", "podman")
	if code, err := TorEnforced(TorConfig{}); code != 0 || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("nft fallback: %d, %v", code, err)
	}
}
