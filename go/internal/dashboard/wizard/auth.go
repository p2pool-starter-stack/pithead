package wizard

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"io"
	"strings"
)

const authTypeErrorMessage = "comparing strings with non-ASCII characters is not supported"

type authRequest struct {
	Operation   string `json:"operation"`
	Token       string `json:"token"`
	Supplied    string `json:"supplied"`
	Cookie      string `json:"cookie"`
	Failures    int    `json:"failures"`
	MaxFailures int    `json:"max_failures"`
}

type authLogin struct {
	Accepted bool `json:"accepted"`
	Failures int  `json:"failures"`
	Status   int  `json:"status"`
}

type authTypeError struct{}

func (authTypeError) Error() string { return authTypeErrorMessage }

func RunAuth(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request authRequest
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		response := Response{}
		if err := decoder.Decode(&request); err != nil {
			response.Error = wireError(err)
		} else {
			response = handleAuth(request)
		}
		if err := writeResponse(output, response); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func handleAuth(request authRequest) Response {
	var value any
	var err error
	switch request.Operation {
	case "canon":
		value = canonicalToken(request.Token)
	case "cookie":
		value, err = cookieMatches(request.Token, request.Cookie)
	case "login":
		value, err = loginToken(request)
	default:
		err = authUnsupportedError(request.Operation)
	}
	if err != nil {
		if _, ok := err.(authTypeError); ok {
			return Response{Error: &Error{Kind: "TypeError", Message: err.Error()}}
		}
		return Response{Error: wireError(err)}
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return Response{Error: wireError(err)}
	}
	return Response{OK: true, Value: raw}
}

func canonicalToken(token string) string {
	token = strings.TrimFunc(token, pythonSpace)
	token = pythonUpper(token)
	return strings.TrimPrefix(token, "PIT-")
}

func cookieMatches(token, cookie string) (bool, error) {
	if token == "" {
		return false, nil
	}
	return asciiEqual(cookie, token)
}

func loginToken(request authRequest) (authLogin, error) {
	if request.Token != "" {
		accepted, err := asciiEqual(canonicalToken(request.Supplied), canonicalToken(request.Token))
		if err != nil {
			return authLogin{}, err
		}
		if accepted {
			return authLogin{Accepted: true, Failures: request.Failures, Status: 302}, nil
		}
	}
	failures := request.Failures + 1
	status := 403
	if failures >= request.MaxFailures {
		status = 429
	}
	return authLogin{Failures: failures, Status: status}, nil
}

func asciiEqual(left, right string) (bool, error) {
	if !isASCII(left) || !isASCII(right) {
		return false, authTypeError{}
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1, nil
}

func isASCII(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] >= 0x80 {
			return false
		}
	}
	return true
}

type authUnsupportedError string

func (e authUnsupportedError) Error() string {
	return "unsupported wizard operation: auth/" + string(e)
}
