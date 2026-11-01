package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/lifecycle"
)

func lifecycleOptions(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) < 4 || len(fields[len(fields)-1]) != 0 {
		return unsupported
	}
	count, err := strconv.Atoi(string(fields[1]))
	if err != nil || count < 0 || strconv.Itoa(count) != string(fields[1]) || len(fields) != count+4 || !bytes.Equal(fields[len(fields)-2], []byte("0")) {
		return unsupported
	}
	values := make([]string, count)
	for index := range values {
		values[index] = string(fields[index+2])
	}
	verdict, err := lifecycle.ParseOptions(string(fields[0]), values)
	if err != nil {
		return unsupported
	}
	result := []byte(verdict.Kind)
	result = append(result, 0)
	result = append(result, verdict.Argument...)
	result = append(result, 0)
	result = append(result, boolField(verdict.Options.Yes), 0)
	result = append(result, boolField(verdict.Options.DryRun), 0)
	result = append(result, boolField(verdict.Options.Porcelain), 0)
	written, err := output.Write(result)
	if err != nil || written != len(result) {
		return unsupported
	}
	return nil
}

func boolField(value bool) byte {
	if value {
		return '1'
	}
	return '0'
}
