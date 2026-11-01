package config

import (
	"errors"
	"testing"
)

var dashboardAccessDefaults = []byte(`{
  "values":{"dashboard":{"host":"auto"}},
  "appliance":{"dashboard":{"host":"pithead"}},
  "materialize":[],
  "LEGACY_ABSENT":[{"path":"dashboard.host","platform":"appliance","value":"auto"}]
}`)

func TestParseDashboardAccessDefaultsAndValues(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		platform string
		want     DashboardAccess
	}{
		{"DIY defaults", `{}`, "diy", DashboardAccess{Assigned: 5, Values: [5]string{"", "", "true", "false", ""}, NeedsHostTimezone: true}},
		{"appliance legacy default", `{}`, "appliance", DashboardAccess{Assigned: 5, Values: [5]string{"", "", "true", "false", ""}, NeedsHostTimezone: true}},
		{"values", `{"dashboard":{"host":"box_1.lan","port":"8443","secure":"YES","expose_public_ip":1,"timezone":"America/Chicago"}}`, "diy", DashboardAccess{Assigned: 5, Values: [5]string{"box_1.lan", "8443", "YES", "1", "America/Chicago"}}},
		{"false alternatives", `{"dashboard":{"host":false,"port":false,"secure":false,"expose_public_ip":false,"timezone":false}}`, "diy", DashboardAccess{Assigned: 5, Values: [5]string{"false", "", "false", "false", ""}, NeedsHostTimezone: true}},
		{"dynamic sentinels", `{"dashboard":{"host":"DYNAMIC_HOST","port":"DYNAMIC_DATA","timezone":"DYNAMIC_ID"}}`, "diy", DashboardAccess{Assigned: 5, Values: [5]string{"", "", "true", "false", ""}, NeedsHostTimezone: true}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseDashboardAccess([]byte(test.raw), dashboardAccessDefaults, DashboardAccessInput{Platform: test.platform})
			if err != nil || got != test.want {
				t.Fatalf("ParseDashboardAccess() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseDashboardAccessVerdictsAndPrecedence(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want DashboardAccess
	}{
		{
			"host characters before port read",
			`{"dashboard":{"host":"bad host","port":[]}}`,
			DashboardAccess{Assigned: 1, Values: [5]string{"bad host"}, Reason: `dashboard.host must be a hostname or IP address — only letters, digits, dots, hyphens, and colons (got "bad host").`},
		},
		{
			"port leading zero before secure read",
			`{"dashboard":{"host":"box","port":"080","secure":[]}}`,
			DashboardAccess{Assigned: 2, Values: [5]string{"box", "080"}, Reason: `dashboard.port must be a whole number between 1 and 65535, or "auto" (got "080").`},
		},
		{
			"port upper bound",
			`{"dashboard":{"port":65536}}`,
			DashboardAccess{Assigned: 2, Values: [5]string{"", "65536"}, Reason: `dashboard.port must be a whole number between 1 and 65535, or "auto" (got "65536").`},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseDashboardAccess([]byte(test.raw), dashboardAccessDefaults, DashboardAccessInput{Platform: "diy"})
			if err != nil || got != test.want {
				t.Fatalf("ParseDashboardAccess() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseDashboardAccessRejectsUnsupportedInput(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		defaults []byte
	}{
		{"invalid JSON", `{`, dashboardAccessDefaults},
		{"duplicate", `{"dashboard":{},"dashboard":{}}`, dashboardAccessDefaults},
		{"scalar parent", `{"dashboard":4}`, dashboardAccessDefaults},
		{"compound host", `{"dashboard":{"host":[]}}`, dashboardAccessDefaults},
		{"control host", `{"dashboard":{"host":"bad\nhost"}}`, dashboardAccessDefaults},
		{"compound port", `{"dashboard":{"port":{}}}`, dashboardAccessDefaults},
		{"decimal port", `{"dashboard":{"port":1.0}}`, dashboardAccessDefaults},
		{"compound secure", `{"dashboard":{"secure":[]}}`, dashboardAccessDefaults},
		{"compound expose", `{"dashboard":{"expose_public_ip":{}}}`, dashboardAccessDefaults},
		{"compound timezone", `{"dashboard":{"timezone":[]}}`, dashboardAccessDefaults},
		{"control timezone", `{"dashboard":{"timezone":"bad\ntimezone"}}`, dashboardAccessDefaults},
		{"invalid defaults", `{}`, []byte(`{}`)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseDashboardAccess([]byte(test.raw), test.defaults, DashboardAccessInput{Platform: "diy"})
			if got != (DashboardAccess{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("ParseDashboardAccess() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}
