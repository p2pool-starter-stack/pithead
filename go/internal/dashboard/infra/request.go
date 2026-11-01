package infra

import (
	"encoding/json"
	"errors"
	"io"
)

type Request struct {
	Operation string            `json:"operation"`
	Args      []json.RawMessage `json:"args"`
	Now       float64           `json:"now"`
	Zone      string            `json:"zone"`
}

func Build(request Request) (any, error) {
	switch request.Operation {
	case "build_system":
		return buildSystem(request.Args)
	case "build_proxy_summary":
		return buildProxySummary(request.Args)
	case "build_tari":
		return buildTari(request.Args)
	case "build_sync":
		return buildSync(request.Args)
	case "build_monero":
		return buildMonero(request.Args)
	default:
		return nil, errors.New("unsupported infrastructure operation")
	}
}

func Run(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	decoder.UseNumber()
	var request Request
	if err := decoder.Decode(&request); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple infrastructure inputs")
		}
		return err
	}
	result, err := Build(request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
