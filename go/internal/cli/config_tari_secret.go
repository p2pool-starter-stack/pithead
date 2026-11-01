package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configTariSecret(args []string, input io.Reader) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 8 || len(fields[7]) != 0 || !bytes.Equal(fields[6], []byte("0")) {
		return unsupported
	}
	uid, err := parseTariSecretID(fields[1])
	if err != nil {
		return unsupported
	}
	gid, err := parseTariSecretID(fields[2])
	if err != nil {
		return unsupported
	}
	if err := config.PublishTariSecret(string(fields[0]), uid, gid, string(fields[3]), string(fields[4]), string(fields[5])); err != nil {
		return unsupported
	}
	return nil
}

func parseTariSecretID(raw []byte) (uint32, error) {
	value, err := strconv.ParseUint(string(raw), 10, 32)
	if err != nil || strconv.FormatUint(value, 10) != string(raw) {
		return 0, strconv.ErrSyntax
	}
	return uint32(value), nil
}
