package badges

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
	case "build_badges":
		return buildBadges(request)
	case "recent_wallet_change":
		return recentWalletChange(request)
	default:
		return nil, errors.New("unsupported badges operation")
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
			return errors.New("multiple badges inputs")
		}
		return err
	}
	result, err := Build(request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
