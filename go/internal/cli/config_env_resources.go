package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configEnvResources(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 3 || !bytes.Equal(fields[1], []byte("0")) || len(fields[2]) != 0 {
		return unsupported
	}
	var value string
	switch args[0] {
	case "threads":
		value, err = config.PrepThreads(string(fields[0]))
	case "peers":
		var valid bool
		valid, err = config.OutPeersValid(string(fields[0]))
		value = strconv.FormatBool(valid)
	default:
		return unsupported
	}
	if err != nil {
		return unsupported
	}
	result := append([]byte(value), 0)
	written, err := output.Write(result)
	if err != nil || written != len(result) {
		return unsupported
	}
	return nil
}
