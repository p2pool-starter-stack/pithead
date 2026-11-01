package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configDashboardAccess(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
		return unsupported
	}
	settings, err := config.ParseDashboardAccess(fields[2], fields[1], config.DashboardAccessInput{Platform: string(fields[0])})
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	result.WriteString(strconv.Itoa(settings.Assigned))
	result.WriteByte(0)
	for _, value := range settings.Values {
		result.WriteString(value)
		result.WriteByte(0)
	}
	result.WriteString(strconv.FormatBool(settings.NeedsHostTimezone))
	result.WriteByte(0)
	result.WriteString(settings.Reason)
	result.WriteByte(0)
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
