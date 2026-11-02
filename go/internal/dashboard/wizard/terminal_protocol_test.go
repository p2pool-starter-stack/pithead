package wizard

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type terminalWireResponse struct {
	OK    bool            `json:"ok"`
	Value json.RawMessage `json:"value"`
	Error *Error          `json:"error"`
}

type terminalErrorWriter struct{ err error }

func (w terminalErrorWriter) Write([]byte) (int, error) { return 0, w.err }

func TestRunTerminalJSONLines(t *testing.T) {
	requests := []TerminalRequest{
		{Operation: "handoff"},
		{Operation: "retry", Authenticated: true, Stage: "failed"},
	}
	var input bytes.Buffer
	for _, request := range requests {
		encoded, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		input.Write(encoded)
		input.WriteByte('\n')
	}
	var output bytes.Buffer
	if err := RunTerminal(&input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("lines=%d", len(lines))
	}
	first := decodeTerminalResponse(t, lines[0])
	var unauthenticated TerminalResult
	if !first.OK || first.Error != nil || json.Unmarshal(first.Value, &unauthenticated) != nil || unauthenticated.Status != 401 {
		t.Fatalf("first=%#v result=%#v", first, unauthenticated)
	}
	second := decodeTerminalResponse(t, lines[1])
	var lazy TerminalResult
	if !second.OK || second.Error != nil || json.Unmarshal(second.Value, &lazy) != nil || !lazy.NeedSpool {
		t.Fatalf("second=%#v result=%#v", second, lazy)
	}
}

func TestRunTerminalPreservesRawHandoffText(t *testing.T) {
	handoff := t.TempDir()
	want := `{"message":"\u263a"}`
	writeTerminalFile(t, handoff, "handoff.json", want)
	request, err := json.Marshal(TerminalRequest{Operation: "handoff", Authenticated: true, Handoff: handoff})
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := RunTerminal(bytes.NewReader(append(request, '\n')), &output); err != nil {
		t.Fatal(err)
	}
	response := decodeTerminalResponse(t, strings.TrimSpace(output.String()))
	var result TerminalResult
	if err := json.Unmarshal(response.Value, &result); err != nil {
		t.Fatal(err)
	}
	if result.Raw == nil || *result.Raw != want {
		t.Fatalf("raw=%v", result.Raw)
	}
}

func TestRunTerminalReportsMalformedAndUnknownRequests(t *testing.T) {
	var output bytes.Buffer
	if err := RunTerminal(strings.NewReader("not-json\n{\"operation\":\"unknown\"}\n"), &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("lines=%d", len(lines))
	}
	malformed := decodeTerminalResponse(t, lines[0])
	unknown := decodeTerminalResponse(t, lines[1])
	if malformed.OK || malformed.Error == nil || unknown.OK || unknown.Error == nil || unknown.Error.Kind != "ValueError" {
		t.Fatalf("malformed=%#v unknown=%#v", malformed, unknown)
	}
}

func TestRunTerminalReturnsOutputError(t *testing.T) {
	wantErr := errors.New("closed output")
	err := RunTerminal(strings.NewReader("{\"operation\":\"handoff\"}\n"), terminalErrorWriter{err: wantErr})
	if !errors.Is(err, wantErr) {
		t.Fatalf("error=%v", err)
	}
}

func decodeTerminalResponse(t *testing.T, line string) terminalWireResponse {
	t.Helper()
	var response terminalWireResponse
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		t.Fatal(err)
	}
	return response
}
