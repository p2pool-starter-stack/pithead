package domain

import (
	"encoding/json"
	"errors"
	"io"
	"math"
)

type averageInput struct {
	History []map[string]any `json:"history"`
	Window  float64          `json:"window"`
	Now     float64          `json:"now"`
	XVB     bool             `json:"xvb"`
}

func RunAverage(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	decoder.UseNumber()
	var request averageInput
	if err := decoder.Decode(&request); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple average inputs")
		}
		return err
	}
	if math.IsNaN(request.Window) || math.IsInf(request.Window, 0) || math.IsNaN(request.Now) || math.IsInf(request.Now, 0) {
		return errors.New("invalid average input")
	}
	key := "v_p2pool"
	legacy := true
	if request.XVB {
		key = "v_xvb"
		legacy = false
	}
	result, err := average(request.History, request.Window, request.Now, key, legacy)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(PythonFloat(result))
}
