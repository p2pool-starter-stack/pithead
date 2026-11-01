package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configPayoutSettings(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var values []string
	switch args[0] {
	case "monero":
		if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
			return unsupported
		}
		settings, parseErr := config.ParseMoneroPayoutSettings(fields[0], string(fields[1]))
		if parseErr != nil {
			return unsupported
		}
		values = []string{strconv.Itoa(settings.Assigned), settings.Mode, settings.ViewKey, settings.ScanHeight, settings.Enabled, settings.Reason}
	case "tari":
		if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
			return unsupported
		}
		settings, parseErr := config.ParseTariPayoutSettings(fields[0], string(fields[1]), string(fields[2]))
		if parseErr != nil {
			return unsupported
		}
		values = []string{settings.ViewKey, settings.SpendPublicKey, settings.Birthday, settings.Enabled, settings.Reason}
	case "birthday":
		if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
			return unsupported
		}
		reason, parseErr := config.ValidatePayoutBirthday(string(fields[0]), string(fields[1]))
		if parseErr != nil {
			return unsupported
		}
		values = []string{reason}
	default:
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
