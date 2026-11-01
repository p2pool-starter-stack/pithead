package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configCaddyBind(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) < 5 || len(fields[len(fields)-1]) != 0 || !bytes.Equal(fields[len(fields)-2], []byte("0")) {
		return unsupported
	}
	count, err := strconv.ParseUint(string(fields[2]), 10, 64)
	if err != nil || strconv.FormatUint(count, 10) != string(fields[2]) || count > uint64(len(fields)) || len(fields) != int(count)+5 {
		return unsupported
	}
	candidates := make([]string, int(count))
	for i := range candidates {
		candidates[i] = string(fields[i+3])
	}
	value := config.CaddyBindAddresses(string(fields[0]), string(fields[1]), candidates)
	if _, err := output.Write(append([]byte(value), 0)); err != nil {
		return unsupported
	}
	return nil
}
