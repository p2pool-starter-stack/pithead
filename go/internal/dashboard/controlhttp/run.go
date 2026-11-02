package controlhttp

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

type wireError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Errno   any    `json:"errno"`
}

type response struct {
	OK    bool
	Value *Result
	Error *wireError
}

func (r response) MarshalJSON() ([]byte, error) {
	if !r.OK {
		return json.Marshal(struct {
			OK    bool       `json:"ok"`
			Error *wireError `json:"error"`
		}{Error: r.Error})
	}
	return json.Marshal(struct {
		OK    bool    `json:"ok"`
		Value *Result `json:"value"`
	}{OK: true, Value: r.Value})
}

func Run(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request Request
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		result := response{}
		if err := decoder.Decode(&request); err != nil {
			failure := protocolFailure(err)
			result.Error = &failure
		} else if value, err := Handle(request); err != nil {
			failure := protocolFailure(err)
			result.Error = &failure
		} else {
			result.OK, result.Value = true, &value
		}
		encoded, err := result.MarshalJSON()
		if err != nil {
			return err
		}
		if _, err := output.Write(append(encoded, '\n')); err != nil {
			return err
		}
	}
	return scanner.Err()
}
