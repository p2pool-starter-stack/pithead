package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configDirectories(args []string, input io.Reader, output io.Writer) error {
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
	plan, err := config.DeriveDirectories(fields[1], string(fields[0]))
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range plan.Values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
