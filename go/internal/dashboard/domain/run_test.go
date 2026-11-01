package domain

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	input := baseInput()
	encoded, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := Run(bytes.NewReader(encoded), &output); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(output.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["mode"] != "XVB (Split)" || len(got) != 46 {
		t.Fatalf("output = %#v", got)
	}
	if !strings.Contains(output.String(), `"target_threshold":10000.0`) {
		t.Fatalf("float encoding = %s", output.String())
	}
}

func TestRunRejectsTrailingInput(t *testing.T) {
	if err := Run(strings.NewReader(`{} {}`), &bytes.Buffer{}); err == nil {
		t.Fatal("expected trailing input error")
	}
}

func TestRunAverage(t *testing.T) {
	input := `{"history":[{"timestamp":970,"v":1000,"v_p2pool":600,"v_xvb":400},{"timestamp":940,"v":800,"v_p2pool":0,"v_xvb":0}],"window":100,"now":1000,"xvb":false}`
	var output bytes.Buffer
	if err := RunAverage(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "700.0\n" {
		t.Fatalf("p2pool average = %q", output.String())
	}
	input = strings.Replace(input, `"xvb":false`, `"xvb":true`, 1)
	output.Reset()
	if err := RunAverage(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "200.0\n" {
		t.Fatalf("xvb average = %q", output.String())
	}
}

func TestRunAverageRejectsInvalidInput(t *testing.T) {
	for _, input := range []string{
		`{"history":[],"window":1,"now":2} {}`,
		`{"history":[{"timestamp":"bad"}],"window":1,"now":2}`,
	} {
		if err := RunAverage(strings.NewReader(input), &bytes.Buffer{}); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
}

func TestArithmeticOverflowFallsBack(t *testing.T) {
	input := baseInput()
	input.LatestData["shares"] = []any{
		map[string]any{"ts": json.Number("1700000000"), "difficulty": json.Number("9223372036854775807")},
		map[string]any{"ts": json.Number("1700000000"), "difficulty": json.Number("1")},
	}
	if _, err := Build(input); err == nil {
		t.Fatal("expected share-weight overflow")
	}
	input = baseInput()
	input.LatestData["monero_sync"] = map[string]any{
		"target": json.Number("-9223372036854775808"), "current": json.Number("1"),
	}
	if _, err := Build(input); err == nil {
		t.Fatal("expected sync subtraction overflow")
	}
}

func TestShareRejectPct(t *testing.T) {
	rows := []map[string]any{
		{"ts": json.Number("990"), "accepted": json.Number("3"), "rejected": json.Number("1")},
		{"ts": json.Number("800"), "accepted": json.Number("100"), "rejected": json.Number("100")},
	}
	got, err := ShareRejectPct(rows, 100, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || *got != PythonFloat(25) {
		t.Fatalf("reject pct = %#v", got)
	}
	got, err = ShareRejectPct(nil, 100, 1000)
	if err != nil || got != nil {
		t.Fatalf("empty reject pct = %#v, %v", got, err)
	}
}
