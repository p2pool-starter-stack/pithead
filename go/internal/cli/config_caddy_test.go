package cli

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestConfigCaddyFraming(t *testing.T) {
	fields := []string{"false", "", "host", "http://host", "https://host", "", "", "", "", "", ""}
	for _, fixture := range []struct {
		args []string
		raw  string
		code int
		want string
	}{
		{[]string{"prefix"}, strings.Join(fields, "\x00") + "\x00", 0, "."},
		{nil, "", 125, ""},
		{[]string{"unknown"}, strings.Join(fields, "\x00") + "\x00", 125, ""},
		{[]string{"prefix"}, strings.Join(fields, "\x00"), 125, ""},
		{[]string{"prefix"}, strings.Join(fields, "\x00") + "\x00extra", 125, ""},
		{[]string{"onion-http"}, strings.Join(fields, "\x00") + "\x00", 125, ""},
	} {
		var output bytes.Buffer
		err := configCaddy(fixture.args, strings.NewReader(fixture.raw), &output)
		code := 0
		if err != nil {
			var status *ExitError
			if !errors.As(err, &status) {
				t.Fatal(err)
			}
			code = status.Code
		}
		if code != fixture.code || output.String() != fixture.want {
			t.Fatalf("args %q: got %d / %q, want %d / %q", fixture.args, code, output.String(), fixture.code, fixture.want)
		}
	}
}
