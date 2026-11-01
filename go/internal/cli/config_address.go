package cli

import (
	"bytes"
	"io"
	"os"
	"unicode/utf8"

	"github.com/p2pool-starter-stack/pithead/go/internal/address"
)

func configAddress(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 4 || !bytes.Equal(fields[2], []byte("0")) || len(fields[3]) != 0 {
		return unsupported
	}

	var verdict string
	switch string(fields[0]) {
	case "monero":
		if os.Getenv("MONERO_ADDRESS_KEY_ONLY") == "1" || !configAddressASCII(fields[1]) {
			return unsupported
		}
		verdict = address.Monero(string(fields[1]), true, false)
	case "tari":
		if os.Getenv("TARI_ADDRESS_KEY_ONLY") == "1" || len(fields[1]) > 4096 || !utf8.Valid(fields[1]) {
			return unsupported
		}
		verdict = address.Tari(string(fields[1]), true, false)
	default:
		return unsupported
	}

	result := append([]byte(verdict), 0)
	written, err := output.Write(result)
	if err != nil || written != len(result) {
		return unsupported
	}
	return nil
}

func configAddressASCII(value []byte) bool {
	for _, current := range value {
		if current >= utf8.RuneSelf {
			return false
		}
	}
	return true
}
