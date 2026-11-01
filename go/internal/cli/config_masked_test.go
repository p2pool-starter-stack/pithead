package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestConfigMaskedProtocol(t *testing.T) {
	input := `{"secret":"value"}` + "\x00[[\"secret\"]]\x000\x00"
	var output bytes.Buffer
	if err := configMasked(nil, strings.NewReader(input), &output); err != nil || output.String() != "{\n  \"secret\": {\n    \"__secret__\": true\n  }\n}\n\x00" {
		t.Fatalf("configMasked() = %q, %v", output.String(), err)
	}
}

func TestConfigMaskedRefusals(t *testing.T) {
	good := `{}` + "\x00[]\x000\x00"
	for _, test := range []struct {
		name  string
		args  []string
		input string
	}{
		{"argument", []string{"extra"}, good},
		{"truncated", nil, strings.TrimSuffix(good, "\x00")},
		{"trailing", nil, good + "x"},
		{"producer", nil, strings.Replace(good, "\x000\x00", "\x001\x00", 1)},
		{"bad config", nil, `{` + "\x00[]\x000\x00"},
		{"bad paths", nil, `{}` + "\x00{}\x000\x00"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if status := exitStatus(configMasked(test.args, strings.NewReader(test.input), &output)); status != 125 || output.Len() != 0 {
				t.Fatalf("status %d output %q", status, output.String())
			}
		})
	}
	var output bytes.Buffer
	if status := exitStatus(configMasked(nil, failedDashboardReader{}, &output)); status != 125 || output.Len() != 0 {
		t.Fatal("read failure did not defer")
	}
	if status := exitStatus(configMasked(nil, strings.NewReader(good), failedDashboardWriter{})); status != 125 {
		t.Fatal("write failure did not defer")
	}
	if status := exitStatus(configMasked(nil, strings.NewReader(good), shortMaskedWriter{})); status != 125 {
		t.Fatal("short write did not defer")
	}
}

type shortMaskedWriter struct{}

func (shortMaskedWriter) Write(value []byte) (int, error) {
	return len(value) - 1, nil
}
