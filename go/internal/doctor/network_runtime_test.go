package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetworkStratumDefaultsAndPrecedence(t *testing.T) {
	for _, input := range []Stratum{
		{},
		{EnvPresent: true},
		{EnvPresent: true, EnvPort: "\n\n", EnvBind: "\n"},
		{EnvPort: "ignored\x00", EnvBind: "ignored\x00"},
	} {
		port, err := input.EffectivePort()
		bind, bindErr := input.EffectiveBind()
		if err != nil || bindErr != nil || port != "3333" || bind != "0.0.0.0" {
			t.Fatalf("effective(%#v) = %q, %q, %v, %v", input, port, bind, err, bindErr)
		}
	}
	input := Stratum{Port: "4444\n", Bind: "bind\n", EnvPresent: true, EnvPort: "ignored\x00", EnvBind: "ignored\x00"}
	port, err := input.EffectivePort()
	bind, bindErr := input.EffectiveBind()
	if err != nil || bindErr != nil || port != "4444\n" || bind != "bind\n" {
		t.Fatalf("explicit values = %q, %q, %v, %v", port, bind, err, bindErr)
	}
}

func TestNetworkContainerOutput(t *testing.T) {
	for _, test := range []struct {
		body    string
		running bool
		bad     bool
	}{
		{"printf 'cid\\n'; exit 1", true, false},
		{"printf '\\n\\n'; exit 0", false, false},
		{"printf ' \\n'; exit 127", true, false},
		{"printf 'cid\\0000'; exit 0", false, true},
	} {
		bin := t.TempDir()
		t.Setenv("PATH", bin)
		if err := os.WriteFile(filepath.Join(bin, "docker"), []byte("#!/bin/sh\n"+test.body+"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
		running, err := ContainerRunning("tor")
		if test.bad {
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("ContainerRunning() = %v, %v", running, err)
			}
		} else if err != nil || running != test.running {
			t.Fatalf("ContainerRunning() = %v, %v; want %v", running, err, test.running)
		}
	}
}

func TestNetworkUnsupportedTools(t *testing.T) {
	bin := t.TempDir()
	t.Setenv("PATH", bin)
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte("exit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := ContainerRunning("tor"); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("no shebang error = %v", err)
	}
	t.Setenv("PATH", "."+string(os.PathListSeparator)+bin)
	if _, err := ContainerRunning("tor"); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("relative path error = %v", err)
	}
}

func TestNetworkSkippedInputs(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	finding, err := (StratumListening{Stratum: Stratum{Port: "\x00"}}).Finding()
	if err != nil || finding.Status != "info" || !strings.Contains(finding.Message, "isn't running") {
		t.Fatalf("Listening() = %#v, %v", finding, err)
	}
	finding, err = (TorClearnetEgress{NetworkPrefix: "\x00"}).Finding()
	if err != nil || finding.Status != "info" || !strings.Contains(finding.Message, "isn't running") {
		t.Fatalf("Egress() = %#v, %v", finding, err)
	}
	for _, input := range []Stratum{{Port: "\x00"}, {EnvPresent: true, EnvPort: "\x00"}} {
		if _, err := input.EffectivePort(); !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("EffectivePort(%#v) error = %v", input, err)
		}
	}
}
