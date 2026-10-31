//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetworkContainerRunning(t *testing.T) {
	for _, output := range []string{"", "\n\n", "cid\n", " \n"} {
		for _, code := range []int{0, 1, 127} {
			input := newNetworkFixture(t)
			networkToolFixture(t, input, "docker", output, code)
			input.Prefix = "tor"
			result := runNetworkBash(t, input, "running")
			wantCalls := networkCalls(t, input, true)
			running, err := ContainerRunning(input.Prefix)
			want := 1
			if running {
				want = 0
			}
			if err != nil || result.code != want || result.stdout != "" || result.stderr != "" || networkCalls(t, input, true) != wantCalls {
				t.Fatalf("running(%q, %d) = %v, %v; Bash %+v", output, code, running, err, result)
			}
		}
	}
}

func TestNetworkMiningShortCircuit(t *testing.T) {
	for _, names := range [][]string{nil, {"p2pool"}, {"monerod"}, {"xmrig-proxy"}, {"p2pool", "monerod", "xmrig-proxy"}, {"tor"}, {"dashboard"}} {
		input := newNetworkFixture(t)
		networkContainers(t, input, names...)
		result := runNetworkBash(t, input, "mining")
		wantCalls := networkCalls(t, input, true)
		running, err := MiningStackRunning()
		want := 1
		if running {
			want = 0
		}
		if err != nil || result.code != want || result.stdout != "" || result.stderr != "" || networkCalls(t, input, true) != wantCalls {
			t.Fatalf("MiningStackRunning(%v) = %v, %v; Bash %+v", names, running, err, result)
		}
	}
}

func TestNetworkTorRunning(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, names := range [][]string{nil, {"tor"}, {"p2pool"}, {"monerod"}, {"xmrig-proxy"}, {"dashboard"}, {"tor", "p2pool"}} {
			input := newNetworkFixture(t)
			input.Appliance = appliance
			networkContainers(t, input, names...)
			t.Setenv("PITHEAD_ENGINE", "podman")
			compareNetwork(t, input, "tor")
		}
	}
}

func TestNetworkStratumListening(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, output := range []string{"", "LISTEN 0 4096 0.0.0.0:3333 0.0.0.0:*\n", "LISTEN 0 4096 [::]:3333 [::]:*\n", "LISTEN 0 4096 0.0.0.0:4444 0.0.0.0:*\n", "LISTEN 0 4096 0.0.0.0:33330 0.0.0.0:*\n", "row :3333\tother\n"} {
			for _, code := range []int{0, 1} {
				input := newNetworkFixture(t)
				input.Appliance = appliance
				networkContainers(t, input, "xmrig-proxy")
				networkToolFixture(t, input, "ss", output, code)
				compareNetwork(t, input, "listening")
			}
		}
	}
}

func TestNetworkListeningPortPatterns(t *testing.T) {
	for _, port := range []string{"4444", "44.4", "44[0-9]4", "4444\n", "", "\n", "3333\n4444"} {
		input := newNetworkFixture(t)
		input.Port, input.EnvPresent, input.EnvPort = port, true, "4444\n"
		networkContainers(t, input, "xmrig-proxy")
		networkToolFixture(t, input, "ss", "LISTEN 0 4096 [::]:4444 [::]:*\n", 0)
		compareNetwork(t, input, "listening")
	}
}

func TestNetworkListeningPipefail(t *testing.T) {
	input := newNetworkFixture(t)
	networkContainers(t, input, "xmrig-proxy")
	networkToolFixture(t, input, "ss", strings.Repeat("LISTEN 0 4096 [::]:3333 [::]:*\n", 50000), 0)
	writeHostTool(t, input.Bin, "ss", "printf '%s\\n' \"$@\" >>\"$0.log\"\nexec /bin/cat \"$0.output\"\n")
	compareNetwork(t, input, "listening")
}

func TestNetworkTorClearnetEgress(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, prefix := range []string{"", "192.0.2", "192.0.2\n\n", "prefix with spaces"} {
			for _, code := range []int{0, 1, 7, 28} {
				input := newNetworkFixture(t)
				input.Prefix, input.Appliance = prefix, appliance
				networkContainers(t, input, "tor")
				networkToolFixture(t, input, "curl", "", code)
				compareNetwork(t, input, "clearnet")
			}
		}
	}
}

func TestNetworkMissingTools(t *testing.T) {
	input := newNetworkFixture(t)
	for _, operation := range []string{"exposure", "listening", "tor", "clearnet"} {
		compareNetwork(t, input, operation)
	}
	compareNetworkSetup(t, input)
	networkContainers(t, input, "tor", "xmrig-proxy")
	for _, operation := range []string{"listening", "clearnet"} {
		compareNetwork(t, input, operation)
	}
}

func TestNetworkUnsupportedLaunchParity(t *testing.T) {
	for _, operation := range []string{"tor", "listening", "clearnet", "exposure"} {
		t.Run(operation, func(t *testing.T) {
			input := newNetworkFixture(t)
			networkContainers(t, input, "tor", "xmrig-proxy")
			tool := map[string]string{"tor": "docker", "listening": "ss", "clearnet": "curl", "exposure": "ip"}[operation]
			if err := os.WriteFile(filepath.Join(input.Bin, tool), []byte("exit 0\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			result := runNetworkBash(t, input, operation)
			if result.code != 0 || result.stderr == "" {
				t.Fatalf("Bash no-shebang fixture failed: %+v", result)
			}
			var err error
			switch operation {
			case "tor":
				_, err = TorRunning(false)
			case "listening":
				_, err = (StratumListening{Stratum: input.Stratum}).Finding()
			case "clearnet":
				_, err = (TorClearnetEgress{}).Finding()
			case "exposure":
				_, err = input.Findings()
			}
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("%s error = %v; want unsupported", operation, err)
			}
		})
	}
}

func TestNetworkDiagnosticFallbacks(t *testing.T) {
	input := newNetworkFixture(t)
	networkContainers(t, input, "tor", "xmrig-proxy")
	networkToolFixture(t, input, "curl", "unexpected stdout\n", 0)
	result := runNetworkBash(t, input, "clearnet")
	if !strings.Contains(result.stderr, "unexpected stdout") {
		t.Fatal("Bash output fixture did not reach the diagnostic stream")
	}
	if _, err := (TorClearnetEgress{}).Finding(); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("unexpected curl stdout error = %v", err)
	}
	networkToolFixture(t, input, "ss", "", 0)
	input.Port = "["
	result = runNetworkBash(t, input, "listening")
	if result.code != 0 || result.stderr == "" {
		t.Fatal("Bash invalid regex diagnostic missing")
	}
	if _, err := (StratumListening{Stratum: input.Stratum}).Finding(); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("invalid grep expression error = %v", err)
	}
}
