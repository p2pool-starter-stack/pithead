package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configWorkerRead(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var rendered [][]byte
	switch args[0] {
	case "project":
		if !workerReadInput(fields, 3) {
			return unsupported
		}
		value, renderErr := config.ProjectWorkerRead(fields[0])
		err, rendered = renderErr, [][]byte{value}
	case "values":
		if !workerReadInput(fields, 3) {
			return unsupported
		}
		rendered, err = config.WorkerReadValues(fields[0])
	case "record":
		if !workerReadInput(fields, 6) {
			return unsupported
		}
		value, renderErr := config.WorkerReadRecord(string(fields[0]), string(fields[1]), string(fields[2]), string(fields[3]))
		err, rendered = renderErr, [][]byte{value}
	case "slurp":
		if !workerReadInput(fields, 3) {
			return unsupported
		}
		value, renderErr := config.SlurpWorkerRead(fields[0])
		err, rendered = renderErr, [][]byte{value}
	default:
		return unsupported
	}
	if err != nil {
		return unsupported
	}
	var framed bytes.Buffer
	for _, value := range rendered {
		framed.Write(value)
		framed.WriteByte(0)
	}
	if written, err := output.Write(framed.Bytes()); err != nil || written != framed.Len() {
		return unsupported
	}
	return nil
}

func workerReadInput(fields [][]byte, count int) bool {
	return len(fields) == count && len(fields[count-1]) == 0 && bytes.Equal(fields[count-2], []byte("0"))
}
