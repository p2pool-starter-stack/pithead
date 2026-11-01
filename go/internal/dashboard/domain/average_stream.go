package domain

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

func RunAverageStream(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	for {
		var request json.RawMessage
		if err := decoder.Decode(&request); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		if err := RunAverage(bytes.NewReader(request), output); err != nil {
			return err
		}
	}
}
