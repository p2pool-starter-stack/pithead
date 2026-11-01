package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configWalletSettings(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
		return unsupported
	}
	settings, err := config.ParseWalletSettings(fields[0], string(fields[1]), string(fields[2]))
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range []string{strconv.Itoa(settings.Assigned), settings.MoneroWallet, settings.TariWallet, settings.Reason} {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
