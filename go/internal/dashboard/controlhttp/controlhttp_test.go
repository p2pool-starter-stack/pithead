package controlhttp

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"
)

func cvString(value string) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "str", Text: value}
}

func cvBool(value bool) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "bool", Bool: value}
}

func cvDict(fields ...wizard.ConfigField) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "dict", Fields: fields}
}

func TestHeaderAndApprovalPolicy(t *testing.T) {
	result, err := Handle(Request{Operation: "header", Value: cvString("0")})
	if err != nil || result.Status != 403 || result.Text.Text != "Missing X-Pithead-Control header." {
		t.Fatalf("header result = %#v, %v", result, err)
	}
	body := cvDict(
		wizard.ConfigField{Key: "approve", Value: cvBool(true)},
		wizard.ConfigField{Key: "payout_suffixes", Value: cvDict(
			wizard.ConfigField{Key: "tari", Value: cvString("abcd")},
		)},
	)
	result, err = Handle(Request{Operation: "approval", Value: body})
	if err != nil || result.Next != "approval" || result.Value.Fields[0].Key != "payout_suffixes" {
		t.Fatalf("approval result = %#v, %v", result, err)
	}
	body.Set("approve", cvString("true"))
	result, err = Handle(Request{Operation: "approval", Value: body})
	if err != nil || result.Value.Kind != "null" {
		t.Fatalf("strict approval = %#v, %v", result, err)
	}
}

func TestVersionAcceptsUnicodeDecimalDigits(t *testing.T) {
	for _, version := range []string{"v1.22.333", "v١.٢.٣", "v１２.３.４", "v𝟎.𝟙.𝟚"} {
		result, err := Handle(Request{Operation: "version", Route: "upgrade", Version: cvString(version)})
		if err != nil || result.Next != "ready" {
			t.Fatalf("version %q = %#v, %v", version, result, err)
		}
	}
	result, err := Handle(Request{Operation: "version", Route: "upgrade", Version: cvString("v¹.2.3")})
	if err != nil || result.Status != 400 {
		t.Fatalf("non-decimal digit = %#v, %v", result, err)
	}
	for _, version := range []string{"v𑽐.1.2", "v𞓰.1.2"} {
		result, err = Handle(Request{Operation: "version", Route: "upgrade", Version: cvString(version)})
		if err != nil || result.Status != 400 {
			t.Fatalf("post-Unicode-14 digit %q = %#v, %v", version, result, err)
		}
	}
	result, err = Handle(Request{Operation: "version", Route: "os-update", Version: nullValue()})
	if err != nil || result.Next != "ready" {
		t.Fatalf("optional OS version = %#v, %v", result, err)
	}
}

func TestCompletePreservesIDPositionAndResultOverride(t *testing.T) {
	id := cvString("request-id")
	resultValue := cvDict(
		wizard.ConfigField{Key: "status", Value: cvString("applied")},
		wizard.ConfigField{Key: "id", Value: cvString("result-id")},
	)
	result, err := Handle(Request{Operation: "complete", Route: "preview", Value: resultValue, ID: id})
	if err != nil || result.Status != 200 {
		t.Fatalf("complete = %#v, %v", result, err)
	}
	if len(result.Body.Fields) != 2 || result.Body.Fields[0].Key != "id" || result.Body.Fields[0].Value.Text != "result-id" || result.Body.Fields[1].Key != "status" {
		t.Fatalf("body fields = %#v", result.Body.Fields)
	}
	pending, err := Handle(Request{Operation: "complete", Route: "result", Value: nullValue()})
	if err != nil || pending.Status != 202 || pending.Body.Fields[0].Value.Text != "pending" {
		t.Fatalf("pending = %#v, %v", pending, err)
	}
}

func TestOSActionRejectsUnhashableValues(t *testing.T) {
	_, err := Handle(Request{Operation: "os-action", Value: &wizard.ConfigValue{Kind: "list"}})
	var protocol protocolError
	if !errors.As(err, &protocol) || protocol.kind != "TypeError" || protocol.message != "unhashable type: 'list'" {
		t.Fatalf("error = %#v", err)
	}
	result, err := Handle(Request{Operation: "os-action", Value: cvString("verify")})
	if err != nil || result.Action != "os-verify" {
		t.Fatalf("action = %#v, %v", result, err)
	}
}

func TestRunReportsMalformedInputAndWriteFailure(t *testing.T) {
	var output bytes.Buffer
	if err := Run(bytes.NewBufferString("{\n"), &output); err != nil {
		t.Fatal(err)
	}
	var got struct {
		OK    bool      `json:"ok"`
		Error wireError `json:"error"`
	}
	if err := json.Unmarshal(output.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.OK || got.Error.Kind != "ValueError" || got.Error.Message == "" {
		t.Fatalf("response = %#v", got)
	}
	if err := Run(bytes.NewBufferString("{\"operation\":\"header\"}\n"), failingWriter{}); err == nil {
		t.Fatal("write error was ignored")
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }
