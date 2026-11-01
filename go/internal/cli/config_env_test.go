package cli

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestConfigEnvProtocol(t *testing.T) {
	for _, fixture := range []struct {
		raw  string
		code int
		want string
	}{
		{"KEY\x00value\x00\x000\x00", 0, "KEY=value\n."},
		{"KEY\x00tail\n\n\x00\x000\x00", 0, "KEY=\"tail\\n\\n\"\n."},
		{"KEY\x00\x00\x000\x00", 0, "KEY=\n."},
		{"", 125, ""},
		{"KEY\x00value\x00", 125, ""},
		{"KEY\x00value\x00\x001\x00", 125, ""},
		{"KEY\x00value\x00\x000", 125, ""},
		{"KEY\x00first\x00KEY\x00second\x00\x000\x00", 125, ""},
		{"KEY\x00value\x00\x000\x00trailing", 125, ""},
	} {
		var output bytes.Buffer
		err := configEnv(nil, strings.NewReader(fixture.raw), &output)
		code := 0
		if err != nil {
			var status *ExitError
			if !errors.As(err, &status) {
				t.Fatal(err)
			}
			code = status.Code
		}
		if code != fixture.code || output.String() != fixture.want {
			t.Fatalf("got status %d and %q; want %d and %q", code, output.String(), fixture.code, fixture.want)
		}
	}
}
