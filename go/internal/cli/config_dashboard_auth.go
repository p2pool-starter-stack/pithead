package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configDashboardAuth(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var values []string
	switch args[0] {
	case "settings":
		if len(fields) != 3 || len(fields[2]) != 0 || !bytes.Equal(fields[1], []byte("0")) {
			return unsupported
		}
		settings, parseErr := config.ParseDashboardAuth(fields[0])
		if parseErr != nil {
			return unsupported
		}
		values = []string{settings.Username, settings.Password, settings.Reason}
	case "policy":
		if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
			return unsupported
		}
		settings, parseErr := config.ParseDashboardPolicy(fields[0], config.DashboardPolicyInput{
			Password: string(fields[1]), Program: string(fields[2]),
		})
		if parseErr != nil {
			return unsupported
		}
		values = []string{strconv.Itoa(settings.Assigned), settings.Values[0], settings.Values[1], settings.Values[2], settings.Reason}
	default:
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
