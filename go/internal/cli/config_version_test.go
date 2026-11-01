package cli

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestConfigVersionScalarProtocol(t *testing.T) {
	for _, test := range []struct {
		args       []string
		want       string
		wantStatus int
	}{
		{[]string{"normalize", "2.1.0-beta"}, "2.1.0\x00", 0},
		{[]string{"normalize", "2.1"}, "", 1},
		{[]string{"normalize", "2.1.0\n"}, "", 125},
		{[]string{"ok", "0001.02.3"}, "", 0},
		{[]string{"ok", "1.2.12345"}, "", 1},
	} {
		var output bytes.Buffer
		err := configVersion(test.args, strings.NewReader(""), &output)
		if output.String() != test.want || exitStatus(err) != test.wantStatus {
			t.Fatalf("configVersion(%q) = %q, %v", test.args, output.String(), err)
		}
	}
	if status := exitStatus(configVersion([]string{"normalize", "2.1.0"}, strings.NewReader(""), failedDashboardWriter{})); status != 125 {
		t.Fatal("normalize write failure did not defer")
	}
}

func TestConfigVersionDocumentProtocol(t *testing.T) {
	frame := `{"first":1,"config_version":"2.0.0"}` + "\x002.1.0\x000\x00"
	for _, test := range []struct {
		op, want string
	}{
		{"plan", "2.0.0\x00false\x00false\x00false\x00"},
		{"json", "{\n  \"first\": 1,\n  \"config_version\": \"2.1.0\"\n}\n\x00"},
	} {
		var output bytes.Buffer
		if err := configVersion([]string{test.op}, strings.NewReader(frame), &output); err != nil || output.String() != test.want {
			t.Fatalf("configVersion(%q) = %q, %v", test.op, output.String(), err)
		}
	}
}

func TestConfigVersionProtocolRefusals(t *testing.T) {
	good := `{}` + "\x002.1.0\x000\x00"
	for _, test := range []struct {
		name  string
		args  []string
		input string
	}{
		{"missing op", nil, ""},
		{"unknown op", []string{"other"}, ""},
		{"extra normalize arg", []string{"normalize", "2.1.0", "x"}, ""},
		{"truncated", []string{"plan"}, strings.TrimSuffix(good, "\x00")},
		{"trailing", []string{"json"}, good + "x"},
		{"producer", []string{"plan"}, strings.Replace(good, "\x000\x00", "\x001\x00", 1)},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if status := exitStatus(configVersion(test.args, strings.NewReader(test.input), &output)); status != 125 || output.Len() != 0 {
				t.Fatalf("status %d output %q", status, output.String())
			}
		})
	}
	var output bytes.Buffer
	if status := exitStatus(configVersion([]string{"plan"}, failedDashboardReader{}, &output)); status != 125 || output.Len() != 0 {
		t.Fatal("read failure did not defer")
	}
	if status := exitStatus(configVersion([]string{"json"}, strings.NewReader(good), failedDashboardWriter{})); status != 125 {
		t.Fatal("write failure did not defer")
	}
}

func exitStatus(err error) int {
	if err == nil {
		return 0
	}
	var status *ExitError
	if errors.As(err, &status) {
		return status.Code
	}
	return -1
}
