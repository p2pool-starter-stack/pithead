package wizard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

func RunValues(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request ValuesRequest
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		response := Response{}
		if err := decoder.Decode(&request); err != nil {
			response.Error = wireError(err)
		} else {
			value, err := handleValuesRequest(request, callbackTransactionIO{
				readLine: func() ([]byte, error) {
					if scanner.Scan() {
						return append([]byte(nil), scanner.Bytes()...), nil
					}
					if err := scanner.Err(); err != nil {
						return nil, err
					}
					return nil, io.EOF
				},
				output: output,
				hooks:  request.IOHooks,
			})
			if err != nil {
				response.Error = configProtocolError(err)
			} else if raw, marshalErr := json.Marshal(value); marshalErr != nil {
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

func handleValuesRequest(request ValuesRequest, transactionIO transactionIO) (any, error) {
	switch request.Operation {
	case "tari":
		return tariValue(request)
	case "answers":
		return answersValue(request.Base, request.Mode), nil
	case "explicit":
		return explicitValue(request.Config, request.Reference, request.Paths)
	case "remember":
		return rememberValue(request.Previous, request.Changes)
	case "inventory":
		return inventoryValue(request.Rows)
	case "remove-spool":
		return nil, removeSpoolValues(request.Spool, request.Names, transactionIO)
	default:
		return nil, ValidationError{fmt.Sprintf("unsupported wizard values operation: %s", request.Operation)}
	}
}
