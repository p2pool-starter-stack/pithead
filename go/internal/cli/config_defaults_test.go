package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigDefaultsHelper(t *testing.T) {
	table := `{"values":{"a":"new","tari":{"clearnet_initial_sync":false},"monero":{"clearnet_initial_sync":false}},"appliance":{"a":"appliance"},"materialize":["a"],"LEGACY_ABSENT":[{"path":"a","value":"legacy"}]}`
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"a":"tail\n\n"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"default", "a", "new", "diy"}, "new\n"},
		{[]string{"default", "a", "legacy", "appliance"}, "legacy\n"},
		{[]string{"get", "a", path, "diy"}, "tail\n\n\n"},
	} {
		var output bytes.Buffer
		if err := configDefaults(test.args, strings.NewReader(table+"\n0"), &output); err != nil || output.String() != test.want {
			t.Fatal("helper output differs")
		}
	}
	for _, args := range [][]string{nil, {"unknown", "diy"}, {"get", "a", "-", "diy"}, {"default", "missing", "new", "diy"}} {
		var output bytes.Buffer
		var status *ExitError
		if err := configDefaults(args, strings.NewReader(table+"\n0"), &output); !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
			t.Fatal("unsupported helper invocation did not defer silently")
		}
	}
	for _, suffix := range []string{"", "\n17", "\n0\n"} {
		var output bytes.Buffer
		var status *ExitError
		if err := configDefaults([]string{"defaults", "new", "diy"}, strings.NewReader(table+suffix), &output); !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
			t.Fatal("failed or malformed table production emitted native output")
		}
	}
}
