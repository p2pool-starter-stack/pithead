package config

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

var dashboardTestDefaults = []byte(`{
	"values":{"xvb":{"enabled":false},"dashboard":{"tari_required":false}},
	"appliance":{},
	"materialize":[],
	"LEGACY_ABSENT":[
		{"path":"xvb.enabled","value":true},
		{"path":"dashboard.tari_required","value":true}
	]
}`)

func TestDeriveDashboardDefaultsAndValueOrder(t *testing.T) {
	plan, err := DeriveDashboard([]byte(`{}`), dashboardTestDefaults, DashboardInput{
		Platform:     "diy",
		TariMode:     "local",
		MoneroWallet: "48edfHu712345",
	})
	want := []string{
		"true", "true", "na.xmrvsbeast.com:4247", "48edfHu7", "auto",
		"true", "false", "", "", "true",
		"8080", "none", "", "{}",
		"false", "", "", "false",
		"true", "true", "true", "true", "true", "true", "true", "true", "true",
		"true", "true", "true", "true", "true", "true", "true", "true", "true",
		"true", "true", "true", "true", "true", "true", "true", "true", "true",
		"50", "10", "08:00", "", "", "", "true",
	}
	if err != nil || !reflect.DeepEqual(plan.Values(), want) {
		t.Fatalf("DeriveDashboard() = %#v, %v; want %#v, nil", plan.Values(), err, want)
	}
	values := plan.Values()
	values[0] = "changed"
	if plan.Values()[0] != "true" {
		t.Fatal("Values() did not return a clone")
	}
}

func TestDeriveDashboardConfiguredValues(t *testing.T) {
	raw := []byte(`{
		"xvb":{"enabled":false,"tor":"YES","url":"eu.example:4247","donor_id":"donor","donation_level":"whale","standby":{"source":"https://standby.example/api"}},
		"dashboard":{"tari_required":true,"fail_closed":1,"check_for_updates":"false","hashrate_drop_threshold":33,"hashrate_drop_minutes":"7"},
		"healthchecks":{"ping_url":"https://health.example/ping"},
		"workers":{"api_port":9000,"api_auth":"name","api_token":"fleet-token","list":[
			{"name":"rig-a","host":"rig-a.local","api_token":"first-token"},
			{"name":"rig-a","host":"ignored.local","port":9999,"api_token":"ignored-token"},
			{"name":"rig-b","host":"rig-b.local","port":9001,"api_token":"second-token"},
			{"name":"","host":"skip.local","api_token":"skip-token"}
		]},
		"telegram":{"enabled":true,"bot_token":"bot-token","chat_id":"-1001","commands":{"enabled":0},"events":{"node_down":false,"node_recovered":"custom"},"daily_summary_time":"21:30"},
		"notifications":{"webhooks":["https://one.example",null,true,false,2],"ntfy":{"url":"https://ntfy.example/topic","token":"ntfy-token"},"tor":false}
	}`)
	plan, err := DeriveDashboard(raw, dashboardTestDefaults, DashboardInput{
		Platform:     "diy",
		TariMode:     "off",
		MoneroWallet: "unused",
	})
	if err != nil {
		t.Fatal(err)
	}
	values := plan.Values()
	wantPrefix := []string{
		"false", "true", "eu.example:4247", "donor", "whale",
		"false", "true", "https://health.example/ping", "https://standby.example/api", "true",
		"9000", "name", "fleet-token",
		`{"rig-a":{"host":"rig-a.local","port":9000,"token":"first-token"},"rig-b":{"host":"rig-b.local","port":9001,"token":"second-token"}}`,
		"true", "bot-token", "-1001", "0", "false", "custom",
	}
	if !reflect.DeepEqual(values[:len(wantPrefix)], wantPrefix) {
		t.Fatalf("configured prefix = %#v; want %#v", values[:len(wantPrefix)], wantPrefix)
	}
	for index := dashboardEventStart + 2; index < dashboardEventEnd; index++ {
		if values[index] != "true" {
			t.Errorf("event %d = %q; want true", index-dashboardEventStart, values[index])
		}
	}
	wantTail := []string{
		"33", "7", "21:30", "https://one.example  true false 2",
		"https://ntfy.example/topic", "ntfy-token", "false",
	}
	if !reflect.DeepEqual(values[dashboardHashrateDropThreshold:], wantTail) {
		t.Fatalf("configured tail = %#v; want %#v", values[dashboardHashrateDropThreshold:], wantTail)
	}
}

