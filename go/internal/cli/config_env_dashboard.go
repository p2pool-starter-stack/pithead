package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configEnvDashboard(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 7 || len(fields[6]) != 0 || !bytes.Equal(fields[5], []byte("0")) {
		return unsupported
	}
	plan, err := config.DeriveDashboard(fields[4], fields[3], config.DashboardInput{
		Platform: string(fields[0]), TariMode: string(fields[1]), MoneroWallet: string(fields[2]),
	})
	if err != nil {
		return unsupported
	}
	var result bytes.Buffer
	for _, value := range plan.Values() {
		result.WriteString(value)
		result.WriteByte(0)
	}
	if _, err := output.Write(result.Bytes()); err != nil {
		return unsupported
	}
	return nil
}
