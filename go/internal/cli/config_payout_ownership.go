package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configPayoutOwnership(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 7 || len(fields[6]) != 0 || !bytes.Equal(fields[5], []byte("0")) {
		return unsupported
	}
	result, err := config.ValidatePayoutOwnership(config.PayoutOwnershipInput{
		Chain: string(fields[0]), AddressKeys: string(fields[1]), PrivateView: string(fields[2]),
		ExplicitSpend: string(fields[3]), DocsURL: string(fields[4]),
	})
	if err != nil {
		return unsupported
	}
	assigned := "0"
	if result.AssignSpend {
		assigned = "1"
	}
	response := []byte(assigned + "\x00" + result.Spend + "\x00" + result.Reason + "\x00")
	if written, err := output.Write(response); err != nil || written != len(response) {
		return unsupported
	}
	return nil
}