func TestDeriveDashboardJQFalseAndNullSemantics(t *testing.T) {
	raw := []byte(`{
		"xvb":{"enabled":null,"tor":false,"url":false,"donor_id":false,"donation_level":false},
		"dashboard":{"tari_required":null,"fail_closed":false,"check_for_updates":false,"hashrate_drop_threshold":false,"hashrate_drop_minutes":null},
		"workers":{"api_port":false,"api_auth":false,"api_token":false,"list":false},
		"telegram":{"enabled":null,"bot_token":false,"chat_id":null,"commands":{"enabled":null},"events":{"node_down":null},"daily_summary_time":false},
		"notifications":{"webhooks":false,"ntfy":{"url":false,"token":null},"tor":null}
	}`)
	plan, err := DeriveDashboard(raw, dashboardTestDefaults, DashboardInput{TariMode: "local", MoneroWallet: "wallet"})
	if err != nil {
		t.Fatal(err)
	}
	values := plan.Values()
	checks := map[int]string{
		dashboardXVBEnabled: "true", dashboardXVBTor: "false", dashboardXVBURL: "na.xmrvsbeast.com:4247",
		dashboardXVBDonor: "wallet", dashboardXVBDonationLevel: "auto", dashboardTariRequired: "true",
		dashboardFailClosed: "false", dashboardCheckForUpdates: "false", dashboardWorkerAPIPort: "8080",
		dashboardWorkerAPIAuth: "none", dashboardWorkerAPIToken: "", dashboardWorkerAPITokensJSON: "{}",
		dashboardTGEnabled: "false", dashboardTGToken: "", dashboardTGChat: "", dashboardTGCommands: "false",
		dashboardEventStart: "true", dashboardHashrateDropThreshold: "50", dashboardHashrateDropMinutes: "10",
		dashboardTGSummaryTime: "08:00", dashboardNotifyWebhooks: "", dashboardNTFYURL: "",
		dashboardNTFYToken: "", dashboardNotifyTor: "true",
	}
	for index, want := range checks {
		if values[index] != want {
			t.Errorf("value %d = %q; want %q", index, values[index], want)
		}
	}
}

func TestDeriveDashboardRejectsUnsupportedWithoutExposingInput(t *testing.T) {
	secret := "operator-secret"
	tests := map[string]struct {
		raw    string
		table  []byte
		wallet string
	}{
		"invalid JSON":              {raw: `{`, table: dashboardTestDefaults},
		"duplicate":                 {raw: `{"telegram":{},"telegram":{}}`, table: dashboardTestDefaults},
		"invalid defaults":          {raw: `{}`, table: []byte(`{}`)},
		"scalar parent":             {raw: `{"telegram":4}`, table: dashboardTestDefaults},
		"non-ASCII fallback wallet": {raw: `{}`, table: dashboardTestDefaults, wallet: "wállét"},
		"unsafe number":             {raw: `{"dashboard":{"hashrate_drop_threshold":9007199254740992}}`, table: dashboardTestDefaults},
		"worker name type":          {raw: `{"workers":{"list":[{"name":2,"host":"h","api_token":"` + secret + `"}]}}`, table: dashboardTestDefaults},
		"webhook object":            {raw: `{"notifications":{"webhooks":[{"token":"` + secret + `"}]}}`, table: dashboardTestDefaults},
		"control string":            {raw: `{"telegram":{"bot_token":"` + secret + `\n"}}`, table: dashboardTestDefaults},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			plan, err := DeriveDashboard([]byte(test.raw), test.table, DashboardInput{TariMode: "local", MoneroWallet: test.wallet})
			if plan != (DashboardPlan{}) || !errors.Is(err, ErrUnsupportedDashboard) {
				t.Fatalf("DeriveDashboard() = %#v, %v; want zero, unsupported", plan, err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Fatalf("error exposes input: %q", err)
			}
		})
	}
}
