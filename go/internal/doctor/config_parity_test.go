//go:build parity

package doctor

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/address"
)

func TestConfigMoneroPublicVectors(t *testing.T) {
	vectors := configVectors(t)
	for _, key := range []string{"PRIMARY", "SUBADDR", "INTEGRATED"} {
		for _, keyOnly := range []bool{false, true} {
			t.Run(key+"/"+strconv.FormatBool(keyOnly), func(t *testing.T) {
				input, file := configFixture(t, true)
				input.Monero, input.MoneroKeyOnly = vectors[key], keyOnly
				compareConfigKind(t, input, file, "monero", address.Monero(input.Monero, true, keyOnly))
				for _, appliance := range []bool{false, true} {
					input.Appliance = appliance
					compareConfig(t, input, file)
				}
			})
		}
	}
}

func TestConfigMoneroCorruption(t *testing.T) {
	primary := configVectors(t)["PRIMARY"]
	values := []string{"", "1abc", "4" + strings.Repeat("a", 93), "4" + strings.Repeat("A", 94), "8" + strings.Repeat("A", 94),
		"4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBJG8KmJ",
		"4" + strings.Repeat("z", 94), "4" + strings.Repeat("1", 94), "your_monero_wallet_address", "invalid\n", " "}
	for _, index := range []int{1, 10, 11, 50, 94} {
		for _, ch := range []string{"0", "O", "I", "l", "B", "\n", "\r"} {
			values = append(values, primary[:index]+ch+primary[index+1:])
		}
	}
	for index, value := range values {
		t.Run(strconv.Itoa(index), func(t *testing.T) {
			input, file := configFixture(t, true)
			input.Monero = value
			compareConfigKind(t, input, file, "monero", address.Monero(value, true, false))
			for _, appliance := range []bool{false, true} {
				input.Appliance = appliance
				compareConfig(t, input, file)
			}
		})
	}
}

func TestConfigMoneroByteShape(t *testing.T) {
	for _, verify := range []bool{false, true} {
		t.Run(strconv.FormatBool(verify), func(t *testing.T) {
			input, file := configFixture(t, verify)
			for _, value := range []string{"4" + strings.Repeat("🐢", 94), "4🐢" + strings.Repeat("A", 90), "4\xff" + strings.Repeat("A", 93)} {
				input.Monero = value
				compareConfigKind(t, input, file, "monero", address.Monero(value, verify, false))
			}
		})
	}
}

func TestConfigTariPublicVectors(t *testing.T) {
	vectors := configVectors(t)
	for _, key := range []string{"TARI", "TARI_EMOJI", "TARI_SINGLE"} {
		for _, keyOnly := range []bool{false, true} {
			t.Run(key+"/"+strconv.FormatBool(keyOnly), func(t *testing.T) {
				input, file := configFixture(t, true)
				input.Tari, input.TariKeyOnly = vectors[key], keyOnly
				compareConfigKind(t, input, file, "tari", address.Tari(input.Tari, true, keyOnly))
				for _, appliance := range []bool{false, true} {
					input.Appliance = appliance
					compareConfig(t, input, file)
				}
			})
		}
	}
}

func TestConfigTariCorruption(t *testing.T) {
	vectors := configVectors(t)
	emoji := []rune(vectors["TARI_EMOJI"])
	values := []string{"", "T", "your_tari_wallet_address", vectors["TARI"][:90] + "B", string(emoji[:66]), string(emoji[:66]) + "🎅",
		string(emoji[:66]) + "🎒", vectors["TARI_EMOJI"] + "\ufe0f", vectors["TARI_SINGLE"] + "\n", "\xff",
		"f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb",
		"1A6J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Dr"}
	for _, index := range []int{0, 1, 2, 45, 90} {
		for _, ch := range []string{"0", "O", "I", "l", "B", "\n", " "} {
			values = append(values, vectors["TARI"][:index]+ch+vectors["TARI"][index+1:])
		}
	}
	for index, value := range values {
		t.Run(strconv.Itoa(index), func(t *testing.T) {
			input, file := configFixture(t, true)
			input.Tari = value
			compareConfigKind(t, input, file, "tari", address.Tari(value, true, false))
			for _, appliance := range []bool{false, true} {
				input.Appliance = appliance
				compareConfig(t, input, file)
			}
		})
	}
}

func TestConfigSSHRelease(t *testing.T) {
	for _, variant := range []string{"", "release", "debug", "RELEASE", "release\n\n", "release "} {
		for _, enabled := range []string{"", "false", "true", "true\n\n", "TRUE", "true "} {
			for _, appliance := range []bool{false, true} {
				t.Run(strconv.Quote(variant+enabled)+"/"+strconv.FormatBool(appliance), func(t *testing.T) {
					input, file := configFixture(t, true)
					input.Variant, input.SSHEnabled, input.Appliance = variant, enabled, appliance
					compareConfig(t, input, file)
				})
			}
		}
	}
}

func TestConfigVerificationUnavailable(t *testing.T) {
	for _, mode := range []string{"missing", "unusable"} {
		t.Run(mode, func(t *testing.T) {
			input, file := configFixture(t, false)
			if mode == "unusable" {
				writeHostTool(t, os.Getenv("PATH"), "python3", "exit 127\n")
			}
			for _, monero := range []string{"invalid", "4" + strings.Repeat("A", 94), "4" + strings.Repeat("A", 105), "8" + strings.Repeat("A", 94)} {
				input.Monero, input.Tari = monero, "invalid"
				compareConfigKind(t, input, file, "monero", address.Monero(monero, false, false))
				compareConfigKind(t, input, file, "tari", address.Tari(input.Tari, false, false))
				compareConfig(t, input, file)
			}
		})
	}
}

func TestConfigGetterTrimmingAndOrder(t *testing.T) {
	vectors := configVectors(t)
	for _, suffix := range []string{"", "\n", "\n\n", " \n", "\r\n"} {
		t.Run(strconv.Quote(suffix), func(t *testing.T) {
			input, file := configFixture(t, true)
			input.Appliance, input.Variant, input.SSHEnabled = true, "release\n", "true\n"
			input.Monero, input.Tari = vectors["PRIMARY"]+suffix, vectors["TARI"]+suffix
			compareConfig(t, input, file)
		})
	}
}

func TestConfigAbsent(t *testing.T) {
	input, file := configFixture(t, true)
	input.Present, input.Appliance, input.Variant, input.SSHEnabled = false, true, "release", "true"
	input.Monero, input.Tari = "invalid", "invalid"
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	compareConfig(t, input, file)
	compareConfig(t, input, filepath.Dir(file))
}
