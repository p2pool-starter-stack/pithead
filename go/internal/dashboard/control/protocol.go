package control

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

type Request struct {
	Operation string          `json:"operation"`
	Directory string          `json:"directory"`
	Request   json.RawMessage `json:"request"`
	Data      []byte          `json:"data"`
	ID        string          `json:"id"`
	Action    string          `json:"action"`
	Kind      string          `json:"kind"`
	Temp      string          `json:"temp"`
	Actor     json.RawMessage `json:"actor"`
	Config    json.RawMessage `json:"config"`
	Version   json.RawMessage `json:"version"`
	Confirm   json.RawMessage `json:"confirm"`
	Approval  json.RawMessage `json:"approval"`
	Worker    json.RawMessage `json:"worker"`
	Changes   json.RawMessage `json:"changes"`
	IDPresent bool            `json:"-"`
}

func (r *Request) UnmarshalJSON(data []byte) error {
	type plain Request
	var value plain
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	*r = Request(value)
	_, r.IDPresent = fields["id"]
	return nil
}

type response struct {
	OK    bool   `json:"ok"`
	Value any    `json:"value"`
	Error *Error `json:"error,omitempty"`
}

func Process(command Request) (any, error) {
	switch command.Operation {
	case "control-submit":
		return submit(command)
	case "control-validate-worker":
		return validateWorker(command.Changes), nil
	case "control-result":
		return readResult(command.Directory, command.ID)
	case "control-write":
		return write(command)
	case "control-stage":
		return stage(command)
	case "control-publish":
		return command.ID, publish(command.Directory, command.ID, command.Temp)
	default:
		return nil, valueError("unsupported control operation: %s", command.Operation)
	}
}

func Run(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	encoder := json.NewEncoder(output)
	for scanner.Scan() {
		var command Request
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		var value any
		var err error
		if decodeErr := decoder.Decode(&command); decodeErr != nil {
			err = valueError("%s", decodeErr)
			value = nil
		} else {
			value, err = Process(command)
		}
		reply := response{OK: err == nil, Value: value}
		if err != nil {
			if typed, ok := err.(*Error); ok {
				reply.Error = typed
			} else {
				reply.Error = newError("Error", err.Error(), err)
			}
		}
		if err := encoder.Encode(reply); err != nil {
			return err
		}
	}
	return scanner.Err()
}
