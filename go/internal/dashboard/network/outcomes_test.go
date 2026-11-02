package network

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestControlOutcomesAllStatusesAndMetadata(t *testing.T) {
	terminal := []string{"applied", "rejected", "rolled_back", "failed", "noop", "throttled", "applied"}
	rows := []outcomeRow{}
	for _, status := range terminal[:6] {
		rows = append(rows, outcomeRow{IDString: outcomeBool(true), IDNonempty: outcomeBool(true), StatusKind: outcomeString("string"), Status: outcomeStatus(status)})
	}
	rows = append(rows,
		outcomeRow{IDString: outcomeBool(false), IDNonempty: outcomeBool(true), StatusKind: outcomeString("string"), Status: outcomeStatus("applied")},
		outcomeRow{IDString: outcomeBool(true), IDNonempty: outcomeBool(false), StatusKind: outcomeString("string"), Status: outcomeStatus("applied")},
		outcomeRow{IDString: outcomeBool(true), IDNonempty: outcomeBool(true), StatusKind: outcomeString("other")},
		outcomeRow{IDString: outcomeBool(true), IDNonempty: outcomeBool(true), StatusKind: outcomeString("string"), Status: outcomeStatus("running")},
	)
	got, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)})
	want := []bool{true, true, true, true, true, true, false, false, false, false}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("outcomes=%v err=%v", got, err)
	}
}

func TestControlOutcomesEmptyVocabularyAndOrder(t *testing.T) {
	terminal := []string{}
	rows := []outcomeRow{
		{IDString: outcomeBool(true), IDNonempty: outcomeBool(true), StatusKind: outcomeString("string"), Status: outcomeStatus("applied")},
		{IDString: outcomeBool(true), IDNonempty: outcomeBool(true), StatusKind: outcomeString("other")},
	}
	got, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)})
	if err != nil || got == nil || !reflect.DeepEqual(got, []bool{false, false}) {
		t.Fatalf("outcomes=%v err=%v", got, err)
	}
	emptyRows := []outcomeRow{}
	got, err = controlOutcomes(outcomeRequest{Rows: &emptyRows, Terminal: outcomeTerminal(terminal)})
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("empty outcomes=%v err=%v", got, err)
	}
}

func TestControlOutcomeBounds(t *testing.T) {
	text := strings.Repeat("é", 128)
	terminal := []string{text}
	rows := []outcomeRow{{IDString: outcomeBool(true), IDNonempty: outcomeBool(true), StatusKind: outcomeString("string"), Status: outcomeStatus(text)}}
	if got, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)}); err != nil || !reflect.DeepEqual(got, []bool{true}) {
		t.Fatalf("boundary outcomes=%v err=%v", got, err)
	}
	tooLong := text + "x"
	terminal = []string{tooLong}
	if _, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)}); err == nil {
		t.Fatal("accepted oversized vocabulary value")
	}
	terminal = []string{"applied"}
	rows[0].Status = outcomeStatus(tooLong)
	if _, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)}); err == nil {
		t.Fatal("accepted oversized row status")
	}
	rows = make([]outcomeRow, maxOutcomeRows+1)
	if _, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)}); err == nil {
		t.Fatal("accepted oversized row batch")
	}
	terminal = make([]string, maxTerminalValues+1)
	rows = []outcomeRow{}
	if _, err := controlOutcomes(outcomeRequest{Rows: &rows, Terminal: outcomeTerminal(terminal)}); err == nil {
		t.Fatal("accepted oversized vocabulary")
	}
}

func TestControlOutcomeProtocolRejectsMalformedMetadata(t *testing.T) {
	cases := [][]byte{
		[]byte(`{"operation":"control-outcomes","rows":null,"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[],"terminal":null}`),
		[]byte(`{"operation":"control-outcomes","rows":[],"terminal":[null]}`),
		[]byte(`{"operation":"control-outcomes","rows":[],"terminal":[1]}`),
		[]byte(`{"operation":"control-outcomes","rows":[],"terminal":[true]}`),
		[]byte(`{"operation":"control-outcomes","rows":[],"terminal":[{}]}`),
		[]byte(`{"operation":"control-outcomes","rows":[{"id_nonempty":true,"status_kind":"other"}],"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[{"id_string":true,"id_nonempty":true,"status_kind":"string"}],"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[{"id_string":true,"id_nonempty":true,"status_kind":"string","status":null}],"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[{"id_string":true,"id_nonempty":true,"status_kind":"other","status":null}],"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[{"id_string":true,"id_nonempty":true,"status_kind":"bad"}],"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[{"id_string":true,"id_nonempty":true,"status_kind":"other","extra":true}],"terminal":[]}`),
		[]byte(`{"operation":"control-outcomes","rows":[],"terminal":[],"extra":true}`),
		append([]byte(`{"operation":"control-outcomes","rows":[],"terminal":["`), append([]byte{0xff}, []byte(`"]}`)...)...),
	}
	for _, input := range cases {
		if _, err := build(input); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
}

func TestControlOutcomeProtocolAndWriteError(t *testing.T) {
	input := `{"operation":"control-outcomes","rows":[{"id_string":true,"id_nonempty":true,"status_kind":"string","status":"applied"},{"id_string":true,"id_nonempty":true,"status_kind":"other"}],"terminal":["applied","applied"]}`
	value, err := build([]byte(input))
	if err != nil || !reflect.DeepEqual(value, []bool{true, false}) {
		t.Fatalf("value=%v err=%v", value, err)
	}
	if err := Run(strings.NewReader(input), failingWriter{}); err == nil || err.Error() != "write failed" {
		t.Fatalf("write error=%v", err)
	}
	var output bytes.Buffer
	if err := Run(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	var response wireResponse
	if err := json.Unmarshal(output.Bytes(), &response); err != nil || !response.OK {
		t.Fatalf("response=%s err=%v", output.String(), err)
	}
}

func outcomeBool(value bool) *bool {
	return &value
}

func outcomeString(value string) *string {
	return &value
}

func outcomeStatus(value string) json.RawMessage {
	encoded, _ := json.Marshal(value)
	return encoded
}

func outcomeTerminal(values []string) *[]*string {
	result := make([]*string, len(values))
	for index, value := range values {
		result[index] = outcomeString(value)
	}
	return &result
}
