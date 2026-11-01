//go:build parity

package nodeprobe

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMoneroRPCParityTransport(t *testing.T) {
	for _, tool := range []string{"curl", "timeout"} {
		for _, code := range []string{"7", "28", "124", "63", "127", "1", "22", "126", "130"} {
			t.Run(tool+"/"+code, func(t *testing.T) {
				fixture := newRPCFixture(t)
				fixture.write(t, tool+".code", code)
				fixture.write(t, "curl.stderr", "synthetic transport diagnostic")
				compareRPC(t, fixture)
			})
		}
	}
	t.Run("discard-opaque-body", func(t *testing.T) {
		fixture := newRPCFixture(t)
		fixture.write(t, "curl.code", "7")
		fixture.write(t, "response.value", "\xff\n200")
		compareRPC(t, fixture)
	})
}

func TestMoneroRPCParityHTTP(t *testing.T) {
	for _, code := range []string{"200", "401", "403", "400", "404", "500", "000", "0200", "200\r", "", "200\n\n"} {
		t.Run(code, func(t *testing.T) {
			fixture := newRPCFixture(t)
			fixture.write(t, "response.value", `{"status":"OK","nettype":"mainnet","height":0,"target_height":0}`+"\n"+code)
			compareRPC(t, fixture)
		})
	}
}

func TestMoneroRPCParityJSON(t *testing.T) {
	for name, body := range map[string]string{
		"testnet":      `{"status":"OK","nettype":"testnet","height":0,"target_height":0}`,
		"stagenet":     `{"status":"OK","nettype":"stagenet","height":9007199254740991,"target_height":1}`,
		"status":       `{"status":"BUSY","nettype":"mainnet","height":10,"target_height":20}`,
		"network":      `{"status":"OK","nettype":"fakechain","height":10,"target_height":20}`,
		"negative":     `{"status":"OK","nettype":"mainnet","height":-1,"target_height":20}`,
		"string":       `{"status":"OK","nettype":"mainnet","height":"10","target_height":20}`,
		"missing":      `{"status":"OK","nettype":"mainnet","height":10}`,
		"boolean":      `{"status":"OK","nettype":"mainnet","height":true,"target_height":20}`,
		"extra-fields": `{"status":"OK","nettype":"mainnet","height":10,"target_height":20,"extra":[true,"fixture"]}`,
		"duplicate":    `{"status":"BAD","status":"OK","nettype":"mainnet","height":10,"target_height":20}`,
		"empty-object": `{}`, "array": `[]`, "null": `null`, "number": `200`, "scalar": `true`, "empty": "", "space": " \t\n",
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newRPCFixture(t)
			fixture.write(t, "response.value", body+"\n200\n\n")
			compareRPC(t, fixture)
		})
	}
}

func TestMoneroRPCParityArguments(t *testing.T) {
	for _, name := range []string{"ipv6", "bracketed", "bracketed-name", "zone", "empty-host", "raw-args", "auth", "password-only", "getter-lines", "quoted-auth", "unicode-auth", "cap", "zero-cap"} {
		t.Run(name, func(t *testing.T) {
			fixture := newRPCFixture(t)
			switch name {
			case "ipv6":
				fixture.Host = "2001:db8::1"
			case "bracketed":
				fixture.Host = "[2001:db8::1]"
			case "bracketed-name":
				fixture.Host = "[fixture]"
			case "zone":
				fixture.Host = "2001:db8::1%fixture"
			case "empty-host":
				fixture.Host = ""
			case "raw-args":
				fixture.Host, fixture.Port, fixture.MaxFileSize = "host\n", "18081\n", "4096\n"
			case "auth":
				fixture.User, fixture.Password = "fixture-user", "synthetic-placeholder"
			case "password-only":
				fixture.Password = "synthetic-placeholder"
			case "getter-lines":
				fixture.User, fixture.Password = "fixture-user\n\n", "synthetic-placeholder\n\n"
			case "quoted-auth":
				fixture.User, fixture.Password = "fixture'\"\\&<>", "synthetic\t\r\nplaceholder\b\f\x01\x7f"
			case "unicode-auth":
				fixture.User, fixture.Password = "fixture-猫\u2028", "synthetic-🐱\u2029"
			case "cap":
				fixture.MaxFileSize = "4096"
			case "zero-cap":
				fixture.MaxFileSize = "0"
			}
			compareRPC(t, fixture)
		})
	}
}

func TestMoneroRPCParityMissingTools(t *testing.T) {
	for _, tool := range []string{"curl", "timeout"} {
		t.Run(tool, func(t *testing.T) {
			fixture := newRPCFixture(t)
			if err := os.Remove(filepath.Join(fixture.dir, tool)); err != nil {
				t.Fatal(err)
			}
			compareRPC(t, fixture)
		})
	}
}

func TestMoneroRPCParityFraming(t *testing.T) {
	for name, response := range map[string]string{
		"empty": "", "code-only": "200", "code-lines": "200\n\n", "empty-json": "{}",
		"no-body": "\n200", "extra-code": "{}\n200\n401", "space": " \r\n200",
		"opaque-auth": "\xff\n403", "opaque-protocol": "\xff\n500",
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newRPCFixture(t)
			fixture.write(t, "response.value", response)
			compareRPC(t, fixture)
		})
	}
}
