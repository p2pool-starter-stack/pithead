package cli

import (
	"bytes"
	"io"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configEnv(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) < 5 || len(fields)%2 != 1 || len(fields[len(fields)-1]) != 0 ||
		len(fields[len(fields)-3]) != 0 || !bytes.Equal(fields[len(fields)-2], []byte("0")) {
		return unsupported
	}
	pairs := make([]config.EnvPair, 0, (len(fields)-3)/2)
	for index := 0; index < len(fields)-3; index += 2 {
		pairs = append(pairs, config.EnvPair{Key: string(fields[index]), Value: string(fields[index+1])})
	}
	rendered, err := config.RenderEnv(pairs)
	if err != nil {
		return unsupported
	}
	if _, err := output.Write(append(rendered, '.')); err != nil {
		return unsupported
	}
	return nil
}
