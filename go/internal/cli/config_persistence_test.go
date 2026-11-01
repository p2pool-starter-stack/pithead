package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestConfigPersistenceProtocol(t *testing.T) {
	for _, test := range []struct {
		op, input, want string
	}{
		{"credentials", `{"monero":{}}` + "\x00user\x00pass\x000\x00", "{\n  \"monero\": {\n    \"node_username\": \"user\",\n    \"node_password\": \"pass\"\n  }\n}\n\x00"},
		{"appliance", `{}` + "\x00{\"tor\":{\"auto_heal\":true}}\x000\x00", "{\n  \"tor\": {\n    \"auto_heal\": true\n  }\n}\n\x00"},
	} {
		var output bytes.Buffer
		if err := configPersistence([]string{test.op}, strings.NewReader(test.input), &output); err != nil || output.String() != test.want {
			t.Fatalf("configPersistence(%s) = %q, %v", test.op, output.String(), err)
		}
	}
}

func TestConfigPersistenceRefusals(t *testing.T) {
	good := `{}` + "\x00u\x00p\x000\x00"
	for _, test := range []struct {
		name  string
		args  []string
		input string
	}{
		{"missing op", nil, ""},
		{"unknown op", []string{"other"}, good},
		{"truncated", []string{"credentials"}, strings.TrimSuffix(good, "\x00")},
		{"trailing", []string{"credentials"}, good + "x"},
		{"producer", []string{"credentials"}, strings.Replace(good, "\x000\x00", "\x001\x00", 1)},
		{"bad appliance", []string{"appliance"}, `{}` + "\x00{}\x000\x00x"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if status := exitStatus(configPersistence(test.args, strings.NewReader(test.input), &output)); status != 125 || output.Len() != 0 {
				t.Fatalf("status %d output %q", status, output.String())
			}
		})
	}
	var output bytes.Buffer
	if status := exitStatus(configPersistence([]string{"credentials"}, failedDashboardReader{}, &output)); status != 125 || output.Len() != 0 {
		t.Fatal("read failure did not defer")
	}
	if status := exitStatus(configPersistence([]string{"credentials"}, strings.NewReader(good), failedDashboardWriter{})); status != 125 {
		t.Fatal("write failure did not defer")
	}
}
