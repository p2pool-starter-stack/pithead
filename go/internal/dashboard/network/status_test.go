package network

import (
	"math/big"
	"strings"
	"testing"
)

func numeric(kind, value string) numericValue {
	return numericValue{Kind: kind, Value: &value}
}

func invalidNumeric() numericValue {
	return numericValue{Kind: "invalid"}
}

func TestStatusFieldValidityBoundaries(t *testing.T) {
	max := "9007199254740992"
	tests := []struct {
		name    string
		rc      numericValue
		checked numericValue
		want    bool
	}{
		{"integer maximum", numeric("int", "0"), numeric("int", max), true},
		{"integer minimum", numeric("int", "5"), numeric("int", "-"+max), true},
		{"integer above", numeric("int", "0"), numeric("int", "9007199254740993"), false},
		{"float maximum", numeric("int", "0"), numeric("float", "9007199254740992.0"), true},
		{"float above", numeric("int", "0"), numeric("float", "9007199254740994.0"), false},
		{"nan", numeric("int", "0"), numeric("float", "nan"), false},
		{"infinity", numeric("int", "0"), numeric("float", "inf"), false},
		{"float rc", numeric("float", "0.0"), numeric("int", "0"), false},
		{"invalid rc", invalidNumeric(), numeric("int", "0"), false},
		{"invalid checked", numeric("int", "0"), invalidNumeric(), false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := statusFieldsValid(test.rc, test.checked)
			if err != nil || got != test.want {
				t.Fatalf("valid=%v err=%v", got, err)
			}
		})
	}
	large := new(big.Int).Lsh(big.NewInt(1), 999).String()
	if valid, err := statusFieldsValid(numeric("int", large), numeric("int", "0")); err != nil || !valid {
		t.Fatalf("1000-bit rc valid=%v err=%v", valid, err)
	}
	tooLarge := new(big.Int).Lsh(big.NewInt(1), 1000).String()
	if _, err := statusFieldsValid(numeric("int", tooLarge), numeric("int", "0")); err == nil {
		t.Fatal("accepted rc above bit limit")
	}
}

func TestFirewallStatusResult(t *testing.T) {
	tests := []struct {
		name string
		rc   string
		age  numericValue
		want string
	}{
		{"fresh enforced integer", "0", numeric("int", "360"), stateEnforced},
		{"stale enforced integer", "0", numeric("int", "361"), stateUnverified},
		{"fresh enforced float", "0", numeric("float", "360.0"), stateEnforced},
		{"stale enforced float", "0", numeric("float", "360.0000001"), stateUnverified},
		{"nan remains fresh", "1", numeric("float", "nan"), stateMissing},
		{"infinity is stale", "1", numeric("float", "inf"), stateUnverified},
		{"missing two", "2", numeric("int", "0"), stateMissing},
		{"missing four", "4", numeric("int", "0"), stateMissing},
		{"missing five", "5", numeric("int", "0"), stateMissing},
		{"unknown rc", "3", numeric("int", "0"), stateUnverified},
		{"large rc", new(big.Int).Lsh(big.NewInt(1), 999).String(), numeric("int", "0"), stateUnverified},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := firewallState(numeric("int", test.rc), test.age)
			if err != nil || got != test.want {
				t.Fatalf("state=%q err=%v", got, err)
			}
		})
	}
}

func TestFirewallPlan(t *testing.T) {
	disabled, err := buildFirewallPlan(false, stateMissing)
	if err != nil || disabled != (firewallPlan{}) {
		t.Fatalf("disabled=%#v err=%v", disabled, err)
	}
	enforced, err := buildFirewallPlan(true, stateEnforced)
	if err != nil || enforced != (firewallPlan{Firewall: true, Overlay: true}) {
		t.Fatalf("enforced=%#v err=%v", enforced, err)
	}
	missing, err := buildFirewallPlan(true, stateMissing)
	if err != nil || missing != (firewallPlan{Overlay: true, Warn: true, Prefix: missingPrefix}) {
		t.Fatalf("missing=%#v err=%v", missing, err)
	}
	unverified, err := buildFirewallPlan(true, stateUnverified)
	if err != nil || unverified != (firewallPlan{Overlay: true, Warn: true, Prefix: unverifiedPrefix}) {
		t.Fatalf("unverified=%#v err=%v", unverified, err)
	}
	if _, err := buildFirewallPlan(true, "bad"); err == nil {
		t.Fatal("accepted invalid state")
	}
}

func TestFirewallProtocolOperationsAndMalformedInputs(t *testing.T) {
	validity, err := build([]byte(`{"operation":"firewall-status-valid","rc":{"kind":"int","value":"0"},"checked_at":{"kind":"float","value":"nan"}}`))
	if err != nil || validity != false {
		t.Fatalf("validity=%#v err=%v", validity, err)
	}
	result, err := build([]byte(`{"operation":"firewall-status-result","rc":{"kind":"int","value":"1"},"age":{"kind":"float","value":"nan"}}`))
	if err != nil || result != stateMissing {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	plan, err := build([]byte(`{"operation":"firewall-plan","configured":true,"state":"unverified"}`))
	if err != nil || plan != (firewallPlan{Overlay: true, Warn: true, Prefix: unverifiedPrefix}) {
		t.Fatalf("plan=%#v err=%v", plan, err)
	}
	cases := []string{
		`{"operation":"firewall-status-valid","rc":{"kind":"int"},"checked_at":{"kind":"int","value":"0"}}`,
		`{"operation":"firewall-status-valid","rc":{"kind":"invalid","value":"0"},"checked_at":{"kind":"int","value":"0"}}`,
		`{"operation":"firewall-status-valid","rc":{"kind":"other"},"checked_at":{"kind":"int","value":"0"}}`,
		`{"operation":"firewall-status-valid","rc":{"kind":"int","value":"0","raw":false},"checked_at":{"kind":"int","value":"0"}}`,
		`{"operation":"firewall-status-result","rc":{"kind":"float","value":"0.0"},"age":{"kind":"int","value":"0"}}`,
		`{"operation":"firewall-status-result","rc":{"kind":"int","value":"0"},"age":{"kind":"invalid"}}`,
		`{"operation":"firewall-plan","configured":true,"state":"bad"}`,
		`{"operation":"firewall-plan","configured":true,"state":"enforced","now":0}`,
	}
	for _, input := range cases {
		if _, err := build([]byte(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
	tooLarge := new(big.Int).Lsh(big.NewInt(1), 1000).String()
	request := `{"operation":"firewall-status-result","rc":{"kind":"int","value":"` + tooLarge + `"},"age":{"kind":"int","value":"0"}}`
	if _, err := build([]byte(request)); err == nil || !strings.Contains(err.Error(), "integer metadata") {
		t.Fatalf("oversized integer error=%v", err)
	}
}
