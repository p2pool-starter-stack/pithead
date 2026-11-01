package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

func streamHelper(run func(io.Reader, io.Writer) error, input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	for {
		var request json.RawMessage
		if err := decoder.Decode(&request); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		if err := run(bytes.NewReader(request), output); err != nil {
			return err
		}
	}
}
