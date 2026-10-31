package doctor

import (
	"errors"
	"reflect"
	"testing"
)

func TestLANPublished(t *testing.T) {
	got, err := LANPublished([]string{"0.0.0.0\n", "127.0.0.1\n", " \n", "ignored\x00"})
	want := []string{"MONERO_RPC_BIND:18081", "TARI_GRPC_BIND:18142"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("LANPublished() = %#v, %v", got, err)
	}
	for _, binds := range [][]string{nil, {""}, {"127.0.0.1", "\n", "127.0.0.1"}} {
		if got, err := LANPublished(binds); err != nil || got != nil {
			t.Fatalf("LANPublished(%q) = %#v, %v", binds, got, err)
		}
	}
	if got, err := LANPublished([]string{"\x00"}); got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("LANPublished(NUL) = %#v, %v", got, err)
	}
}

func TestLANSilentGates(t *testing.T) {
	t.Setenv("PATH", ".")
	if got, err := (LANGuard{}).Findings(); got != nil || err != nil {
		t.Fatalf("Findings(empty) = %#v, %v", got, err)
	}
	if got, err := (LANGuard{OS: "Darwin"}).Hold([]string{"\x00"}); got != nil || err != nil {
		t.Fatalf("Hold(non-Linux) = %#v, %v", got, err)
	}
	t.Setenv("PATH", t.TempDir())
	if got, err := LANBootApplies("Linux", false); got || err != nil {
		t.Fatalf("LANBootApplies(no systemctl) = %v, %v", got, err)
	}
}

func TestLANReasons(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	for _, engine := range []string{"docker", "podman"} {
		t.Setenv("PITHEAD_ENGINE", engine)
		got, err := LANReason("2")
		want := "the iptables command is not installed"
		if engine == "podman" {
			want = "the nft command is not installed"
		}
		if err != nil || got != want {
			t.Fatalf("LANReason(2) = %q, %v; want %q", got, err, want)
		}
	}
	got, err := LANReason("unknown\n")
	if err != nil || got != "the readback failed (rc unknown\n)" {
		t.Fatalf("LANReason(unknown) = %q, %v", got, err)
	}
}
