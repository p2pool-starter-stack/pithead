package nodeprobe

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestClassifyMoneroRPC(t *testing.T) {
	valid := `{"status":"OK","nettype":"mainnet","height":0,"target_height":9007199254740991}`
	tests := []struct {
		name        string
		output      string
		exitCode    int
		want        string
		unsupported bool
	}{
		{"valid", valid + "\n200\n\n", 0, "ok", false},
		{"testnet", strings.Replace(valid, "mainnet", "testnet", 1) + "\n200", 0, "ok", false},
		{"stagenet", strings.Replace(valid, "mainnet", "stagenet", 1) + "\n200", 0, "ok", false},
		{"auth", "ignored\n401", 0, "auth", false},
		{"forbidden", "ignored\n403", 0, "auth", false},
		{"other http", "ignored\n500", 0, "protocol", false},
		{"no separator", "200", 0, "protocol", false},
		{"empty body", "\n200", 0, "protocol", false},
		{"wrong status", strings.Replace(valid, `"OK"`, `"BUSY"`, 1) + "\n200", 0, "protocol", false},
		{"wrong nettype", strings.Replace(valid, "mainnet", "fake", 1) + "\n200", 0, "protocol", false},
		{"missing height", `{"status":"OK","nettype":"mainnet","target_height":1}` + "\n200", 0, "protocol", false},
		{"string height", `{"status":"OK","nettype":"mainnet","height":"1","target_height":1}` + "\n200", 0, "protocol", false},
		{"negative height", `{"status":"OK","nettype":"mainnet","height":-1,"target_height":1}` + "\n200", 0, "protocol", false},
		{"fraction", `{"status":"OK","nettype":"mainnet","height":1.0,"target_height":1}` + "\n200", 0, "", true},
		{"exponent", `{"status":"OK","nettype":"mainnet","height":1e2,"target_height":1}` + "\n200", 0, "", true},
		{"negative zero", `{"status":"OK","nettype":"mainnet","height":-0,"target_height":1}` + "\n200", 0, "", true},
		{"large height", `{"status":"OK","nettype":"mainnet","height":9007199254740992,"target_height":1}` + "\n200", 0, "", true},
		{"malformed", "{\n200", 0, "", true},
		{"extra document", valid + ` {}` + "\n200", 0, "", true},
		{"unicode escape", strings.Replace(valid, `"OK"`, `"\u004fK"`, 1) + "\n200", 0, "", true},
		{"null byte", "bad\x00\n500", 0, "", true},
		{"null byte before exit", "bad\x00", 7, "", true},
		{"invalid utf8 transport", string([]byte{0xff}), 7, "refused", false},
		{"invalid utf8 auth", string([]byte{0xff, '\n'}) + "401", 0, "auth", false},
		{"invalid utf8 body", string([]byte{0xff, '\n'}) + "200", 0, "", true},
		{"refused", "partial\n200", 7, "refused", false},
		{"curl timeout", "partial\n200", 28, "timeout", false},
		{"outer timeout", "partial\n200", 124, "timeout", false},
		{"unusable", "partial\n200", 63, "unusable", false},
		{"missing tool", "", 127, "missing-tool", false},
		{"other failure", "partial\n200", 9, "unknown", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ClassifyMoneroRPC(test.output, test.exitCode)
			if test.unsupported {
				if got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
					t.Fatalf("got %q, %v", got, err)
				}
				return
			}
			if err != nil || got != test.want {
				t.Fatalf("got %q, %v; want %q", got, err, test.want)
			}
		})
	}
}

func TestMoneroRPCCheck(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixtures require POSIX")
	}
	dir := t.TempDir()
	trace := filepath.Join(dir, "trace")
	stdin := filepath.Join(dir, "stdin")
	writeExecutable(t, dir, "timeout", `#!/bin/sh
printf '%s\n' "$@" >"$PROBE_TRACE"
shift
exec "$@"
`)
	writeExecutable(t, dir, "curl", `#!/bin/sh
/bin/cat >"$PROBE_STDIN"
printf '%s' "$PROBE_OUTPUT"
exit "${PROBE_EXIT:-0}"
`)
	t.Setenv("PATH", dir)
	t.Setenv("PROBE_TRACE", trace)
	t.Setenv("PROBE_STDIN", stdin)
	t.Setenv("PROBE_OUTPUT", `{"status":"OK","nettype":"mainnet","height":10,"target_height":11}`+"\n200\n")
	rpc := MoneroRPC{Host: "2001:db8::1", Port: "18081", User: "fixture\n", Password: "secret\n", MaxFileSize: "17"}
	got, err := rpc.Check()
	if err != nil || got != "ok" {
		t.Fatalf("got %q, %v", got, err)
	}
	args, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	wantArgs := "6\ncurl\n-sS\n--noproxy\n*\n--max-time\n5\n--max-filesize\n17\n--digest\n--config\n-\n-w\n\\n%{http_code}\nhttp://[2001:db8::1]:18081/get_info\n"
	if string(args) != wantArgs {
		t.Fatalf("unexpected command arguments")
	}
	config, err := os.ReadFile(stdin)
	if err != nil {
		t.Fatal(err)
	}
	if string(config) != `user = "fixture:secret"` {
		t.Fatalf("unexpected curl config")
	}
}

