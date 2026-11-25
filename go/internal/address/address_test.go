package address

import (
	"encoding/hex"
	"strings"
	"testing"
	"unicode/utf8"
)

const (
	validMoneroPrimary    = "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"
	validMoneroSubaddress = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
	validMoneroIntegrated = "4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijGDpDGTWtLM516v46mB"
	validTari             = "126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"
	validTariEmoji        = "🐢📟🍼🌈🍓🚓➕🎸🍆🍷🎣🍗📿😂🥊⏰🍯👾🤔👒🍾👀🍼🌊🎷📟😈🚨👙🍈🌈🛵🤢🍔🔋👙🚽🤑🎽🎓🎓🐀🐜🐴🥄🚿📷💰👶👍🎉🍄🎢🔌🐋🚰🚑💅👢🦂🐬🐋🍗🍸🎹🏀🍄"
	validTariSingle       = "1224yPceFvbksLKQ8JE6APDzVY2D6P3SpXwB5LLC3BH4F7oF"
)

func TestMonero(t *testing.T) {
	cases := []struct {
		name  string
		value string
		want  string
	}{
		{"primary", validMoneroPrimary, "primary"},
		{"subaddress", validMoneroSubaddress, "subaddress"},
		{"integrated", validMoneroIntegrated, "integrated"},
		{"short", "4" + strings.Repeat("a", 93), "invalid"},
		{"other prefix", "1abc", "invalid"},
		{"bad checksum", "4" + strings.Repeat("A", 94), "checksum"},
		{"bad subaddress checksum", "8" + strings.Repeat("A", 94), "checksum"},
		{"non base58", validMoneroPrimary[:50] + "0" + validMoneroPrimary[51:], "invalid"},
		{"wrong tag length", "4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBJG8KmJ", "invalid"},
		{"overflow", "4" + strings.Repeat("1", 10) + strings.Repeat("z", 11) + strings.Repeat("1", 73), "invalid"},
		{"invalid utf8", string([]byte{'4', 0xff}) + strings.Repeat("A", 93), "invalid"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Monero(tc.value, true, false); got != tc.want {
				t.Fatalf("Monero() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestMoneroShapeOnlyAndKey(t *testing.T) {
	if got := Monero("4"+strings.Repeat("A", 94), false, false); got != "primary" {
		t.Fatalf("shape-only Monero() = %q, want primary", got)
	}
	if got := Monero(validMoneroPrimary, true, true); got != "1e7f5d11ab6a2f499d2213a0195b670457d9d9637d48cbaf237760b10f0be45b" {
		t.Fatalf("key-only Monero() = %q", got)
	}
}

func TestMoneroByteShape(t *testing.T) {
	for _, test := range []struct {
		value, want string
	}{
		{"4" + strings.Repeat("🐢", 94), "invalid"},
		{"4🐢" + strings.Repeat("A", 90), "primary"},
		{"4\xff" + strings.Repeat("A", 93), "primary"},
	} {
		if got := Monero(test.value, false, false); got != test.want {
			t.Fatalf("Monero(%q, false, false) = %q; want %q", test.value, got, test.want)
		}
	}
}

func TestLegacyKeccak256(t *testing.T) {
	want, err := hex.DecodeString("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
	if err != nil {
		t.Fatal(err)
	}
	got := legacyKeccak256(nil)
	if string(got[:]) != string(want) {
		t.Fatalf("legacyKeccak256(nil) = %x", got)
	}
}

func TestTari(t *testing.T) {
	tari66 := "🍗🌊🦂🍎🐛🔱🍟🚦🦆👃🐛🎼🛵🔮💋👙💦🍷👠🦀🐺🍪🚀🎮🎩👅🐔🐉🍍🥑💔📌🚧🐊💄🎥🎓🚗🎳🐛🚿💉🌴🧢🐵🎩👾👽🎃🤡👍🔮👒👽🎵👀🚨😷🎒👂👶🍄🏰🚑🌸🍁"
	cases := []struct {
		name  string
		value string
		want  string
	}{
		{"dual base58", validTari, "ok"},
		{"dual emoji", validTariEmoji, "ok"},
		{"single", validTariSingle, "ok"},
		{"flipped base58", validTari[:90] + "B", "checksum"},
		{"bad emoji checksum", tari66 + "🎒", "checksum"},
		{"invalid emoji", tari66 + "🎅", "invalid"},
		{"short emoji", tari66, "invalid"},
		{"wrong network", "f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb", "network"},
		{"unknown feature", "1A6J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Dr", "invalid"},
		{"placeholder", "T", "invalid"},
		{"invalid utf8", string([]byte{0xff}), "invalid"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Tari(tc.value, true, false); got != tc.want {
				t.Fatalf("Tari() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestTariUncheckedAndKeys(t *testing.T) {
	if count := utf8.RuneCountInString(tariEmoji); count != 256 {
		t.Fatalf("Tari emoji alphabet has %d entries", count)
	}
	if got := Tari(validTari, false, false); got != "unchecked" {
		t.Fatalf("unchecked Tari() = %q", got)
	}
	if got := Tari(validTari, true, true); got != "003c0223f2be5917384926cbe1a3cd32a907963a933c035801e3f99d1902f3e924d09dfde45e45456b7a8935fecfc0ebea431548d105d2f098a488820526395a61" {
		t.Fatalf("dual key-only Tari() = %q", got)
	}
	if got := Tari(validTariEmoji, true, true); got != "003c0223f2be5917384926cbe1a3cd32a907963a933c035801e3f99d1902f3e924d09dfde45e45456b7a8935fecfc0ebea431548d105d2f098a488820526395a61" {
		t.Fatalf("emoji key-only Tari() = %q", got)
	}
	if got := Tari(validTariSingle, true, true); got != "00d09dfde45e45456b7a8935fecfc0ebea431548d105d2f098a488820526395a61" {
		t.Fatalf("single key-only Tari() = %q", got)
	}
}
