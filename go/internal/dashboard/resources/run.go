package resources

import (
	"encoding/json"
	"errors"
	"io"
)

type Request struct {
	Operation string            `json:"operation"`
	Args      []json.RawMessage `json:"args"`
	Now       float64           `json:"now"`
	MaxAge    float64           `json:"max_age"`
}

func Build(request Request) (any, error) {
	switch request.Operation {
	case "build_host_resources":
		return buildHostResources(request)
	case "capacity_outlook":
		return buildCapacityOutlook(request)
	default:
		return nil, errors.New("unsupported host resources operation")
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
			return errors.New("multiple host resources inputs")
		}
		return err
	}
	result, err := Build(request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
