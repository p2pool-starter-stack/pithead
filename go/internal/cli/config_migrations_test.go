package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestConfigMigrationsProtocol(t *testing.T) {
	workers := `{"xmrig_proxy":{"url":"old"}}` + "\x00[\"url\"]\x00{\"url\":\"default\"}\x000\x00"
	telegram := `{"telegram":{"control":{"enabled":true}}}` + "\x000\x00"
	for _, test := range []struct {
		op, input, want string
	}{
		{"workers-plan", workers, "\x00true\x00true\x00"},
		{"workers-json", workers, "{\n  \"xvb\": {\n    \"url\": \"old\"\n  }\n}\n\x00"},
		{"telegram-plan", telegram, "true\x00true\x00"},
		{"telegram-json", telegram, "{\n  \"telegram\": {}\n}\n\x00"},
	} {
		var output bytes.Buffer
		if err := configMigrations([]string{test.op}, strings.NewReader(test.input), &output); err != nil || output.String() != test.want {
			t.Fatalf("configMigrations(%s) = %q, %v", test.op, output.String(), err)
		}
	}
}

func TestConfigMigrationsRefusals(t *testing.T) {
	workers := `{}` + "\x00[]\x00{}\x000\x00"
	for _, test := range []struct {
		name  string
		args  []string
		input string
	}{
		{"missing op", nil, ""},
		{"unknown op", []string{"other"}, workers},
		{"truncated", []string{"workers-plan"}, strings.TrimSuffix(workers, "\x00")},
		{"trailing", []string{"workers-json"}, workers + "x"},
		{"producer", []string{"workers-plan"}, strings.Replace(workers, "\x000\x00", "\x001\x00", 1)},
		{"bad telegram frame", []string{"telegram-plan"}, `{}` + "\x000\x00x"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if status := exitStatus(configMigrations(test.args, strings.NewReader(test.input), &output)); status != 125 || output.Len() != 0 {
				t.Fatalf("status %d output %q", status, output.String())
			}
		})
	}
	var output bytes.Buffer
	if status := exitStatus(configMigrations([]string{"workers-plan"}, failedDashboardReader{}, &output)); status != 125 || output.Len() != 0 {
		t.Fatal("read failure did not defer")
	}
	if status := exitStatus(configMigrations([]string{"workers-json"}, strings.NewReader(workers), failedDashboardWriter{})); status != 125 {
		t.Fatal("write failure did not defer")
	}
}
