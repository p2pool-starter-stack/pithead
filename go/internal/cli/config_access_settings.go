package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configAccessSettings(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 || args[0] != "ssh" && args[0] != "node" {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var result bytes.Buffer
	if args[0] == "ssh" {
		if len(fields) != 6 || len(fields[5]) != 0 || !bytes.Equal(fields[4], []byte("0")) {
			return unsupported
		}
		if !bytes.Equal(fields[1], []byte("true")) && !bytes.Equal(fields[1], []byte("false")) {
			return unsupported
		}
		release := bytes.Equal(fields[1], []byte("true"))
		reason, err := config.ParseSSHSettings(fields[0], config.SSHSettingsInput{
			Release: release, ConfigSet: string(fields[2]), Carried: string(fields[3]),
		})
		if err != nil {
			return unsupported
		}
		result.WriteString(reason)
		result.WriteByte(0)
	} else {
		if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
			return unsupported
		}
		credentials, err := config.ParseNodeCredentials(fields[0], string(fields[1]), string(fields[2]))
		if err != nil {
			return unsupported
		}
		for _, value := range []string{
			credentials.User, credentials.Pass,
			strconv.FormatBool(credentials.GenerateUser), strconv.FormatBool(credentials.GeneratePass),
		} {
			result.WriteString(value)
			result.WriteByte(0)
		}
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
