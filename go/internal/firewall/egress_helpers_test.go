package firewall

import (
	"errors"
	"reflect"
	"testing"
)

func TestEgressTokenise(t *testing.T) {
	tests := []struct {
		name    string
		line    string
		want    []egressToken
		ok      bool
		wantErr bool
	}{
		{"bare", "-A DOCKER-USER -j ACCEPT", []egressToken{{"-A", false}, {"DOCKER-USER", false}, {"-j", false}, {"ACCEPT", false}}, true, false},
		{"quoted", `-m string --string "! -s 0.0.0.0/0 x"`, []egressToken{{"-m", false}, {"string", false}, {"--string", false}, {"! -s 0.0.0.0/0 x", true}}, true, false},
		{"escapes", `--comment "a\\b\"c"`, []egressToken{{"--comment", false}, {`a\b"c`, true}}, true, false},
		{"joined", `ab" cd"ef`, []egressToken{{"ab cdef", true}}, true, false},
		{"empty quote", `""`, []egressToken{{"", true}}, true, false},
		{"whitespace", " \t\v\f\r\n ", []egressToken{}, true, false},
		{"partial unterminated", `one two "three`, []egressToken{{"one", false}, {"two", false}}, false, false},
		{"partial escape", `one "two\`, []egressToken{{"one", false}}, false, false},
		{"nul", "one\x00two", nil, false, true},
		{"quoted newline", "one \"two\nthree\"", nil, false, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok, err := egressTokenise(test.line)
			if !reflect.DeepEqual(got, test.want) || ok != test.ok || errors.Is(err, ErrUnsupportedInput) != test.wantErr {
				t.Fatalf("egressTokenise(%q) = %#v, %v, %v", test.line, got, ok, err)
			}
		})
	}
}

func TestEgressCIDR(t *testing.T) {
	valid := []string{"0.0.0.0/0", "255.255.255.255/32", "001.002.003.004/00032", "1.2.3.4.", "1.2.3.4..", "1.2.3.4"}
	for _, value := range valid {
		if got, err := egressValidCIDR(value); !got || err != nil {
			t.Errorf("egressValidCIDR(%q) = %v, %v", value, got, err)
		}
	}
	invalid := []string{"", "1.2.3", ".1.2.3.4", "1.2.3.4...", "1.2.3.256", "1.2.3.-1", "1.2.3.4/", "1.2.3.4/33", "1.2.3.4/24/25"}
	for _, value := range invalid {
		if got, err := egressValidCIDR(value); got || err != nil {
			t.Errorf("egressValidCIDR(%q) = %v, %v", value, got, err)
		}
	}
	if got, err := egressValidCIDR("1.2.3.4/18446744073709551616"); got || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("overflow = %v, %v", got, err)
	}
	overlaps := []struct {
		first, second string
		want          bool
	}{
		{"172.28.0.0/24", "172.28.0.9", true},
		{"172.28.0.9", "172.28.0.0/24", true},
		{"172.28.0.0/24", "172.29.0.0/24", false},
		{"1.2.3.4", "1.2.3.4/32", true},
		{"1.2.3.4/0", "255.255.255.255", true},
	}
	for _, test := range overlaps {
		got, err := egressCIDROverlaps(test.first, test.second)
		if got != test.want || err != nil {
			t.Errorf("egressCIDROverlaps(%q, %q) = %v, %v", test.first, test.second, got, err)
		}
	}
	contains := []struct {
		container, member string
		want              bool
	}{
		{"172.28.0.0/16", "172.28.3.0/24", true},
		{"172.28.3.0/24", "172.28.0.0/16", false},
		{"172.28.0.0/16", "172.29.0.0/24", false},
		{"0.0.0.0/0", "255.255.255.255", true},
	}
	for _, test := range contains {
		got, err := egressCIDRContains(test.container, test.member)
		if got != test.want || err != nil {
			t.Errorf("egressCIDRContains(%q, %q) = %v, %v", test.container, test.member, got, err)
		}
	}
	if got, err := egressCIDROverlaps("1.2.3.4..", "1.2.3.4"); got || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("ambiguous arithmetic = %v, %v", got, err)
	}
	if got, err := egressCIDROverlaps("1.2.3.4/024", "1.2.3.4/24"); got || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("octal prefix = %v, %v", got, err)
	}
}

func TestEgressRuleShadows(t *testing.T) {
	const subnet = "172.28.0.0/24"
	tests := []struct {
		name string
		line string
		want bool
	}{
		{"unscoped accept", "-A DOCKER-USER -j ACCEPT", true},
		{"overlap", "-A DOCKER-USER -s 172.28.0.9 -j ACCEPT", true},
		{"supernet", "-A DOCKER-USER --source 172.28.0.0/16 -j ACCEPT", true},
		{"disjoint", "-A DOCKER-USER --src 172.29.0.0/24 -j ACCEPT", false},
		{"negated contains", "-A DOCKER-USER ! -s 172.28.0.0/16 -j ACCEPT", false},
		{"negated disjoint", "-A DOCKER-USER ! -s 10.0.0.0/8 -j ACCEPT", true},
		{"separated bang", "-A DOCKER-USER ! -p tcp -s 172.29.0.0/24 -j ACCEPT", false},
		{"deny target", "-A DOCKER-USER -s nonsense -j REJECT", false},
		{"unknown target", "-A DOCKER-USER -s 172.29.0.0/24 -j OTHER", false},
		{"duplicate source", "-s 172.29.0.0/24 -s 10.0.0.0/8 -j ACCEPT", true},
		{"quoted flag", `--comment "-s 0.0.0.0/0" -s 172.29.0.0/24 -j ACCEPT`, false},
		{"quoted target flag", `-s 172.29.0.0/24 "-j" ACCEPT`, false},
		{"quoted source value", `-s "172.28.0.0/24" -j ACCEPT`, true},
		{"missing value", "-A DOCKER-USER -s", true},
		{"unterminated", `-s 172.29.0.0/24 "broken`, true},
		{"invalid source", "-s 172.28.0.999 -j ACCEPT", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := egressRuleShadows(test.line, subnet)
			if got != test.want || err != nil {
				t.Fatalf("egressRuleShadows(%q) = %v, %v", test.line, got, err)
			}
		})
	}
	if got, err := egressRuleShadows("-s 172.28.0.0/24 -j ACCEPT\x00", subnet); got || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("nul = %v, %v", got, err)
	}
}

