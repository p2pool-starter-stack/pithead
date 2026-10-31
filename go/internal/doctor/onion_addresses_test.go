package doctor

import (
	"errors"
	"reflect"
	"testing"
)

func TestOnionAddressesFixedOrderAndProfiles(t *testing.T) {
	got, err := (OnionAddresses{
		Profiles:  "",
		Addresses: []string{"ignored\x00", "ignored\x00", "p2pool.onion\n", "extra\x00"},
	}).Findings()
	want := []Finding{
		{"node-onion-address", "ok", "MONERO_ONION_ADDRESS not needed — that node runs elsewhere, so it has no inbound hidden service."},
		{"node-onion-address", "ok", "TARI_ONION_ADDRESS not needed — that node runs elsewhere, so it has no inbound hidden service."},
		{"node-onion-address", "ok", "P2POOL_ONION_ADDRESS set."},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Findings() = %#v, %v; want %#v", got, err, want)
	}

	got, err = (OnionAddresses{
		Profiles:  "local_node_plus,local_tari\n",
		Addresses: []string{"placeholder", "tari.onion", ""},
	}).Findings()
	want = []Finding{
		{"node-onion-address", "ok", "MONERO_ONION_ADDRESS not needed — that node runs elsewhere, so it has no inbound hidden service."},
		{"node-onion-address", "ok", "TARI_ONION_ADDRESS set."},
		{"node-onion-address", "warn", "P2POOL_ONION_ADDRESS is not provisioned (value: 'empty') — re-run './pithead setup' to generate Tor hidden services."},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("profile Findings() = %#v, %v; want %#v", got, err, want)
	}
}

func TestOnionAddressesMissingRemedies(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		got, err := (OnionAddresses{
			Profiles:         "local_node,local_tari",
			Addresses:        []string{"placeholder", "", "placeholder"},
			DashboardEnabled: "true",
			DashboardAddress: "placeholder",
			Appliance:        appliance,
		}).Findings()
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 4 {
			t.Fatalf("Findings() returned %d rows: %#v", len(got), got)
		}
		if !appliance {
			want := []Finding{
				{"node-onion-address", "warn", "MONERO_ONION_ADDRESS is not provisioned (value: 'placeholder') — re-run './pithead setup' to generate Tor hidden services."},
				{"node-onion-address", "warn", "TARI_ONION_ADDRESS is not provisioned (value: 'empty') — re-run './pithead setup' to generate Tor hidden services."},
				{"node-onion-address", "warn", "P2POOL_ONION_ADDRESS is not provisioned (value: 'placeholder') — re-run './pithead setup' to generate Tor hidden services."},
				{"dashboard-onion-address", "warn", "DASHBOARD_ONION_ADDRESS is not provisioned yet — re-run './pithead setup' or './pithead apply'."},
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("host Findings() = %#v, want %#v", got, want)
			}
			continue
		}
		want := []Finding{
			{"node-onion-address", "warn", "MONERO_ONION_ADDRESS is not provisioned (value: 'placeholder') — its Tor hidden service has not been generated. This machine regenerates it the next time it applies its configuration, so saving any change from the dashboard provisions it."},
			{"node-onion-address", "warn", "TARI_ONION_ADDRESS is not provisioned (value: 'empty') — its Tor hidden service has not been generated. This machine regenerates it the next time it applies its configuration, so saving any change from the dashboard provisions it."},
			{"node-onion-address", "warn", "P2POOL_ONION_ADDRESS is not provisioned (value: 'placeholder') — its Tor hidden service has not been generated. This machine cannot finish applying its configuration while it is missing, so no dashboard surface regenerates it — correcting this needs console access."},
			{"dashboard-onion-address", "warn", "DASHBOARD_ONION_ADDRESS is not provisioned yet — the dashboard's own hidden service has not been generated. This machine regenerates it the next time it applies its configuration, so saving any change from the dashboard provisions it."},
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("appliance Findings() = %#v, want %#v", got, want)
		}
	}
}

func TestOnionAddressesDashboardStatus(t *testing.T) {
	for _, test := range []struct {
		name  string
		input OnionAddresses
		want  string
	}{
		{"disabled ignores other values", OnionAddresses{DashboardEnabled: "false", DashboardAddress: "\x00", ClientAuth: "\x00", Program: "\x00"}, ""},
		{"missing ignores auth and program", OnionAddresses{DashboardEnabled: "true", DashboardAddress: "placeholder\n", ClientAuth: "\x00", Program: "\x00"}, ""},
		{"login ignores program", OnionAddresses{DashboardEnabled: "true\n", DashboardAddress: "dash.onion\n", ClientAuth: "false\n", Program: "\x00"}, "http://dash.onion (login required)"},
		{"client auth preserves program", OnionAddresses{DashboardEnabled: "true", DashboardAddress: "dash.onion", ClientAuth: "true", Program: "pithead\nnext"}, "http://dash.onion (client-auth ON + login; get your client key with 'pithead\nnext onion-client-key')"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := test.input.DashboardStatus()
			if err != nil || got != test.want {
				t.Fatalf("DashboardStatus() = %q, %v; want %q", got, err, test.want)
			}
		})
	}
}

func TestOnionAddressesRejectsReachedNUL(t *testing.T) {
	tests := []OnionAddresses{
		{Profiles: "\x00"},
		{Profiles: "local_node", Addresses: []string{"\x00"}},
		{Addresses: []string{"", "", "ok"}, DashboardEnabled: "\x00"},
		{Addresses: []string{"", "", "ok"}, DashboardEnabled: "true", DashboardAddress: "\x00"},
		{Addresses: []string{"", "", "ok"}, DashboardEnabled: "true", DashboardAddress: "dash.onion", ClientAuth: "\x00"},
		{Addresses: []string{"", "", "ok"}, DashboardEnabled: "true", DashboardAddress: "dash.onion", ClientAuth: "true", Program: "\x00"},
	}
	for index, input := range tests {
		if findings, err := input.Findings(); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Errorf("case %d Findings() = %#v, %v", index, findings, err)
		}
	}
}

func TestOnionAddressesDashboardFinding(t *testing.T) {
	got, err := (OnionAddresses{
		Addresses:        []string{"ignored", "ignored", "p2pool.onion"},
		DashboardEnabled: "true",
		DashboardAddress: "dash.onion",
		ClientAuth:       "true",
		Program:          "./pithead",
	}).Findings()
	want := Finding{"dashboard-onion-address", "ok", "Dashboard onion: http://dash.onion (client-auth ON + login; get your client key with './pithead onion-client-key')"}
	if err != nil || len(got) != 4 || got[3] != want {
		t.Fatalf("Findings() = %#v, %v; want final %#v", got, err, want)
	}
}
