//go:build parity

package doctor

import (
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/address"
)

func TestConfigTariPayloadBounds(t *testing.T) {
	input, file := configFixture(t, true)
	for _, size := range []int{34, 35, 36, 66, 67, 68, 322, 323, 324} {
		compareConfigPayload(t, input, file, configPayload(size, 0, 7), true)
	}
}

func TestConfigTariNetworkFeaturesAndChecksumOrder(t *testing.T) {
	input, file := configFixture(t, true)
	for _, network := range []byte{0, 1, 2, 16, 36, 38, 3, 57, 128, 255} {
		for _, feature := range []byte{0, 1, 2, 4, 7, 8, 255} {
			raw := configPayload(67, network, feature)
			compareConfigPayload(t, input, file, raw, false)
			raw[len(raw)-1] ^= 1
			compareConfigPayload(t, input, file, raw, false)
		}
	}
}

func configPayload(size int, network, feature byte) []byte {
	raw := make([]byte, size)
	raw[0], raw[1] = network, feature
	for index := 2; index < size-1; index++ {
		raw[index] = byte(index - 2)
	}
	var checksum byte
	for _, value := range raw[:size-1] {
		checksum ^= value
		if checksum < 128 {
			checksum *= 2
		} else {
			checksum = checksum*2 ^ 27
		}
	}
	raw[size-1] = checksum
	return raw
}

func compareConfigPayload(t *testing.T, input ConfigDiagnostics, file string, raw []byte, bothForms bool) {
	t.Helper()
	source, err := os.ReadFile(filepath.Join(verificationRoot(t), "lib", "pithead", "25-address-types.sh"))
	if err != nil {
		t.Fatal(err)
	}
	_, tail, found := strings.Cut(string(source), "_EMOJI = (\n")
	if !found {
		t.Fatal("reference emoji alphabet missing")
	}
	alphabet, _, found := strings.Cut(tail, "\n)")
	if !found {
		t.Fatal("reference emoji alphabet end missing")
	}
	var runes []rune
	for _, line := range strings.Split(alphabet, "\n") {
		runes = append(runes, []rune(strings.Trim(strings.TrimSpace(line), `"`))...)
	}
	if len(runes) != 256 {
		t.Fatalf("reference emoji alphabet length %d", len(runes))
	}
	var emoji strings.Builder
	for _, value := range raw {
		emoji.WriteRune(runes[value])
	}
	values := []string{emoji.String()}
	if bothForms {
		const b58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
		n := new(big.Int).SetBytes(raw[2:])
		var encoded []byte
		for n.Sign() > 0 {
			var digit big.Int
			n.QuoRem(n, big.NewInt(58), &digit)
			encoded = append(encoded, b58[digit.Int64()])
		}
		for _, value := range raw[2:] {
			if value != 0 {
				break
			}
			encoded = append(encoded, '1')
		}
		for left, right := 0, len(encoded)-1; left < right; left, right = left+1, right-1 {
			encoded[left], encoded[right] = encoded[right], encoded[left]
		}
		values = append(values, string([]byte{b58[raw[0]], b58[raw[1]]})+string(encoded))
	}
	for _, value := range values {
		input.Tari = value
		for _, keyOnly := range []bool{false, true} {
			input.TariKeyOnly = keyOnly
			compareConfigKind(t, input, file, "tari", address.Tari(value, true, keyOnly))
		}
	}
}
