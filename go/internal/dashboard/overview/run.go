package overview

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
	case "build_pool_network":
		return buildPoolNetwork(request)
	case "build_raffle_log":
		return buildRaffleLog(request)
	case "build_raffle_eligibility":
		return buildRaffleEligibility(request)
	case "_egress_badge":
		return buildEgressBadge(request)
	case "visible_update":
		return buildVisibleUpdate(request)
	default:
		return nil, errors.New("unsupported overview operation")
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
			return errors.New("multiple overview inputs")
		}
		return err
	}
	result, err := Build(request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
