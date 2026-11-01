package cli

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestConfigTariSecretProtocol(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secret")
	uid := strconv.Itoa(os.Geteuid())
	gid := strconv.Itoa(os.Getegid())
	input := strings.Join([]string{path, uid, gid, "view", "spend", "password", "0", ""}, "\x00")
	if err := configTariSecret(nil, strings.NewReader(input)); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil || string(content) != "MINOTARI_WALLET_VIEW_PRIVATE_KEY=view\nMINOTARI_WALLET_SPEND_KEY=spend\nMINOTARI_WALLET_PASSWORD=password\n" {
		t.Fatalf("content = %q, %v", content, err)
	}
}

func TestConfigTariSecretRefusals(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "secret")
	uid := strconv.Itoa(os.Geteuid())
	gid := strconv.Itoa(os.Getegid())
	good := strings.Join([]string{path, uid, gid, "view", "spend", "password", "0", ""}, "\x00")
	otherUID := strconv.FormatUint(uint64(uint32(os.Geteuid())+1), 10)
	tests := []struct {
		name  string
		args  []string
		input string
	}{
		{"arguments", []string{"extra"}, good},
		{"empty", nil, ""},
		{"truncated", nil, strings.TrimSuffix(good, "\x00")},
		{"trailing", nil, good + "extra\x00"},
		{"producer", nil, strings.TrimSuffix(good, "0\x00") + "1\x00"},
		{"uid sign", nil, strings.Replace(good, "\x00"+uid+"\x00", "\x00+"+uid+"\x00", 1)},
		{"uid leading zero", nil, strings.Replace(good, "\x00"+uid+"\x00", "\x000"+uid+"\x00", 1)},
		{"uid overflow", nil, strings.Replace(good, "\x00"+uid+"\x00", "\x004294967296\x00", 1)},
		{"gid malformed", nil, strings.Replace(good, "\x00"+gid+"\x00view", "\x00x\x00view", 1)},
		{"foreign uid", nil, strings.Replace(good, "\x00"+uid+"\x00", "\x00"+otherUID+"\x00", 1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
				t.Fatal(err)
			}
			err := configTariSecret(test.args, strings.NewReader(test.input))
			var status *ExitError
			if !errors.As(err, &status) || status.Code != 125 {
				t.Fatalf("status = %v", err)
			}
			if content, err := os.ReadFile(path); err != nil || string(content) != "old" {
				t.Fatalf("destination = %q, %v", content, err)
			}
		})
	}
	var status *ExitError
	if err := configTariSecret(nil, tariSecretFailedReader{}); !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("read failure = %v", err)
	}
}

type tariSecretFailedReader struct{}

func (tariSecretFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
