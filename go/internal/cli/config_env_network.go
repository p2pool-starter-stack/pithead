package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configEnvNetwork(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 13 || len(fields[12]) != 0 || !bytes.Equal(fields[11], []byte("0")) {
		return unsupported
	}
	plan, err := config.DeriveNetwork(fields[10], config.NetworkInput{
		ModeMonero: string(fields[0]), ModeTari: string(fields[1]), NetworkPrefix: string(fields[2]),
		MoneroRemoteHost: string(fields[3]), MoneroRemoteRPCPort: string(fields[4]),
		MoneroRemoteZMQPort: string(fields[5]), TariRemoteHost: string(fields[6]),
		TariRemoteGRPCPort: string(fields[7]), PayoutConfirm: string(fields[8]),
		TariPayoutConfirm: string(fields[9]),
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
