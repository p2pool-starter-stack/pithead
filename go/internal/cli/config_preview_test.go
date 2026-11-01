package cli

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestConfigPreview(t *testing.T) {
	tests := []struct {
		name, op, input, want string
	}{
		{"describe", "describe", "MONERO_PRUNE\x001\x000\x00\x000\x00", "DEST\tMonero pruning DISABLED (1 → 0) — pruned data can't be restored, so the full chain must RE-SYNC from scratch.\x00"},
		{"env-diff", "env-diff", "A=1\nB=2\n\x000\x00A=1\nB=3\n\x000\x00", "B\n\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if err := configPreview([]string{test.op}, strings.NewReader(test.input), &output); err != nil || output.String() != test.want {
				t.Fatalf("error %v, output %q", err, output.String())
			}
		})
	}
}

func TestConfigPreviewRejectsUnsupportedAndMalformedInput(t *testing.T) {
	tests := []struct {
		op, input string
	}{
		{"describe", "TARI_MODE\x00off\x00local\x00\x000\x00"},
		{"describe", "MONERO_PRUNE\x001\x000\x00\x001\x00"},
		{"describe", "MONERO_PRUNE\x001\x000\x00\x000\x00extra"},
		{"env-diff", "A=1\x001\x00B=2\x000\x00"},
		{"env-diff", "A=1\x000\x00B=2\x000\x00extra"},
	}
	for _, test := range tests {
		var output bytes.Buffer
		err := configPreview([]string{test.op}, strings.NewReader(test.input), &output)
		var status *ExitError
		if !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
			t.Fatalf("%s: error %v, output %q", test.op, err, output.String())
		}
	}
}

func TestConfigPreviewIOFailures(t *testing.T) {
	var output bytes.Buffer
	err := configPreview([]string{"describe"}, failedDashboardReader{}, &output)
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
		t.Fatalf("read error %v, output %q", err, output.String())
	}
	err = configPreview([]string{"describe"}, strings.NewReader("MONERO_PRUNE\x001\x000\x00\x000\x00"), failedDashboardWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("write error %v", err)
	}
}
