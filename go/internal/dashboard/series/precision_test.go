package series

import (
	"encoding/json"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
)

func TestShareDownsamplePreservesArbitraryIntegers(t *testing.T) {
	rows := []map[string]any{
		{"ts": 1, "accepted": json.Number("9223372036854775807")},
		{"ts": 2, "accepted": json.Number("9223372036854775807")},
	}
	result, err := downsampleShares(rows, 1)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := result[0]["accepted"].(json.Number)
	if !ok || got.String() != "18446744073709551614" {
		t.Fatalf("accepted sum = %#v", result[0]["accepted"])
	}
}

func TestGaugeDownsampleDividesExactIntegerSum(t *testing.T) {
	rows := []map[string]any{
		{"ts": 1, "value": json.Number("9007199254740993")},
		{"ts": 2, "value": json.Number("-9007199254740992")},
	}
	result, err := downsampleGauges(rows, []string{"value"}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if got := result[0]["value"]; got != domain.PythonFloat(0.5) {
		t.Fatalf("gauge average = %#v", got)
	}
}
