package domain

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunAverageStream(t *testing.T) {
	input := strings.Join([]string{
		`{"history":[{"timestamp":100,"v_p2pool":10,"v_xvb":4}],"window":60,"now":100,"xvb":false}`,
		`{"history":[{"timestamp":100,"v_p2pool":10,"v_xvb":4}],"window":60,"now":100,"xvb":true}`,
		`{"history":[],"window":60,"now":100,"xvb":false}`,
	}, "\n") + "\n"
	var output bytes.Buffer
	if err := RunAverageStream(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "10.0\n4.0\n0.0\n"; got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestRunAverageStreamRejectsMalformedRequest(t *testing.T) {
	input := `{"history":[],"window":60,"now":100,"xvb":false}` + "\n{\n"
	var output bytes.Buffer
	if err := RunAverageStream(strings.NewReader(input), &output); err == nil {
		t.Fatal("accepted malformed stream request")
	}
	if got, want := output.String(), "0.0\n"; got != want {
		t.Fatalf("output before error = %q, want %q", got, want)
	}
}
