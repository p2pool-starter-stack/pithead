package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

const (
	configAddressMonero = "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"
	configAddressTari   = "126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"
)

func TestConfigAddressProtocol(t *testing.T) {
	for _, test := range []struct {
		name  string
		frame string
		want  string
	}{
		{"monero", "monero\x00" + configAddressMonero + "\x000\x00", "primary\x00"},
		{"monero checksum", "monero\x00" + "4" + strings.Repeat("A", 94) + "\x000\x00", "checksum\x00"},
		{"tari", "tari\x00" + configAddressTari + "\x000\x00", "ok\x00"},
		{"tari invalid", "tari\x00T\x000\x00", "invalid\x00"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if err := configAddress(nil, strings.NewReader(test.frame), &output); err != nil || output.String() != test.want {
				t.Fatalf("got %v and %q; want %q", err, output.String(), test.want)
			}
		})
	}
}

func TestConfigAddressRefusals(t *testing.T) {
	valid := "monero\x00" + configAddressMonero + "\x000\x00"
	for _, frame := range []string{
		"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00",
		strings.Replace(valid, "\x000\x00", "\x001\x00", 1),
		"other\x00value\x000\x00", "monero\x00caf\u00e9\x000\x00",
		"tari\x00" + string([]byte{0xff}) + "\x000\x00",
		"tari\x00" + strings.Repeat("A", 4097) + "\x000\x00",
	} {
		assertConfigAddressRefusal(t, nil, frame)
	}
	assertConfigAddressRefusal(t, []string{"extra"}, valid)
	assertConfigAddressUnsupported(t, configAddress(nil, configAddressFailedReader{}, io.Discard))
	assertConfigAddressUnsupported(t, configAddress(nil, strings.NewReader(valid), configAddressFailedWriter{}))
	assertConfigAddressUnsupported(t, configAddress(nil, strings.NewReader(valid), configAddressShortWriter{}))

	t.Setenv("MONERO_ADDRESS_KEY_ONLY", "1")
	assertConfigAddressRefusal(t, nil, valid)
	t.Setenv("TARI_ADDRESS_KEY_ONLY", "1")
	assertConfigAddressRefusal(t, nil, "tari\x00"+configAddressTari+"\x000\x00")
}

func assertConfigAddressRefusal(t *testing.T, args []string, frame string) {
	t.Helper()
	var output bytes.Buffer
	assertConfigAddressUnsupported(t, configAddress(args, strings.NewReader(frame), &output))
	if output.Len() != 0 {
		t.Fatalf("unsupported input wrote %q", output.String())
	}
}

func assertConfigAddressUnsupported(t *testing.T, err error) {
	t.Helper()
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v; want exit 125", err)
	}
}

type configAddressFailedReader struct{}

func (configAddressFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type configAddressFailedWriter struct{}

func (configAddressFailedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type configAddressShortWriter struct{}

func (configAddressShortWriter) Write(value []byte) (int, error) { return len(value) - 1, nil }
