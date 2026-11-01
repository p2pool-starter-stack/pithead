package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestConfigDocumentFallbackEnv(t *testing.T) {
	env := []string{"PATH=/bin", "PITHEAD_IMPL=bash", "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=stale"}
	want := []string{"PATH=/bin", "PITHEAD_IMPL=bash", "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=current"}
	if got := configDocumentFallbackEnv(env, "current"); !reflect.DeepEqual(got, want) {
		t.Fatal("native gate selection was not replaced")
	}
	if env[2] != "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=stale" {
		t.Fatal("input environment was modified")
	}
}

func TestConfigDocumentHelper(t *testing.T) {
	t.Setenv("PITHEAD_GO_HELPER", "config-document")
	path := filepath.Join(t.TempDir(), "config.json")
	for _, test := range []struct {
		raw, mode, want string
		code            int
	}{
		{`{}`, "config", "", 0},
		{`{"a":1,"a":2}`, "config", "duplicate key \"a\" at the top level (path a)\n", 1},
		{`{"actor":"YOUR_actor","config":{}}`, "request", "", 0},
		{`{"secret":"YOUR_hidden"}`, "config", "placeholder value at secret\n", 1},
		{`{`, "config", "not valid JSON\n", 1},
		{`{"a":NaN}`, "config", "", 125},
	} {
		if err := os.WriteFile(path, []byte(test.raw), 0o600); err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		err := Run("unused", []string{path, test.mode}, &output)
		code := 0
		var status *ExitError
		if errors.As(err, &status) {
			code = status.Code
		} else if err != nil {
			t.Fatal(err)
		}
		if code != test.code || output.String() != test.want {
			t.Fatal("helper status or diagnostic bytes differ")
		}
	}
	var output bytes.Buffer
	var status *ExitError
	if err := Run("unused", nil, &output); !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
		t.Fatal("invalid helper invocation did not defer silently")
	}
}
