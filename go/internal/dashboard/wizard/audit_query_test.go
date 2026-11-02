package wizard

import (
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func auditFloatValue(value string) *ConfigValue {
	return &ConfigValue{Kind: "float", Text: value}
}

func auditNullValue() *ConfigValue {
	return &ConfigValue{Kind: "null"}
}

func auditIndexValues(value *ConfigValue) []string {
	indices := make([]string, len(value.Items))
	for index, item := range value.Items {
		indices[index] = item.Text
	}
	return indices
}

func auditWindowArguments(epochs *ConfigValue, from, to *ConfigValue) *ConfigValue {
	return opDict(opField("epochs", epochs), opField("from", from), opField("to", to))
}

func TestAuditWindowUsesExactHalfOpenNumericComparisons(t *testing.T) {
	epochs := opList(
		auditNullValue(),
		auditFloatValue("-Inf"),
		auditFloatValue("-1"),
		auditFloatValue("0"),
		auditFloatValue("NaN"),
		auditFloatValue("1"),
		auditFloatValue("+Inf"),
	)
	got, err := auditWindow(auditWindowArguments(epochs, auditFloatValue("-1"), auditFloatValue("+Inf")))
	if err != nil || !reflect.DeepEqual(auditIndexValues(got), []string{"2", "3", "4", "5"}) {
		t.Fatalf("window = %#v, error = %v", auditIndexValues(got), err)
	}

	all, err := auditWindow(auditWindowArguments(epochs, auditNullValue(), auditNullValue()))
	if err != nil || !reflect.DeepEqual(auditIndexValues(all), []string{"0", "1", "2", "3", "4", "5", "6"}) {
		t.Fatalf("unbounded = %#v, error = %v", auditIndexValues(all), err)
	}

	none, err := auditWindow(auditWindowArguments(opList(auditFloatValue("0")), auditFloatValue("NaN"), auditNullValue()))
	if err != nil || !reflect.DeepEqual(auditIndexValues(none), []string{"0"}) {
		t.Fatalf("nan bound = %#v, error = %v", auditIndexValues(none), err)
	}
}

func TestAuditWindowAcceptsBoolAndComparesLargeIntegersExactly(t *testing.T) {
	got, err := auditWindow(auditWindowArguments(
		opList(opBool(false), opBool(true), auditFloatValue("9007199254740992")),
		opBool(false),
		opInt("9007199254740993"),
	))
	if err != nil || !reflect.DeepEqual(auditIndexValues(got), []string{"0", "1", "2"}) {
		t.Fatalf("window = %#v, error = %v", auditIndexValues(got), err)
	}

	got, err = auditWindow(auditWindowArguments(
		opList(auditFloatValue("9007199254740992")),
		opInt("9007199254740993"),
		auditNullValue(),
	))
	if err != nil || len(got.Items) != 0 {
		t.Fatalf("large lower bound = %#v, error = %v", auditIndexValues(got), err)
	}
}

func TestAuditSearchReturnsEachMatchingRowOnce(t *testing.T) {
	surrogate := string([]byte{0xed, 0xa0, 0x80})
	fields := opList(
		opList(opString("first"), opString("needle here"), opString("needle twice")),
		opList(opString("other")),
		opList(opString(surrogate+"needle")),
	)
	got, err := auditSearch(opDict(opField("fields", fields), opField("query", opString("needle"))))
	if err != nil || !reflect.DeepEqual(auditIndexValues(got), []string{"0", "2"}) {
		t.Fatalf("search = %#v, error = %v", auditIndexValues(got), err)
	}

	all, err := auditSearch(opDict(opField("fields", fields), opField("query", opString(""))))
	if err != nil || !reflect.DeepEqual(auditIndexValues(all), []string{"0", "1", "2"}) {
		t.Fatalf("empty search = %#v, error = %v", auditIndexValues(all), err)
	}
}

func TestAuditFilterCombinesOneImmutableWindowAndSearchEnvelope(t *testing.T) {
	got, err := auditFilter(opDict(
		opField("epochs", opList(
			auditFloatValue("0"),
			auditFloatValue("1"),
			auditFloatValue("2"),
			auditFloatValue("NaN"),
		)),
		opField("fields", opList(
			opList(opString("needle")),
			opList(opString("other")),
			opList(opString("needle")),
			opList(opString("needle")),
		)),
		opField("from", auditFloatValue("1")),
		opField("to", auditFloatValue("3")),
		opField("query", opString("needle")),
	))
	if err != nil || !reflect.DeepEqual(auditIndexValues(got), []string{"2", "3"}) {
		t.Fatalf("filter = %#v, error = %v", auditIndexValues(got), err)
	}

	_, err = auditFilter(opDict(
		opField("epochs", opList(auditFloatValue("1"))),
		opField("fields", opList()),
		opField("from", auditNullValue()),
		opField("to", auditNullValue()),
		opField("query", opString("")),
	))
	if err == nil {
		t.Fatal("mismatched envelope lengths accepted")
	}
}

func TestAuditMergePreservesPythonDictAndStableSortPolicy(t *testing.T) {
	rows := opList(
		auditMergeTestRow("a", "1", false, "0"),
		auditMergeTestRow("b", "3", false, "1"),
		auditMergeTestRow("a", "2", false, "2"),
		auditMergeTestRow("", "8", false, "3"),
		auditMergeTestRow("a", "9", true, "4"),
		auditMergeTestRow("c", "3", true, "5"),
		auditMergeTestRow("", "4", true, "z"),
		auditMergeTestRow("log-z", "5", false, "7"),
	)
	got, err := auditMerge(opDict(opField("rows", rows)))
	if err != nil || !reflect.DeepEqual(auditIndexValues(got), []string{"6", "1", "5", "2"}) {
		t.Fatalf("merge = %#v, error = %v", auditIndexValues(got), err)
	}
}

func TestAuditMergeLaterSyntheticRowsOverwriteInFirstSlot(t *testing.T) {
	rows := opList(
		auditMergeTestRow("", "1", true, "same"),
		auditMergeTestRow("x", "2", true, "x"),
		auditMergeTestRow("", "3", true, "same"),
	)
	got, err := auditMerge(opDict(opField("rows", rows)))
	if err != nil || !reflect.DeepEqual(auditIndexValues(got), []string{"2", "1"}) {
		t.Fatalf("merge = %#v, error = %v", auditIndexValues(got), err)
	}
}

func auditMergeTestRow(id, ts string, control bool, synthetic string) *ConfigValue {
	return opDict(
		opField("id", opString(id)),
		opField("ts", opString(ts)),
		opField("control", opBool(control)),
		opField("synthetic", opString(synthetic)),
	)
}

func TestAuditQueryNormalizesBoundsAndCapsPythonCodepoints(t *testing.T) {
	surrogate := string([]byte{0xed, 0xa0, 0x80})
	query := strings.Repeat("é", 199) + surrogate + "tail"
	got, err := auditQuery(opDict(
		opField("from", auditFloatValue("NaN")),
		opField("to", auditFloatValue("+Inf")),
		opField("query", opString(query)),
	))
	if err != nil || len(got.Items) != 3 || got.Items[0].Kind != "null" || got.Items[1].Kind != "null" {
		t.Fatalf("query = %+v, error = %v", got, err)
	}
	want := strings.Repeat("é", 199) + surrogate
	if got.Items[2].Kind != "str" || got.Items[2].Text != want {
		t.Fatalf("query text bytes = %x", []byte(got.Items[2].Text))
	}

	empty, err := auditQuery(opDict(
		opField("from", auditFloatValue("-1.5")),
		opField("to", auditNullValue()),
		opField("query", opString("")),
	))
	if err != nil || empty.Items[0].Text != "-1.5" || empty.Items[1].Kind != "null" || empty.Items[2].Kind != "null" {
		t.Fatalf("empty query = %+v, error = %v", empty, err)
	}
}

func TestAuditQueryOperationsRejectInvalidPayloads(t *testing.T) {
	tests := []struct {
		name string
		call func() error
	}{
		{"window epochs", func() error {
			_, err := auditWindow(auditWindowArguments(opString("bad"), auditNullValue(), auditNullValue()))
			return err
		}},
		{"window member", func() error {
			_, err := auditWindow(auditWindowArguments(opList(opString("bad")), auditNullValue(), auditNullValue()))
			return err
		}},
		{"window bound", func() error {
			_, err := auditWindow(auditWindowArguments(opList(), opString("bad"), auditNullValue()))
			return err
		}},
		{"search rows", func() error {
			_, err := auditSearch(opDict(opField("fields", opList(opString("bad"))), opField("query", opString(""))))
			return err
		}},
		{"search field", func() error {
			_, err := auditSearch(opDict(opField("fields", opList(opList(opInt("1")))), opField("query", opString(""))))
			return err
		}},
		{"merge row", func() error { _, err := auditMerge(opDict(opField("rows", opList(opString("bad"))))); return err }},
		{"merge field", func() error {
			_, err := auditMerge(opDict(opField("rows", opList(auditMergeTestRow("x", "1", false, "0"), opDict()))))
			return err
		}},
		{"query bound", func() error {
			_, err := auditQuery(opDict(opField("from", opInt("1")), opField("to", auditNullValue()), opField("query", opString(""))))
			return err
		}},
		{"query text", func() error {
			_, err := auditQuery(opDict(opField("from", auditNullValue()), opField("to", auditNullValue()), opField("query", opInt("1"))))
			return err
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := test.call(); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}

func TestAuditQueryPoliciesHandleLargeBatches(t *testing.T) {
	const count = 20000
	epochs := make([]*ConfigValue, count)
	fields := make([]*ConfigValue, count)
	rows := make([]*ConfigValue, count)
	for index := 0; index < count; index++ {
		epochs[index] = auditFloatValue(strconv.Itoa(index))
		fields[index] = opList(opString("row"))
		rows[index] = auditMergeTestRow(strconv.Itoa(index), strconv.Itoa(index), false, "")
	}
	window, windowErr := auditWindow(auditWindowArguments(opList(epochs...), auditFloatValue("100"), auditFloatValue("19900")))
	search, searchErr := auditSearch(opDict(opField("fields", opList(fields...)), opField("query", opString("row"))))
	filtered, filterErr := auditFilter(opDict(
		opField("epochs", opList(epochs...)),
		opField("fields", opList(fields...)),
		opField("from", auditFloatValue("100")),
		opField("to", auditFloatValue("19900")),
		opField("query", opString("row")),
	))
	merged, mergeErr := auditMerge(opDict(opField("rows", opList(rows...))))
	if windowErr != nil || searchErr != nil || filterErr != nil || mergeErr != nil {
		t.Fatalf("errors: window=%v search=%v filter=%v merge=%v", windowErr, searchErr, filterErr, mergeErr)
	}
	if len(window.Items) != 19800 || len(search.Items) != count || len(filtered.Items) != 19800 || len(merged.Items) != count {
		t.Fatalf("lengths: window=%d search=%d filter=%d merge=%d", len(window.Items), len(search.Items), len(filtered.Items), len(merged.Items))
	}
	if merged.Items[0].Text != "9999" {
		t.Fatalf("lexical first index = %s", merged.Items[0].Text)
	}
}

func TestAuditQueryProtocolDispatch(t *testing.T) {
	operations := map[string]*ConfigValue{
		"audit-filter": opDict(
			opField("epochs", opList()),
			opField("fields", opList()),
			opField("from", auditNullValue()),
			opField("to", auditNullValue()),
			opField("query", opString("")),
		),
		"audit-merge": opDict(opField("rows", opList())),
		"audit-query": opDict(
			opField("from", auditNullValue()),
			opField("to", auditNullValue()),
			opField("query", opString("")),
		),
	}
	for operation, config := range operations {
		t.Run(operation, func(t *testing.T) {
			if _, err := handleConfigRequest(ConfigRequest{Operation: operation, Config: config}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestAuditNumberCompareInfinitySigns(t *testing.T) {
	for _, test := range []struct {
		left  string
		right *ConfigValue
		want  int
	}{
		{"+Inf", auditFloatValue("+Inf"), 0},
		{"+Inf", opInt("999999999999999999999999999999"), 1},
		{"-Inf", opInt("-999999999999999999999999999999"), -1},
		{"0", auditFloatValue("+Inf"), -1},
		{"0", auditFloatValue("-Inf"), 1},
	} {
		got, comparable := auditNumberCompare(auditFloatValue(test.left), test.right)
		if !comparable || got != test.want {
			t.Fatalf("compare %s to %+v = %d, %v", test.left, test.right, got, comparable)
		}
	}
	if _, comparable := auditNumberCompare(auditFloatValue("NaN"), opInt("0")); comparable {
		t.Fatal("NaN was comparable")
	}
}
