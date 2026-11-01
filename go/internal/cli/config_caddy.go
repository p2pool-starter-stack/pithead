package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configCaddy(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 12 || len(fields[11]) != 0 {
		return unsupported
	}
	values := config.CaddyInput{
		Secure: string(fields[0]), HostPort: string(fields[1]), Host: string(fields[2]),
		HTTPAddresses: string(fields[3]), HTTPSAddresses: string(fields[4]),
		BindAddresses: string(fields[5]), Auth: string(fields[6]), TLSLine: string(fields[7]),
		BootCapability: string(fields[8]), NetworkPrefix: string(fields[9]), Onion: string(fields[10]),
	}
	rendered, err := config.RenderCaddyFragment(args[0], values)
	if err != nil {
		return unsupported
	}
	if _, err := output.Write(append(rendered, '.')); err != nil {
		return unsupported
	}
	return nil
}
