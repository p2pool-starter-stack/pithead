package wizard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

func Run(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request Request
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		response := Response{}
		if err := decoder.Decode(&request); err != nil {
			response.Error = wireError(err)
		} else {
			response = Handle(request)
		}
		encoded, err := response.MarshalJSON()
		if err != nil {
			return err
		}
		if _, err := output.Write(append(encoded, '\n')); err != nil {
			return err
		}
	}
	return scanner.Err()
}
