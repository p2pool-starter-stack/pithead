package firewall

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestTorSyncIPs(t *testing.T) {
	dir := t.TempDir()
	state := TorSyncState{
		Prefix: "10.40.2\n\n", StateDir: dir + "\n", Monero: "true\n", Tari: "true",
		P2Pool: "true", XVBEnabled: "true", XVBTor: "false\n",
	}
	want := []string{"10.40.2.26", "10.40.2.27", "10.40.2.28", "10.40.2.29"}
	got, err := state.IPs()
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("IPs() = %v, %v; want %v", got, err, want)
	}

	if err := os.WriteFile(filepath.Join(dir, "monero.synced"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing", filepath.Join(dir, "tari.synced")); err != nil {
		t.Fatal(err)
	}
	want = []string{"10.40.2.28", "10.40.2.29"}
	got, err = state.IPs()
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("IPs() with markers = %v, %v; want %v", got, err, want)
	}
}

func TestTorSyncGatesAndDefaults(t *testing.T) {
	state := TorSyncState{
		StateDir: t.TempDir(), CloseChain: "monero", Monero: "bad\x00",
		Tari: "true", P2Pool: "true", XVBEnabled: "false", XVBTor: "bad\x00",
	}
	got, err := state.IPs()
	want := []string{"172.28.0.27", "172.28.0.28"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("IPs() = %v, %v; want %v", got, err, want)
	}

	state.CloseChain = "tari"
	state.Monero = "true"
	state.Tari = "bad\x00"
	got, err = state.IPs()
	want = []string{"172.28.0.26", "172.28.0.28"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("IPs() = %v, %v; want %v", got, err, want)
	}
}

func TestTorSyncUnsupportedInput(t *testing.T) {
	cases := []TorSyncState{
		{Prefix: "bad\x00", StateDir: t.TempDir()},
		{StateDir: "bad\x00"},
		{StateDir: t.TempDir(), CloseChain: "bad\x00"},
		{StateDir: t.TempDir(), Monero: "bad\x00"},
		{StateDir: t.TempDir(), P2Pool: "bad\x00"},
		{StateDir: t.TempDir(), XVBEnabled: "true", XVBTor: "bad\x00"},
		{StateDir: strings.Repeat("x", 4096), Monero: "true"},
	}
	for i, state := range cases {
		if _, err := state.IPs(); !errors.Is(err, ErrUnsupportedInput) {
			t.Errorf("case %d: error = %v", i, err)
		}
	}
}

func TestTorSyncMarkerPath(t *testing.T) {
	if got := syncMarker("", "monero.synced"); got != "/monero.synced" {
		t.Fatalf("syncMarker() = %q", got)
	}
}
