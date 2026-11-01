package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configSiteNames(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var value string
	switch args[0] {
	case "expand":
		if len(fields) < 7 || len(fields[len(fields)-1]) != 0 || !bytes.Equal(fields[len(fields)-2], []byte("0")) {
			return unsupported
		}
		count, ok := siteNameCount(fields[4], len(fields)-7)
		if !ok {
			return unsupported
		}
		candidates := siteNameFields(fields[5 : 5+count])
		value, err = config.ApplianceSiteNames(string(fields[0]), string(fields[1]), string(fields[2]), string(fields[3]), candidates)
		if err != nil {
			return unsupported
		}
	case "san":
		if len(fields) < 3 || len(fields[len(fields)-1]) != 0 || !bytes.Equal(fields[len(fields)-2], []byte("0")) {
			return unsupported
		}
		count, ok := siteNameCount(fields[0], len(fields)-3)
		if !ok {
			return unsupported
		}
		value = config.ApplianceCertAltString(siteNameFields(fields[1 : 1+count]))
	default:
		return unsupported
	}
	if _, err := output.Write(append([]byte(value), 0)); err != nil {
		return unsupported
	}
	return nil
}

func siteNameCount(field []byte, want int) (int, bool) {
	count, err := strconv.ParseUint(string(field), 10, 64)
	if err != nil || strconv.FormatUint(count, 10) != string(field) || count > uint64(want) {
		return 0, false
	}
	return int(count), int(count) == want
}

func siteNameFields(fields [][]byte) []string {
	values := make([]string, len(fields))
	for index := range fields {
		values[index] = string(fields[index])
	}
	return values
}
