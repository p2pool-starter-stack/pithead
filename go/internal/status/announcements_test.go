package status

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOnionStatus(t *testing.T) {
	dir := t.TempDir()
	r := runnerForTest(dir, &bytes.Buffer{})
	for _, tc := range []struct {
		name, env, want string
	}{
		{"off", "DASHBOARD_ONION_ENABLED=false\n", ""},
		{"placeholder", "DASHBOARD_ONION_ENABLED=true\nDASHBOARD_ONION_ADDRESS=placeholder\n", ""},
		{"login", "DASHBOARD_ONION_ENABLED=true\nDASHBOARD_ONION_ADDRESS=example.onion\n", "http://example.onion (login required)"},
		{"client auth", "DASHBOARD_ONION_ENABLED=true\nDASHBOARD_ONION_ADDRESS=example.onion\nDASHBOARD_ONION_CLIENT_AUTH=true\n", "http://example.onion (client-auth ON + login; get your client key with './pithead onion-client-key')"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(tc.env), 0600); err != nil {
				t.Fatal(err)
			}
			if got := r.onionStatus(); got != tc.want {
				t.Fatalf("onionStatus() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestAnnounceStratumAuth(t *testing.T) {
	dir := t.TempDir()
	var out bytes.Buffer
	r := runnerForTest(dir, &out)
	if err := os.WriteFile(filepath.Join(dir, ".env"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	r.announceStratumAuth()
	if got, want := out.String(), "[pithead] Stratum password: none set (any password is accepted)\n"; got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
	out.Reset()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("PROXY_STRATUM_PASSWORD=s3cret\n"), 0600); err != nil {
		t.Fatal(err)
	}
	r.announceStratumAuth()
	if got := out.String(); !strings.Contains(got, "[pithead] Stratum password: s3cret\n") || !strings.Contains(got, `every rig must connect with pass "s3cret"`) || !strings.Contains(got, docsURL+"/docs/workers.md#authentication.") {
		t.Fatalf("output = %q", got)
	}
}

func TestAnnounceStratumTLS(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "openssl", `#!/bin/sh
[ "$1" = x509 ] && [ "$2" = -in ] && [ "$3" = tls/cert.pem ] && [ "$4" = -noout ] && [ "$5" = -fingerprint ] && [ "$6" = -sha256 ] || exit 91
printf 'sha256 Fingerprint=AA:0b:CC=ignored\n'
`)
	if err := os.Mkdir(filepath.Join(dir, "tls"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tls", "cert.pem"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("PROXY_STRATUM_TLS=true\nPROXY_TLS_DIR=tls\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("STRATUM_TLS", "")
	t.Setenv("PROXY_TLS_DIR", "")
	var out bytes.Buffer
	runnerForTest(dir, &out).announceStratumTLS()
	want := "[pithead] Stratum TLS is ON: rigs may connect with TLS on the same stratum port (cleartext still accepted). Pin this fingerprint on each rig (pools[].tls-fingerprint): aa0bcc\n"
	if out.String() != want {
		t.Fatalf("output = %q, want %q", out.String(), want)
	}
}

func TestAnnounceStratumTLSFailuresAreSilent(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "openssl", "#!/bin/sh\nexit 1\n")
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("PROXY_STRATUM_TLS=true\nPROXY_TLS_DIR=missing\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("STRATUM_TLS", "")
	t.Setenv("PROXY_TLS_DIR", "")
	var out bytes.Buffer
	runnerForTest(dir, &out).announceStratumTLS()
	if out.Len() != 0 {
		t.Fatalf("output = %q, want empty", out.String())
	}
}
