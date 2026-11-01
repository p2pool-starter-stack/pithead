package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestConfigWorkerReadProtocol(t *testing.T) {
	for _, test := range []struct {
		op, input, want string
	}{
		{"project", `{"workers":{"list":[]}}` + "\x000\x00", "\x00"},
		{"values", `{"name":"a","host":"h","token":"t","port":1}` + "\x000\x00", "a\x00h\x00t\x001\x00"},
		{"record", "a\x00h\x001\x00r\x000\x00", "{\n  \"name\": \"a\",\n  \"host\": \"h\",\n  \"port\": 1,\n  \"read_token\": \"r\"\n}\n\x00"},
		{"slurp", "\x000\x00", "[]\n\x00"},
	} {
		t.Run(test.op, func(t *testing.T) {
			var output bytes.Buffer
			if err := configWorkerRead([]string{test.op}, strings.NewReader(test.input), &output); err != nil || output.String() != test.want {
				t.Fatalf("configWorkerRead() = %q, %v", output.String(), err)
			}
		})
	}
}

func TestConfigWorkerReadRefusals(t *testing.T) {
	for _, test := range []struct {
		args  []string
		input string
	}{
		{nil, ""},
		{[]string{"bad"}, "\x000\x00"},
		{[]string{"project"}, `{}` + "\x001\x00"},
		{[]string{"project"}, `{}` + "\x000\x00x"},
		{[]string{"values"}, `{` + "\x000\x00"},
		{[]string{"record"}, "a\x00h\x000\x00r\x000\x00"},
		{[]string{"slurp"}, `{` + "\x000\x00"},
	} {
		var output bytes.Buffer
		if status := exitStatus(configWorkerRead(test.args, strings.NewReader(test.input), &output)); status != 125 || output.Len() != 0 {
			t.Fatalf("status %d output %q", status, output.String())
		}
	}
	var output bytes.Buffer
	if status := exitStatus(configWorkerRead([]string{"project"}, failedDashboardReader{}, &output)); status != 125 || output.Len() != 0 {
		t.Fatal("read failure did not defer")
	}
	if status := exitStatus(configWorkerRead([]string{"project"}, strings.NewReader(`{}`+"\x000\x00"), shortMaskedWriter{})); status != 125 {
		t.Fatal("short write did not defer")
	}
}
