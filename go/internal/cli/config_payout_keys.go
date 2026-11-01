package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/payoutkeys"
)

func configPayoutKeys(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
		return unsupported
	}
	derived, valid := payoutkeys.Derive(string(fields[0]), string(fields[1]))
	verdict := "1"
	if valid {
		verdict = "0"
	}
	result := []byte(verdict + "\x00" + derived + "\x00")
	if written, err := output.Write(result); err != nil || written != len(result) {
		return unsupported
	}
	return nil
}
