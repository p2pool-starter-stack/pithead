package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/fleet"
)

func TestFleetStreamKeepsRequestsIndependent(t *testing.T) {
	input := `{"operation":"_num","args":[12]}` + "\n" + `{"operation":"_num","args":[13.5]}`
	var output bytes.Buffer
	if err := streamHelper(fleet.Run, strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "12\n13.5\n" {
		t.Fatalf("responses = %q", output.String())
	}
}

func TestFleetStreamRejectsMalformedLaterFrame(t *testing.T) {
	var output bytes.Buffer
	err := streamHelper(fleet.Run, strings.NewReader(`{"operation":"_num","args":[12]} {`), &output)
	if err == nil || output.String() != "12\n" {
		t.Fatalf("response = %q, error = %v", output.String(), err)
	}
}
