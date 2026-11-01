package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestConfigEnvRead(t *testing.T) {
	for _, test := range []struct{ op, input, want string }{
		{"decode", `"one\ntwo"` + "\x00DATA_DIR\x000\x00", "one\ntwo\x00Directory values in .env must not contain CR or LF.\x000\x00"},
		{"get", "A=first\nA=second\x000\x00A\x00", "first\x00\x000\x00"},
		{"get", "A=first\x000\x00MISSING\x00", "\x00\x000\x00"},
	} {
		var output bytes.Buffer
		if err := configEnvRead([]string{test.op}, strings.NewReader(test.input), &output); err != nil || output.String() != test.want {
			t.Fatalf("%s: error %v, output %q; want %q", test.op, err, output.String(), test.want)
		}
	}
}

func TestConfigEnvReadRefusals(t *testing.T) {
	valid := "value\x00KEY\x000\x00"
	for _, test := range []struct{ op, input string }{
		{"unknown", valid},
		{"decode", strings.TrimSuffix(valid, "\x00")},
		{"decode", valid + "extra"},
		{"decode", strings.Replace(valid, "\x000\x00", "\x001\x00", 1)},
		{"get", "A=one\x000\x00A.*\x00"},
		{"get", "A=one\x00B=two\x000\x00A\x00"},
	} {
		var output bytes.Buffer
		if status := exitStatus(configEnvRead([]string{test.op}, strings.NewReader(test.input), &output)); status != 125 || output.Len() != 0 {
			t.Fatalf("%s: status %d output %q", test.op, status, output.String())
		}
	}
	var output bytes.Buffer
	if status := exitStatus(configEnvRead([]string{"decode"}, failedDashboardReader{}, &output)); status != 125 || output.Len() != 0 {
		t.Fatal("read failure did not defer")
	}
	if status := exitStatus(configEnvRead([]string{"decode"}, strings.NewReader(valid), shortMaskedWriter{})); status != 125 {
		t.Fatal("short write did not defer")
	}
}
