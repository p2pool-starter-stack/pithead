package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func caddySitesTestFrame() string {
	return strings.Join([]string{
		"true", "443", "box", "3", "box", "[fd00::1]", "box",
		"127.0.0.1 ::1", "    basic_auth {\n        operator hash\n    }", "    tls internal",
		"capability", "172.28.0", "demo.onion", "0", "",
	}, "\x00")
}

func TestConfigCaddySitesMatchesLegacyFragments(t *testing.T) {
	legacy := strings.Join([]string{
		"true", "443", "box", "http://box, http://[fd00::1], http://box",
		"https://box, https://[fd00::1], https://box", "127.0.0.1 ::1",
		"    basic_auth {\n        operator hash\n    }", "    tls internal", "capability", "172.28.0", "demo.onion", "",
	}, "\x00")
	for _, section := range []string{"prefix", "main", "onion-http", "onion-https"} {
		t.Run(section, func(t *testing.T) {
			var baseline, selected bytes.Buffer
			if err := configCaddy([]string{section}, strings.NewReader(legacy), &baseline); err != nil {
				t.Fatal(err)
			}
			if err := configCaddy([]string{section, "sites-v1"}, strings.NewReader(caddySitesTestFrame()), &selected); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(selected.Bytes(), baseline.Bytes()) {
				t.Fatalf("site preparation differs:\n%s\nwant:\n%s", selected.Bytes(), baseline.Bytes())
			}
		})
	}
}

func TestConfigCaddySitesRejectsMalformedFrames(t *testing.T) {
	frame := caddySitesTestFrame()
	for _, fixture := range []struct {
		name string
		args []string
		raw  string
	}{
		{"empty", []string{"main", "sites-v1"}, ""},
		{"unknown-tag", []string{"main", "sites-v2"}, frame},
		{"extra-argument", []string{"main", "sites-v1", "extra"}, frame},
		{"unknown-section", []string{"other", "sites-v1"}, frame},
		{"missing-terminator", []string{"main", "sites-v1"}, strings.TrimSuffix(frame, "\x00")},
		{"failed-producer", []string{"main", "sites-v1"}, strings.TrimSuffix(frame, "0\x00") + "1\x00"},
		{"bad-status", []string{"main", "sites-v1"}, strings.TrimSuffix(frame, "0\x00") + "00\x00"},
		{"extra-field", []string{"main", "sites-v1"}, frame + "extra\x00"},
		{"negative-count", []string{"main", "sites-v1"}, strings.Replace(frame, "\x003\x00", "\x00-1\x00", 1)},
		{"wrong-count", []string{"main", "sites-v1"}, strings.Replace(frame, "\x003\x00", "\x004\x00", 1)},
		{"leading-zero-count", []string{"main", "sites-v1"}, strings.Replace(frame, "\x003\x00", "\x0003\x00", 1)},
		{"overflow-count", []string{"main", "sites-v1"}, strings.Replace(frame, "\x003\x00", "\x0099999999999999999999999999999\x00", 1)},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configCaddy(fixture.args, strings.NewReader(fixture.raw), &output)
			var status *ExitError
			if !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
				t.Fatalf("got %v and %q", err, output.Bytes())
			}
		})
	}
}

func TestConfigCaddySitesPreservesCommandSubstitutionTrimming(t *testing.T) {
	legacy := strings.Join([]string{
		"true", "8443\n\n", "box", "http://box:8443", "https://box:8443",
		"", "    basic_auth {}", "", "", "172.28.0", "demo.onion", "",
	}, "\x00")
	tagged := strings.Join([]string{
		"true", "8443\n\n", "box", "1", "box", "", "    basic_auth {}", "", "", "172.28.0", "demo.onion", "0", "",
	}, "\x00")
	for _, section := range []string{"prefix", "main", "onion-http", "onion-https"} {
		t.Run(section, func(t *testing.T) {
			var baseline, selected bytes.Buffer
			if err := configCaddy([]string{section}, strings.NewReader(legacy), &baseline); err != nil {
				t.Fatal(err)
			}
			if err := configCaddy([]string{section, "sites-v1"}, strings.NewReader(tagged), &selected); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(selected.Bytes(), baseline.Bytes()) {
				t.Fatalf("site preparation differs: %q; want %q", selected.Bytes(), baseline.Bytes())
			}
		})
	}
}

func TestConfigCaddySitesIOFailure(t *testing.T) {
	var status *ExitError
	err := configCaddySites("main", failedCaddySitesReader{}, io.Discard)
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
	err = configCaddySites("main", strings.NewReader(caddySitesTestFrame()), failedCaddySitesWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}

type failedCaddySitesReader struct{}

func (failedCaddySitesReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type failedCaddySitesWriter struct{}

func (failedCaddySitesWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
