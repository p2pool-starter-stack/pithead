package config

import (
	"encoding/base64"
	"errors"
	"testing"
)

func TestCaddyAuthBlock(t *testing.T) {
	for _, fixture := range []struct {
		name    string
		user    string
		hash    []byte
		encoded string
		want    string
		wantErr bool
	}{
		{name: "disabled"},
		{name: "bcrypt", user: "operator", hash: []byte("$2y$14$hash"), want: "    basic_auth {\n        operator $2y$14$hash\n    }"},
		{name: "trim-newlines", user: "admin", hash: []byte("hash\n\n"), want: "    basic_auth {\n        admin hash\n    }"},
		{name: "preserve-carriage-return", user: "admin", hash: []byte("hash\r"), want: "    basic_auth {\n        admin hash\r\n    }"},
		{name: "empty-decoded", user: "admin", encoded: "", want: ""},
		{name: "malformed", user: "admin", encoded: "%%%", wantErr: true},
		{name: "missing-padding", user: "admin", encoded: "aGFzaA", wantErr: true},
		{name: "noncanonical-whitespace", user: "admin", encoded: "aGFz\naA==", wantErr: true},
		{name: "nul", user: "admin", hash: []byte("hash\x00tail"), wantErr: true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			encoded := fixture.encoded
			if fixture.hash != nil {
				encoded = base64.StdEncoding.EncodeToString(fixture.hash)
			}
			got, err := CaddyAuthBlock(fixture.user, encoded)
			if fixture.wantErr {
				if !errors.Is(err, ErrUnsupportedCaddyAuth) || got != "" {
					t.Fatalf("got %q and %v", got, err)
				}
				return
			}
			if err != nil || got != fixture.want {
				t.Fatalf("got %q and %v; want %q", got, err, fixture.want)
			}
		})
	}
}

func TestCaddyBootCapability(t *testing.T) {
	for _, fixture := range []struct {
		encoded string
		want    string
	}{
		{"", "5229ffbc637198e7e78d0b123be0dfa8eb00ccf0e3d7e308b8a61ad155d74490"},
		{"YWJj", "08b3f0effcecf6797c13b64aeb65c40b624e28f22e25cc4a81b647f32ed13f8d"},
	} {
		if got := CaddyBootCapability(fixture.encoded); got != fixture.want {
			t.Fatalf("got %q; want %q", got, fixture.want)
		}
	}
}