func TestMoneroRPCCheckAnonymousAndBracketedHost(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixtures require POSIX")
	}
	dir := t.TempDir()
	trace := filepath.Join(dir, "trace")
	stdin := filepath.Join(dir, "stdin")
	writeExecutable(t, dir, "timeout", `#!/bin/sh
printf '%s\n' "$@" >"$PROBE_TRACE"
shift
exec "$@"
`)
	writeExecutable(t, dir, "curl", `#!/bin/sh
/bin/cat >"$PROBE_STDIN"
printf '{"status":"OK","nettype":"mainnet","height":1,"target_height":2}\n200'
`)
	t.Setenv("PATH", dir)
	t.Setenv("PROBE_TRACE", trace)
	t.Setenv("PROBE_STDIN", stdin)
	got, err := (MoneroRPC{Host: "[::1]", Port: "18081"}).Check()
	if err != nil || got != "ok" {
		t.Fatalf("got %q, %v", got, err)
	}
	args, _ := os.ReadFile(trace)
	if strings.Contains(string(args), "--digest") || !strings.Contains(string(args), "--max-filesize\n1048576\n") || !strings.Contains(string(args), "http://[::1]:18081/get_info") {
		t.Fatalf("unexpected anonymous command arguments")
	}
	config, _ := os.ReadFile(stdin)
	if len(config) != 0 {
		t.Fatalf("anonymous config was not empty")
	}
}

func TestMoneroRPCCheckFailures(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixtures require POSIX")
	}
	t.Run("missing timeout", func(t *testing.T) {
		t.Setenv("PATH", t.TempDir())
		got, err := (MoneroRPC{}).Check()
		if err != nil || got != "missing-tool" {
			t.Fatalf("got %q, %v", got, err)
		}
	})
	t.Run("missing curl", func(t *testing.T) {
		dir := t.TempDir()
		writeExecutable(t, dir, "timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
		t.Setenv("PATH", dir)
		got, err := (MoneroRPC{}).Check()
		if err != nil || got != "missing-tool" {
			t.Fatalf("got %q, %v", got, err)
		}
	})
	for _, test := range []struct {
		name string
		mode os.FileMode
		body string
	}{
		{"permission", 0o600, "#!/bin/sh\nexit 0\n"},
		{"no shebang", 0o700, "exit 0\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "timeout"), []byte(test.body), test.mode); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir)
			got, err := (MoneroRPC{}).Check()
			if got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("got %q, %v", got, err)
			}
		})
	}
	t.Run("nul argument", func(t *testing.T) {
		got, err := (MoneroRPC{User: "bad\x00value"}).Check()
		if got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("got %q, %v", got, err)
		}
	})
	t.Run("invalid utf8 argument", func(t *testing.T) {
		got, err := (MoneroRPC{Host: string([]byte{0xff})}).Check()
		if got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("got %q, %v", got, err)
		}
	})
	t.Run("err dot", func(t *testing.T) {
		dir := t.TempDir()
		writeExecutable(t, dir, "timeout", "#!/bin/sh\nexit 0\n")
		old, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Chdir(dir); err != nil {
			t.Fatal(err)
		}
		defer func() {
			if err := os.Chdir(old); err != nil {
				t.Error(err)
			}
		}()
		t.Setenv("PATH", ".")
		got, err := (MoneroRPC{}).Check()
		if got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("got %q, %v", got, err)
		}
	})
}

func TestMoneroRPCCheckDiscardsPartialFailureOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixtures require POSIX")
	}
	dir := t.TempDir()
	writeExecutable(t, dir, "timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
	writeExecutable(t, dir, "curl", "#!/bin/sh\nprintf 'partial\\n200'\nexit 7\n")
	t.Setenv("PATH", dir)
	got, err := (MoneroRPC{}).Check()
	if err != nil || got != "refused" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestQuoteJQString(t *testing.T) {
	input := "\"\\\b\f\n\r\t\x01\x7f café\u2028\u2029"
	want := `"\"\\\b\f\n\r\t\u0001\u007f café  "`
	if got := quoteJQString(input); got != want {
		t.Fatalf("got %q; want %q", got, want)
	}
}

func writeExecutable(t *testing.T, dir, name, body string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
}
