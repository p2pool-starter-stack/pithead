//go:build parity

package nodeprobe

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestZMQParityFallback(t *testing.T) {
	greeting := hex.EncodeToString(zmqParityGreeting())
	pub := zmqParityFrame(zmqParityProperty("Socket-Type", "PUB"))
	for _, test := range []struct {
		name       string
		operation  string
		value      string
		diagnostic bool
	}{
		{"greeting-major", "greeting", greeting[:20] + "gg" + greeting[22:], true},
		{"greeting-unchecked-ascii", "greeting", greeting[:2] + "x" + greeting[3:], false},
		{"greeting-unchecked-byte", "greeting", greeting[:2] + "\xff" + greeting[3:], false},
		{"ready-flags", "ready", "gg0000", true},
		{"ready-odd-flags", "ready", "gg000", true},
		{"ready-metadata", "classify", greeting + "\n" + pub[:16] + "gg" + pub[18:], true},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newZMQFixture(t)
			want := fixture.reference(t, test.operation, test.value, 0)
			if test.diagnostic && want.stderr == "" {
				t.Fatal("Bash did not expose the arithmetic diagnostic")
			}
			var err error
			switch test.operation {
			case "greeting":
				_, err = ZMQGreetingOK(test.value)
			case "ready":
				_, err = ZMQReadyIsPublisher(test.value)
			case "classify":
				_, err = ClassifyZMQPublisher(test.value, 0)
			}
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for a noncanonical ZMTP representation")
			}
		})
	}
}

func TestZMQParityNULDiagnostics(t *testing.T) {
	for _, code := range []int{0, 2, 124, 7} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			fixture := newZMQFixture(t)
			want := fixture.reference(t, "classify", "\x00reply", code)
			if !strings.Contains(want.stderr, "null byte") {
				t.Fatal("Bash did not expose the NUL diagnostic")
			}
			if _, err := ClassifyZMQPublisher("\x00reply", code); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback before transport classification")
			}
		})
	}
}

func TestZMQParityOpaqueFailures(t *testing.T) {
	for _, code := range []int{2, 124, 7, 127} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			compareZMQ(t, "classify", "\xff\nnot-hex", code)
		})
	}
}
