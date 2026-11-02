package wizard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

func RunDocuments(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request DocumentRequest
		response := Response{}
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		if err := decoder.Decode(&request); err != nil {
			response.Error = wireError(err)
		} else {
			result, err := handleDocumentRequest(request)
			if err != nil {
				response.Error = configProtocolError(err)
			} else if raw, marshalErr := json.Marshal(result); marshalErr != nil {
				response.Error = wireError(marshalErr)
			} else {
				response = Response{OK: true, Value: raw}
			}
		}
		if err := writeResponse(output, response); err != nil {
			return err
		}
	}
	return scanner.Err()
}
