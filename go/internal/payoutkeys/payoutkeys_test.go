package payoutkeys

import (
	"strings"
	"sync"
	"testing"
)

func TestDerive(t *testing.T) {
	tests := []struct {
		chain, private, public string
	}{
		{"monero", "01" + strings.Repeat("00", 31), "5866666666666666666666666666666666666666666666666666666666666666"},
		{"tari", "01" + strings.Repeat("00", 31), "e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"},
		{"monero", "02" + strings.Repeat("00", 31), "c9a3f86aae465f0e56513864510f3997561fa2c9e85ea21dc2292309f3cd6022"},
		{"tari", "02" + strings.Repeat("00", 31), "6a493210f7499cd17fecb510ae0cea23a110e8d5b901f8acadd3095c73a3b919"},
	}
	for _, test := range tests {
		got, ok := Derive(test.chain, test.private)
		if !ok || got != test.public {
			t.Fatalf("Derive(%q, %q) = %q, %v; want %q, true", test.chain, test.private, got, ok, test.public)
		}
	}
}

func TestDeriveHexSyntax(t *testing.T) {
	private := " 01\n" + strings.Repeat("00\t", 31)
	got, ok := Derive("monero", strings.ToUpper(private))
	if !ok || got != "5866666666666666666666666666666666666666666666666666666666666666" {
		t.Fatalf("Derive spaced uppercase = %q, %v", got, ok)
	}
	for _, invalid := range []string{"", "0 1" + strings.Repeat("00", 31), "01" + strings.Repeat("00", 30), "gg" + strings.Repeat("00", 31), strings.Repeat("00", 32)} {
		if got, ok := Derive("monero", invalid); ok || got != "" {
			t.Fatalf("Derive invalid %q = %q, %v", invalid, got, ok)
		}
	}
}

func TestDeriveRejectsOrderAndChain(t *testing.T) {
	order := []byte{0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10}
	for _, test := range []struct{ chain, private string }{{"monero", stringHex(order)}, {"tari", stringHex(order)}, {"unknown", "01" + strings.Repeat("00", 31)}} {
		if got, ok := Derive(test.chain, test.private); ok || got != "" {
			t.Fatalf("Derive(%q, %q) = %q, %v", test.chain, test.private, got, ok)
		}
	}
}

func TestDeriveConcurrent(t *testing.T) {
	private := "02" + strings.Repeat("00", 31)
	wants := map[string]string{
		"monero": "c9a3f86aae465f0e56513864510f3997561fa2c9e85ea21dc2292309f3cd6022",
		"tari":   "6a493210f7499cd17fecb510ae0cea23a110e8d5b901f8acadd3095c73a3b919",
	}
	var group sync.WaitGroup
	for chain, want := range wants {
		for range 4 {
			group.Add(1)
			go func() {
				defer group.Done()
				got, ok := Derive(chain, private)
				if !ok || got != want {
					t.Errorf("Derive(%q) = %q, %v; want %q, true", chain, got, ok, want)
				}
			}()
		}
	}
	group.Wait()
}

func stringHex(value []byte) string {
	const digits = "0123456789abcdef"
	result := make([]byte, len(value)*2)
	for index, item := range value {
		result[index*2] = digits[item>>4]
		result[index*2+1] = digits[item&15]
	}
	return string(result)
}
