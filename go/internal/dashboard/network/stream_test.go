package network

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestStreamKeepsRequestsIndependent(t *testing.T) {
	valid := validPolicyJSON(t, "posture")
	input := valid + "\n{" + "\n" + valid + "\n"
	var output bytes.Buffer
	if err := RunStream(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(&output)
	for index, want := range []bool{true, false, true} {
		var response wireResponse
		if err := decoder.Decode(&response); err != nil || response.OK != want {
			t.Fatalf("response %d = %#v, error %v", index, response, err)
		}
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		t.Fatalf("trailing response: %v", err)
	}
}

func TestStreamBoundsAndIOErrors(t *testing.T) {
	valid := validPolicyJSON(t, "posture")
	boundary := valid + strings.Repeat(" ", maxRequestBytes-len(valid))
	var output bytes.Buffer
	if err := RunStream(strings.NewReader(boundary+"\n"), &output); err != nil {
		t.Fatalf("boundary request: %v", err)
	}
	var response wireResponse
	if err := json.Unmarshal(output.Bytes(), &response); err != nil || !response.OK {
		t.Fatalf("boundary response: %#v, %v", response, err)
	}
	output.Reset()
	if err := RunStream(strings.NewReader(strings.Repeat("x", maxRequestBytes+1)+"\n"), &output); err == nil || output.Len() != 0 {
		t.Fatalf("oversize result: output=%d, error=%v", output.Len(), err)
	}
	if err := RunStream(strings.NewReader(valid+"\n"), failingWriter{}); err == nil || err.Error() != "write failed" {
		t.Fatalf("write error = %v", err)
	}
	want := errors.New("read failed")
	if err := RunStream(errorReader{want}, &output); !errors.Is(err, want) {
		t.Fatalf("read error = %v", err)
	}
}

type errorReader struct{ err error }

func (reader errorReader) Read([]byte) (int, error) { return 0, reader.err }
