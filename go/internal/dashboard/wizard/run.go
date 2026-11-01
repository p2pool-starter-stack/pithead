package wizard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"syscall"
)

const wizardProtocolLineLimit = 64 << 10

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
			response = handle(request, callbackTransactionIO{
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
		}
		if err := writeResponse(output, response); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func RunWrite(input io.Reader, output io.Writer) error {
	reader := bufio.NewReaderSize(input, wizardProtocolLineLimit)
	header, err := readBoundedLine(reader)
	response := Response{}
	var request Request
	if err != nil {
		response.Error = wireError(err)
	} else {
		decoder := json.NewDecoder(bytes.NewReader(header))
		decoder.UseNumber()
		if err := decoder.Decode(&request); err != nil {
			response.Error = wireError(err)
		} else if request.Operation != "write" {
			response.Error = wireError(fmt.Errorf("unsupported wizard operation: %s", request.Operation))
		} else {
			txn := Txn{
				Spool:   request.Spool,
				Restore: request.Restore,
				IO: callbackTransactionIO{
					readLine: func() ([]byte, error) { return readBoundedLine(reader) },
					output:   output,
					hooks:    request.IOHooks,
				},
			}
			if err := txn.WriteStream(request.Name, reader, request.Length, request.Directory); err != nil {
				response.Error = wireError(err)
			} else {
				response.OK = true
			}
		}
	}
	return writeResponse(output, response)
}

func readBoundedLine(reader *bufio.Reader) ([]byte, error) {
	line, err := reader.ReadSlice('\n')
	if err == bufio.ErrBufferFull {
		return nil, fmt.Errorf("wizard protocol line exceeds %d bytes", wizardProtocolLineLimit)
	}
	if err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(line, []byte{'\n'}), nil
}

func writeResponse(output io.Writer, response Response) error {
	encoded, err := response.MarshalJSON()
	if err != nil {
		return err
	}
	_, err = output.Write(append(encoded, '\n'))
	return err
}

type callbackTransactionIO struct {
	readLine func() ([]byte, error)
	output   io.Writer
	hooks    map[string]bool
}

func (c callbackTransactionIO) Replace(source, destination string) error {
	if !c.hooks["replace"] {
		return systemTransactionIO{}.Replace(source, destination)
	}
	return c.call(map[string]string{
		"event": "replace", "source": source, "destination": destination,
	})
}

func (c callbackTransactionIO) Unlink(path string) error {
	if !c.hooks["unlink"] {
		return systemTransactionIO{}.Unlink(path)
	}
	return c.call(map[string]string{"event": "unlink", "path": path})
}

func (c callbackTransactionIO) call(event map[string]string) error {
	encoded, err := json.Marshal(event)
	if err != nil {
		return err
	}
	if _, err := c.output.Write(append(encoded, '\n')); err != nil {
		return err
	}
	line, err := c.readLine()
	if err == io.EOF {
		return fmt.Errorf("wizard callback ended without a response")
	}
	if err != nil {
		return err
	}
	var reply struct {
		OK    bool   `json:"ok"`
		Error *Error `json:"error"`
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.UseNumber()
	if err := decoder.Decode(&reply); err != nil {
		return err
	}
	if reply.OK {
		return nil
	}
	if reply.Error == nil {
		return fmt.Errorf("wizard callback failed")
	}
	return callbackError{message: reply.Error.Message, errno: callbackErrno(reply.Error.Errno)}
}

type callbackError struct {
	message string
	errno   syscall.Errno
}

func (e callbackError) Error() string { return e.message }

func (e callbackError) Unwrap() error {
	if e.errno == 0 {
		return nil
	}
	return e.errno
}

func callbackErrno(value any) syscall.Errno {
	switch number := value.(type) {
	case json.Number:
		integer, _ := strconv.ParseInt(string(number), 10, 64)
		return syscall.Errno(integer)
	case float64:
		return syscall.Errno(int(number))
	}
	return 0
}
