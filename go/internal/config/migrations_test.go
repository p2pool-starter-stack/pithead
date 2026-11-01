package config

import (
	"errors"
	"strings"
	"testing"
)

var migrationKeys = []byte(`["enabled","url","donor_id"]`)
var migrationDefaults = []byte(`{"enabled":true,"url":"default.example:1","donor_id":"auto"}`)

func TestPlanLegacyWorkers(t *testing.T) {
	for _, test := range []struct {
		name, raw   string
		want        LegacyWorkersPlan
		unsupported bool
	}{
		{"none", `{}`, LegacyWorkersPlan{}, false},
		{"empty names", `{"dashboard":{"workers":[]},"xmrig_proxy":{}}`, LegacyWorkersPlan{Need: true}, false},
		{"populated aliases", `{"dashboard":{"workers":[{"name":"a"}]},"xmrig_proxy":{"url":"custom"}}`, LegacyWorkersPlan{Need: true, Populated: true}, false},
		{"same object different order", `{"dashboard":{"workers":[{"a":1,"b":2}]},"workers":{"list":[{"b":2,"a":1}]}}`, LegacyWorkersPlan{Need: true, Populated: true}, false},
		{"stable conflicts", `{"dashboard":{"workers":[1]},"workers":{"list":[2]},"xmrig_proxy":{"enabled":false,"url":"old","donor_id":"old"},"xvb":{"enabled":true,"url":"new","donor_id":"new"}}`, LegacyWorkersPlan{Conflict: "workers.list[] and dashboard.workers[]; xvb.enabled and xmrig_proxy.enabled; xvb.url and xmrig_proxy.url; xvb.donor_id and xmrig_proxy.donor_id", Need: true, Populated: true}, false},
		{"v1 default no conflict", `{"xmrig_proxy":{"enabled":true,"url":"default.example:1","donor_id":"auto"},"xvb":{"enabled":false,"url":"new","donor_id":"new"}}`, LegacyWorkersPlan{Need: true}, false},
		{"null membership", `{"xmrig_proxy":{"url":null},"xvb":{}}`, LegacyWorkersPlan{Need: true, Populated: true}, false},
		{"float fallback", `{"unrelated":1.5}`, LegacyWorkersPlan{}, true},
		{"duplicate fallback", `{"xvb":{},"xvb":{}}`, LegacyWorkersPlan{}, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := PlanLegacyWorkers([]byte(test.raw), migrationKeys, migrationDefaults)
			if got != test.want || errors.Is(err, ErrUnsupportedMigration) != test.unsupported {
				t.Fatalf("PlanLegacyWorkers() = %#v, %v", got, err)
			}
		})
	}
}

func TestMigrateLegacyWorkers(t *testing.T) {
	raw := `{"first":1,"dashboard":{"title":"rig","workers":[{"name":"a"}]},"workers":{"api_port":19000},"xmrig_proxy":{"enabled":false,"url":"old","extra":"drop"},"xvb":{"url":"new"},"last":"é\u0001"}`
	want := "{\n  \"first\": 1,\n  \"dashboard\": {\n    \"title\": \"rig\"\n  },\n  \"workers\": {\n    \"api_port\": 19000,\n    \"list\": [\n      {\n        \"name\": \"a\"\n      }\n    ]\n  },\n  \"xvb\": {\n    \"url\": \"new\",\n    \"enabled\": false\n  },\n  \"last\": \"é\\u0001\"\n}\n"
	got, err := MigrateLegacyWorkers([]byte(raw), migrationKeys, migrationDefaults)
	if err != nil || string(got) != want {
		t.Fatalf("MigrateLegacyWorkers() = %q, %v", got, err)
	}
	if strings.Contains(string(got), "xmrig_proxy") || strings.Contains(string(got), `"workers": [`) {
		t.Fatal("removed aliases remain")
	}
}

func TestTelegramControlMigration(t *testing.T) {
	for _, test := range []struct {
		name, raw string
		plan      TelegramControlPlan
		want      string
	}{
		{"absent", `{"telegram":{"token":"x"}}`, TelegramControlPlan{}, "{\n  \"telegram\": {\n    \"token\": \"x\"\n  }\n}\n"},
		{"boolean enabled", `{"telegram":{"before":1,"control":{"enabled":true},"after":2}}`, TelegramControlPlan{Need: true, WarnEnabled: true}, "{\n  \"telegram\": {\n    \"before\": 1,\n    \"after\": 2\n  }\n}\n"},
		{"string enabled", `{"telegram":{"control":{"enabled":"true"}}}`, TelegramControlPlan{Need: true, WarnEnabled: true}, "{\n  \"telegram\": {}\n}\n"},
		{"newline enabled", `{"telegram":{"control":{"enabled":"true\n\n"}}}`, TelegramControlPlan{Need: true, WarnEnabled: true}, "{\n  \"telegram\": {}\n}\n"},
		{"false default", `{"telegram":{"control":{"enabled":false}}}`, TelegramControlPlan{Need: true}, "{\n  \"telegram\": {}\n}\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			plan, err := PlanTelegramControl([]byte(test.raw))
			if err != nil || plan != test.plan {
				t.Fatalf("PlanTelegramControl() = %#v, %v", plan, err)
			}
			got, err := MigrateTelegramControl([]byte(test.raw))
			if err != nil || string(got) != test.want {
				t.Fatalf("MigrateTelegramControl() = %q, %v", got, err)
			}
		})
	}
	if _, err := PlanTelegramControl([]byte(`{"telegram":{"control":{"enabled":"true\u0000"}}}`)); !errors.Is(err, ErrUnsupportedMigration) {
		t.Fatal("NUL-bearing enabled string did not defer")
	}
}
