package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/preview"
)

func configPreview(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var rendered []byte
	switch args[0] {
	case "describe":
		if !previewInput(fields, 6, 4) {
			return unsupported
		}
		result, ok := preview.Describe(string(fields[0]), string(fields[1]), string(fields[2]), string(fields[3]))
		if !ok {
			return unsupported
		}
		rendered = []byte(result.Flag + "\t" + result.Message)
	case "env-diff":
		if !previewInput(fields, 5, 1, 3) {
			return unsupported
		}
		var ok bool
		rendered, ok = preview.EnvChangedKeys(fields[0], fields[2])
		if !ok {
			return unsupported
		}
	default:
		return unsupported
	}
	rendered = append(rendered, 0)
	if written, err := output.Write(rendered); err != nil || written != len(rendered) {
		return unsupported
	}
	return nil
}

func previewInput(fields [][]byte, count int, statuses ...int) bool {
	if len(fields) != count || len(fields[count-1]) != 0 {
		return false
	}
	for _, index := range statuses {
		if !bytes.Equal(fields[index], []byte("0")) {
			return false
		}
	}
	return true
}
