package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configComposeProject(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 6 || len(fields[5]) != 0 || !bytes.Equal(fields[4], []byte("0")) {
		return unsupported
	}
	overridePresent := bytes.Equal(fields[1], []byte("1"))
	if !overridePresent && !bytes.Equal(fields[1], []byte("0")) {
		return unsupported
	}
	if !overridePresent && len(fields[2]) != 0 {
		return unsupported
	}
	filePresent := bytes.Equal(fields[3], []byte("file"))
	if !filePresent && !bytes.Equal(fields[3], []byte("missing")) {
		return unsupported
	}
	if overridePresent && (filePresent || len(fields[0]) != 0) {
		return unsupported
	}
	if !overridePresent && !filePresent && len(fields[0]) != 0 {
		return unsupported
	}
	project, warning, valid := config.ComposeProjectName(fields[0], filePresent, overridePresent, string(fields[2]))
	verdict := "1"
	if valid {
		verdict = "0"
	}
	result := []byte(project + "\x00" + warning + "\x00" + verdict + "\x00")
	if written, err := output.Write(result); err != nil || written != len(result) {
		return unsupported
	}
	return nil
}
