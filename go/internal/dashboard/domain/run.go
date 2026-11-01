package domain

import (
	"encoding/json"
	"errors"
	"io"
)

func Run(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	decoder.UseNumber()
	var request Input
	if err := decoder.Decode(&request); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple domain inputs")
		}
		return err
	}
	metrics, err := Build(request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(metrics)
}
