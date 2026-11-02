package network

import (
	"reflect"
	"testing"
)

func TestAuditCapPolicyComparisons(t *testing.T) {
	limit := 3
	got, err := buildAuditCapPolicy(auditCapRequest{Limit: &limit})
	want := auditCapPolicy{
		Limit:     3,
		NamesFull: []bool{false, false, false, true, true},
		Spend:     [][2]bool{{true, false}, {true, false}, {true, false}, {false, true}, {false, false}},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("policy=%v err=%v", got, err)
	}
}

func TestAuditCapPolicyZeroAndMaximumBounds(t *testing.T) {
	zero := 0
	got, err := buildAuditCapPolicy(auditCapRequest{Limit: &zero})
	if err != nil || !reflect.DeepEqual(got.NamesFull, []bool{true, true}) || !reflect.DeepEqual(got.Spend, [][2]bool{{false, true}, {false, false}}) {
		t.Fatalf("zero policy=%v err=%v", got, err)
	}
	maximum := maxAuditCap
	got, err = buildAuditCapPolicy(auditCapRequest{Limit: &maximum})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.NamesFull) != maxAuditCap+2 || got.NamesFull[maxAuditCap-1] || !got.NamesFull[maxAuditCap] || !got.NamesFull[maxAuditCap+1] {
		t.Fatalf("maximum names boundary=%v", got.NamesFull[maxAuditCap-1:])
	}
	if len(got.Spend) != maxAuditCap+2 || got.Spend[maxAuditCap-1] != [2]bool{true, false} || got.Spend[maxAuditCap] != [2]bool{false, true} || got.Spend[maxAuditCap+1] != [2]bool{false, false} {
		t.Fatalf("maximum spend boundary=%v", got.Spend[maxAuditCap-1:])
	}
}

func TestAuditCapPolicyResultsDoNotShareSlices(t *testing.T) {
	limit := 1
	first, err := buildAuditCapPolicy(auditCapRequest{Limit: &limit})
	if err != nil {
		t.Fatal(err)
	}
	first.NamesFull[0] = true
	first.Spend[0] = [2]bool{}
	second, err := buildAuditCapPolicy(auditCapRequest{Limit: &limit})
	if err != nil || second.NamesFull[0] || second.Spend[0] != [2]bool{true, false} {
		t.Fatalf("second policy=%v err=%v", second, err)
	}
}

func TestAuditCapPolicyProtocolRejectsMalformedInput(t *testing.T) {
	cases := []string{
		`{"operation":"audit-cap-policy"}`,
		`{"operation":"audit-cap-policy","limit":null}`,
		`{"operation":"audit-cap-policy","limit":true}`,
		`{"operation":"audit-cap-policy","limit":1.0}`,
		`{"operation":"audit-cap-policy","limit":1e0}`,
		`{"operation":"audit-cap-policy","limit":"1"}`,
		`{"operation":"audit-cap-policy","limit":-1}`,
		`{"operation":"audit-cap-policy","limit":4097}`,
		`{"operation":"audit-cap-policy","limit":1,"extra":true}`,
		`{"operation":"audit-cap-policy","limit":1,"cap":1}`,
	}
	for _, input := range cases {
		if _, err := build([]byte(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}

func TestAuditCapPolicyProtocolValue(t *testing.T) {
	value, err := build([]byte(`{"operation":"audit-cap-policy","limit":1}`))
	want := auditCapPolicy{
		Limit:     1,
		NamesFull: []bool{false, true, true},
		Spend:     [][2]bool{{true, false}, {false, true}, {false, false}},
	}
	if err != nil || !reflect.DeepEqual(value, want) {
		t.Fatalf("value=%v err=%v", value, err)
	}
}
