package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLocalMinerHugePages(t *testing.T) {
	for _, test := range []struct {
		name, marker, enabled string
		appliance, warning    bool
	}{
		{"reduced", "pages=2048\n", "true", true, true},
		{"lower boundary", "pages=1\n", "true", true, true},
		{"upper boundary", "pages=3071\n", "true", true, true},
		{"released", "pages=0\n", "true", true, false},
		{"full", "pages=3072\n", "true", true, false},
		{"larger", "pages=4096\n", "true", true, false},
		{"malformed", "pages=-1\n", "true", true, false},
		{"leading zero", "pages=02560\n", "true", true, true},
		{"disabled", "pages=2048\n", "false", true, false},
		{"not boolean true", "pages=2048\n", "yes", true, false},
		{"lookup newline", "pages=2048\n", "true\n", true, true},
		{"DIY", "pages=2048\n", "true", false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "marker")
			if err := os.WriteFile(marker, []byte(test.marker), 0o600); err != nil {
				t.Fatal(err)
			}
			findings, err := (Memory{Marker: marker, Appliance: test.appliance}).LocalMiner(test.enabled)
			if err != nil || (len(findings) == 1) != test.warning {
				t.Fatalf("findings=%+v error=%v", findings, err)
			}
			if test.warning && (findings[0].ID != "local-miner-hugepages" || findings[0].Status != "warn") {
				t.Fatal(findings)
			}
		})
	}
}

func TestLocalMinerUnsupported(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "marker")
	if err := os.WriteFile(marker, []byte("pages=99999999999999999999999999\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ marker, enabled string }{
		{marker, "true"}, {marker, "true\x00"}, {"marker\x00", "true"},
	} {
		got, err := (Memory{Marker: test.marker, Appliance: true}).LocalMiner(test.enabled)
		if got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("unsupported = %+v, %v", got, err)
		}
	}
	if got, err := (Memory{Marker: marker, Appliance: true}).LocalMiner("false"); got != nil || err != nil {
		t.Fatalf("disabled = %+v, %v", got, err)
	}
	if err := os.WriteFile(marker, []byte("pages=25\x0060\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := (Memory{Marker: marker, Appliance: true}).LocalMiner("true"); got != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("NUL marker = %+v, %v", got, err)
	}
}
