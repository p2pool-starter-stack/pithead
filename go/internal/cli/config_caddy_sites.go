package cli

import (
	"bytes"
	"io"
	"strconv"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configCaddySites(section string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) < 12 || len(fields[len(fields)-1]) != 0 || !bytes.Equal(fields[len(fields)-2], []byte("0")) {
		return unsupported
	}
	count, err := strconv.Atoi(string(fields[3]))
	if err != nil || count != len(fields)-12 || strconv.Itoa(count) != string(fields[3]) {
		return unsupported
	}
	hosts := make([]string, count)
	for index := range hosts {
		hosts[index] = string(fields[4+index])
	}
	http, https := config.CaddySiteAddresses(string(fields[0]), string(fields[1]), hosts)
	start := 4 + count
	values := config.CaddyInput{
		Secure: string(fields[0]), HostPort: string(fields[1]), Host: string(fields[2]),
		HTTPAddresses: strings.TrimRight(http, "\n"), HTTPSAddresses: strings.TrimRight(https, "\n"),
		BindAddresses: string(fields[start]), Auth: string(fields[start+1]),
		TLSLine: string(fields[start+2]), BootCapability: string(fields[start+3]),
		NetworkPrefix: string(fields[start+4]), Onion: string(fields[start+5]),
	}
	rendered, err := config.RenderCaddyFragment(section, values)
	if err != nil {
		return unsupported
	}
	if _, err := output.Write(append(rendered, '.')); err != nil {
		return unsupported
	}
	return nil
}
