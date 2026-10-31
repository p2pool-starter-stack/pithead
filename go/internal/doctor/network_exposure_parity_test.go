//go:build parity

package doctor

import (
	"strconv"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

func TestNetworkPublicIPClassification(t *testing.T) {
	input := newNetworkFixture(t)
	values := []string{"", "not-an-ip", "999.1.1.1", "1.2.3", "8.8.8.8", "1.1.1.1", "0.0.0.0", "10.0.0.1", "127.0.0.1", "169.254.1.1", "192.168.1.1", "100.64.0.1", "100.127.255.255", "100.128.0.1", "172.15.0.1", "172.16.0.1", "172.31.255.255", "172.32.0.1", "010.0.0.1", "000.0.0.0", "169.025.1.1", "169.254.001.001", "192.168.001.001", "172.016.0.1", "100.064.0.1", "1.2.3.256", "1.2.3.0001", " 8.8.8.8", "8.8.8.8\n", "::1", "fe80::1", "fc00::1", "ff02::1", "1fff::", "2000::", "3fff::", "4000::", "2001:db8::1", "2606:4700:4700::1111", "2001:garbage", "2001:", "00002001:", "0x2001:", "200g::", "8000000000002001:"}
	for _, value := range values {
		input.Prefix = value
		result := runNetworkBash(t, input, "public-ip")
		public, err := host.PublicIP(value)
		code := 1
		if public {
			code = 0
		}
		if err != nil || result.code != code || result.stdout != "" || result.stderr != "" {
			t.Fatalf("PublicIP(%q) = %v, %v; Bash %+v", value, public, err, result)
		}
	}
}

func TestNetworkPublicInterfaceParsing(t *testing.T) {
	for _, output := range []string{"", "2: eth0 inet 8.8.8.8/24", "2: eth0 inet 8.8.8.8/24\n", "2: eth0 inet 8.8.8.8/24\n2: eth0 inet 8.8.8.8/24\n", "1: lo inet 127.0.0.1/8\n2: eth0 inet 203.0.113.5/24\n3: eth1 inet6 2001:db8::1/64\n", "2: eth0 inet6 2001:garbage/64\n", "2:\teth0\tinet\t203.0.113.5/24\tscope global\n", "2: eth0 link 8.8.8.8/24\nshort inet 8.8.8.8/24\n2: eth0 inet 203.0.113.5/24\nunterminated"} {
		for _, code := range []int{0, 1} {
			t.Run(strconv.Quote(output)+"/"+strconv.Itoa(code), func(t *testing.T) {
				input := newNetworkFixture(t)
				networkToolFixture(t, input, "ip", output, code)
				result := runNetworkBash(t, input, "public-ips")
				wantCalls := networkCalls(t, input, true)
				public, err := host.PublicIPs()
				if err != nil || result.code != 0 || result.stdout != public || result.stderr != "" || networkCalls(t, input, true) != wantCalls {
					t.Fatalf("PublicIPs() = %q, %v; Bash %+v", public, err, result)
				}
			})
		}
	}
}

func TestNetworkExposureBindings(t *testing.T) {
	for _, output := range []string{"", "2: eth0 inet 192.168.1.5/24\n", "2: eth0 inet 203.0.113.5/24\n3: eth1 inet6 2001:db8::1/64\n"} {
		for _, bind := range []string{"", "0.0.0.0", "127.0.0.1", "203.0.113.5", "2001:db8::1", "::", "203.0.113.5\n", "wrong\n203.0.113.5", "\n"} {
			t.Run(strconv.Quote(output+bind), func(t *testing.T) {
				input := newNetworkFixture(t)
				networkToolFixture(t, input, "ip", output, 0)
				input.Bind = bind
				compareNetwork(t, input, "exposure")
				compareNetworkSetup(t, input)
			})
		}
	}
}

func TestNetworkExposureMitigations(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, password := range []string{"", "fixture-password", "\n", " \n"} {
			for _, tls := range []string{"", "false", "true", "TRUE", "yes", "ON", "1", "true \n", "true\n\n"} {
				t.Run(strconv.FormatBool(appliance)+"/"+strconv.Quote(password+tls), func(t *testing.T) {
					input := newNetworkFixture(t)
					networkToolFixture(t, input, "ip", "2: eth0 inet 203.0.113.5/24\n", 0)
					input.Password, input.TLS, input.Appliance = password, tls, appliance
					compareNetwork(t, input, "exposure")
					findings, err := input.Findings()
					if err != nil || strings.Contains(findings[0].Message, "203.0.113.5") || strings.Contains(findings[0].Message, "fixture-password") {
						t.Fatalf("exposure values leaked: %#v, %v", findings, err)
					}
				})
			}
		}
	}
}

func TestNetworkPortPrecedence(t *testing.T) {
	for _, inputValue := range []Stratum{{}, {EnvPort: "4444", EnvBind: "bind"}, {EnvPresent: true, EnvPort: "4444\n\n", EnvBind: "bind\n"}, {EnvPresent: true, EnvPort: "\n", EnvBind: "\n"}, {Port: "5555\n", Bind: "bind\n", EnvPresent: true, EnvPort: "4444", EnvBind: "ignored"}, {Port: "\n", Bind: "0.0.0.0", EnvPresent: true, EnvPort: "4444"}} {
		input := newNetworkFixture(t)
		input.Stratum = inputValue
		result := runNetworkBash(t, input, "port")
		port, err := input.EffectivePort()
		if err != nil || result.code != 0 || result.stdout != port || result.stderr != "" {
			t.Fatalf("port(%#v) = %q, %v; Bash %+v", inputValue, port, err, result)
		}
		networkToolFixture(t, input, "ip", "2: eth0 inet 203.0.113.5/24\n", 0)
		compareNetwork(t, input, "exposure")
	}
}

func compareNetworkSetup(t *testing.T, input networkFixture) {
	t.Helper()
	networkCalls(t, input, true)
	result := runNetworkBash(t, input, "setup")
	wantCalls := networkCalls(t, input, true)
	warnings, err := input.Warnings()
	var stderr strings.Builder
	for _, warning := range warnings {
		stderr.WriteString("[WARNING] " + warning + "\n")
	}
	if err != nil || result.code != 0 || result.stdout != "" || result.stderr != stderr.String() || networkCalls(t, input, true) != wantCalls {
		t.Fatalf("setup Go %q, %v; Bash %+v", stderr.String(), err, result)
	}
}