func TestEgressSyncAccept(t *testing.T) {
	const ip = "172.28.0.26"
	valid := []string{
		`-A DOCKER-USER -s 172.28.0.26 -m comment --comment pithead-tor-egress -j ACCEPT`,
		`-j ACCEPT --comment "pithead-tor-egress" -m comment -s 172.28.0.26/32 -A DOCKER-USER`,
		`--comment "" --comment pithead-tor-egress -j ACCEPT -m comment -s 172.28.0.26 -A DOCKER-USER`,
	}
	for _, line := range valid {
		if got, err := egressSyncAccept(line, ip); !got || err != nil {
			t.Errorf("egressSyncAccept(%q) = %v, %v", line, got, err)
		}
	}
	invalid := []string{
		`-A DOCKER-USER -s 172.28.0.27 -m comment --comment pithead-tor-egress -j ACCEPT`,
		`-A DOCKER-USER -s "172.28.0.26" -m comment --comment pithead-tor-egress -j ACCEPT`,
		`-A OTHER -s 172.28.0.26 -m comment --comment pithead-tor-egress -j ACCEPT`,
		`-A DOCKER-USER -s 172.28.0.26 -s 172.28.0.26 -m comment --comment pithead-tor-egress -j ACCEPT`,
		`-A DOCKER-USER -s 172.28.0.26 -m comment --comment pithead-tor-egress -p tcp -j ACCEPT`,
		`-A DOCKER-USER -s 172.28.0.26 -m comment --comment pithead-tor-egress -j`,
		`-A DOCKER-USER -s 172.28.0.26 -m comment --comment pithead-tor-egress -j "ACCEPT"`,
	}
	for _, line := range invalid {
		if got, err := egressSyncAccept(line, ip); got || err != nil {
			t.Errorf("egressSyncAccept(%q) = %v, %v", line, got, err)
		}
	}
}

func TestEgressCanonical(t *testing.T) {
	first := `-A DOCKER-USER -s 172.28.0.26/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`
	second := `--ctstate ESTABLISHED,RELATED -j ACCEPT -m conntrack -s 172.28.0.26 -A DOCKER-USER`
	one, ok, err := egressCanonical(first)
	if err != nil || !ok {
		t.Fatalf("first canonical = %q, %v, %v", one, ok, err)
	}
	two, ok, err := egressCanonical(second)
	if err != nil || !ok || one != two {
		t.Fatalf("second canonical = %q, %v, %v; want %q", two, ok, err, one)
	}
	if one[len(one)-1] == '\n' {
		t.Fatalf("canonical has final newline: %q", one)
	}
	invalid := []string{"", "   ", "-A", `"-A" DOCKER-USER`, "value other", `-A "unterminated`}
	for _, line := range invalid {
		if got, ok, err := egressCanonical(line); got != "" || ok || err != nil {
			t.Errorf("egressCanonical(%q) = %q, %v, %v", line, got, ok, err)
		}
	}
	if got, ok, err := egressCanonical("-A \"bad\nvalue\""); got != "" || ok || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("newline = %q, %v, %v", got, ok, err)
	}
}
