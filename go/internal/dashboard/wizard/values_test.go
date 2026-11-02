package wizard

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestTariValueUsesFirstMatchingDiskAndPythonEquality(t *testing.T) {
	request := ValuesRequest{
		Disks: opList(
			opDict(opField("name", opInt("1")), opField("state", opString("empty"))),
			opDict(opField("name", opBool(true)), opField("state", opString("pithead-with-data"))),
		),
		Target: opBool(true),
		Wipe:   opString("data"),
	}
	result, err := tariValue(request)
	if err != nil || !result.NeedDefault || result.Value != nil {
		t.Fatalf("result=%+v error=%v", result, err)
	}
	request.Disks = opList(opDict(opField("name", opInt("1")), opField("state", opString("pithead-with-data"))))
	result, err = tariValue(request)
	if err != nil || result.Value == nil || result.Value.Text != "local" {
		t.Fatalf("result=%+v error=%v", result, err)
	}
}

func TestTariValueReadsBudgetOnlyWithoutDisksAndRequiresTrue(t *testing.T) {
	request := ValuesRequest{Disks: opList(opDict(opField("name", opString("other")))), Target: opString("target")}
	result, err := tariValue(request)
	if err != nil || !result.NeedDefault {
		t.Fatalf("result=%+v error=%v", result, err)
	}
	request.Disks = opList()
	request.Budget = opDict(opField("tari_chain_held", opInt("1")))
	result, err = tariValue(request)
	if err != nil || !result.NeedDefault {
		t.Fatalf("numeric true result=%+v error=%v", result, err)
	}
	request.Budget = opDict(opField("tari_chain_held", opBool(true)))
	result, err = tariValue(request)
	if err != nil || result.Value == nil || result.Value.Text != "local" {
		t.Fatalf("strict true result=%+v error=%v", result, err)
	}
}

func TestTariValueStopsBeforeLaterMalformedDisk(t *testing.T) {
	request := ValuesRequest{
		Disks:  opList(opDict(opField("name", opString("target"))), opDict()),
		Target: opString("target"),
		Wipe:   opString("keep"),
	}
	if result, err := tariValue(request); err != nil || !result.NeedDefault {
		t.Fatalf("result=%+v error=%v", result, err)
	}
	request.Target = opString("missing")
	if _, err := tariValue(request); err == nil {
		t.Fatal("missing disk name was accepted")
	}
}

func TestAnswersValueMergesTariModeWithoutReordering(t *testing.T) {
	base := opDict(opField("first", opInt("1")), opField("tari", opDict(opField("wallet", opString("key")))))
	result := answersValue(base, opString("off"))
	if keys := opKeys(result); !reflect.DeepEqual(keys, []string{"first", "tari"}) {
		t.Fatalf("keys=%v", keys)
	}
	tari, _ := result.Field("tari")
	if keys := opKeys(tari); !reflect.DeepEqual(keys, []string{"wallet", "mode"}) {
		t.Fatalf("tari keys=%v", keys)
	}
}

func TestExplicitValueReportsAliasesPathsOrderAndNaN(t *testing.T) {
	nan := &ConfigValue{Kind: "float", Text: "nan", Identity: 7}
	config := opDict(
		opField("same", opBool(true)),
		opField("list", opList(opInt("1"))),
		opField("nested", opDict(opField("same", opString("x")), opField("keep", opString("y")))),
		opField("nan", nan),
		opField("_private", opString("secret")),
	)
	reference := opDict(
		opField("same", opInt("1")),
		opField("list", opList()),
		opField("nested", opDict(opField("same", opString("x")))),
		opField("nan", nan.Clone()),
	)
	result, err := explicitValue(config, reference, []string{"nested.keep", "nested.same", "missing.key"})
	if err != nil {
		t.Fatal(err)
	}
	if keys := opKeys(result.Value); !reflect.DeepEqual(keys, []string{"list", "nested", "nan"}) {
		t.Fatalf("value keys=%v", keys)
	}
	wantAliases := [][]string{{"list"}, {"nested", "keep"}, {"nan"}}
	if !reflect.DeepEqual(result.Aliases, wantAliases) {
		t.Fatalf("aliases=%v", result.Aliases)
	}
	if !reflect.DeepEqual(result.Paths, [][]string{{"nested", "keep"}, {"nested", "same"}}) {
		t.Fatalf("paths=%v", result.Paths)
	}
	if result.Same {
		t.Fatal("truthy reference reported same")
	}
}

func TestExplicitValueFalseReferenceAndBadPaths(t *testing.T) {
	config := opDict(opField("value", opString("kept")), opField("nested", opDict(opField("chosen", opBool(true)))))
	result, err := explicitValue(config, opDict(), []string{"nested.chosen"})
	if err != nil || !result.Same || result.Value != config {
		t.Fatalf("result=%+v error=%v", result, err)
	}
	if !reflect.DeepEqual(result.Paths, [][]string{{"nested", "chosen"}}) {
		t.Fatalf("paths=%v", result.Paths)
	}
	if _, err := explicitValue(config, opDict(), []string{"malformed"}); err == nil || err.Error() != "not enough values to unpack (expected 2, got 1)" {
		t.Fatalf("false reference malformed path error=%v", err)
	}
	reference := opDict(opField("value", opString("default")))
	for path, message := range map[string]string{
		"one":       "not enough values to unpack (expected 2, got 1)",
		"one.two.3": "too many values to unpack (expected 2)",
	} {
		_, err := explicitValue(config, reference, []string{path})
		if err == nil || err.Error() != message {
			t.Fatalf("path=%q error=%v", path, err)
		}
	}
}

func TestRememberValueNormalizesAndUsesPythonStableUniqueness(t *testing.T) {
	nan := &ConfigValue{Kind: "float", Text: "nan", Identity: 12}
	previous := opList(opString("discard"), opInt("2"))
	changes := opList(opBool(true), opInt("1"), nan, nan.Clone(), opString("last"))
	result, err := rememberValue(previous, changes)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 3 || result.Items[0].Kind != "bool" || result.Items[1].Identity != 12 || result.Items[2].Text != "last" {
		t.Fatalf("items=%#v", result.Items)
	}
	_, err = rememberValue(opList(), opList(opDict()))
	var typeError configTypeError
	if !errors.As(err, &typeError) || err.Error() != "unhashable type: 'dict'" {
		t.Fatalf("error=%v", err)
	}
}

func TestInventoryValueSkipsShortRowsAndAddsCapacities(t *testing.T) {
	rows := []InventoryRow{
		{Parts: []*ConfigValue{opString("short")}},
		{
			Parts:      []*ConfigValue{opString("disk"), opString("1T"), opString("model"), opString("serial"), opString("state"), opString("extra")},
			Capacities: []InventoryCapacity{{Digit: true, Integer: "100000000000000000000"}, {Digit: false}},
		},
	}
	result, err := inventoryValue(rows)
	if err != nil || len(result.Items) != 1 {
		t.Fatalf("result=%#v error=%v", result, err)
	}
	if keys := opKeys(result.Items[0]); !reflect.DeepEqual(keys, []string{"name", "size", "model", "serial", "state", "data_bytes"}) {
		t.Fatalf("keys=%v", keys)
	}
	value, _ := result.Items[0].Field("data_bytes")
	if value.Kind != "int" || value.Text != "100000000000000000000" {
		t.Fatalf("capacity=%#v", value)
	}
	_, err = inventoryValue([]InventoryRow{{
		Parts:      rows[1].Parts,
		Capacities: []InventoryCapacity{{Digit: true, Error: "invalid literal for int()"}},
	}})
	if err == nil || err.Error() != "invalid literal for int()" {
		t.Fatalf("error=%v", err)
	}
}

type valuesRecordingIO struct {
	paths []string
	fail  string
}

func (r *valuesRecordingIO) Replace(string, string) error { return nil }

func (r *valuesRecordingIO) Unlink(path string) error {
	r.paths = append(r.paths, filepath.Base(path))
	if filepath.Base(path) == r.fail {
		return syscall.EACCES
	}
	return syscall.Unlink(path)
}

func TestRemoveSpoolValuesSkipsBrokenLinksAndStopsAtFirstError(t *testing.T) {
	spool := t.TempDir()
	if err := os.Symlink("missing", filepath.Join(spool, "broken")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"first", "blocked", "later"} {
		if err := os.WriteFile(filepath.Join(spool, name), []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	io := &valuesRecordingIO{fail: "blocked"}
	err := removeSpoolValues(spool, []string{"broken", "first", "blocked", "later"}, io)
	if !errors.Is(err, syscall.EACCES) || !reflect.DeepEqual(io.paths, []string{"first", "blocked"}) {
		t.Fatalf("paths=%v error=%v", io.paths, err)
	}
	if _, err := os.Stat(filepath.Join(spool, "first")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("first error=%v", err)
	}
	if _, err := os.Stat(filepath.Join(spool, "later")); err != nil {
		t.Fatalf("later error=%v", err)
	}
}

func TestRunValuesProtocolAndUnlinkCallback(t *testing.T) {
	spool := t.TempDir()
	path := filepath.Join(spool, "marker")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	request := ValuesRequest{Operation: "remove-spool", Spool: spool, Names: []string{"marker"}, IOHooks: map[string]bool{"unlink": true}}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	input := bytes.NewBuffer(append(append(encoded, '\n'), []byte("{\"ok\":true}\nnot-json\n")...))
	var output bytes.Buffer
	if err := RunValues(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 3 || !strings.Contains(lines[0], `"event":"unlink"`) {
		t.Fatalf("output=%q", output.String())
	}
	first := decodeConfigResponse(t, lines[1])
	malformed := decodeConfigResponse(t, lines[2])
	if !first.OK || malformed.OK || malformed.Error == nil {
		t.Fatalf("responses=%+v %+v", first, malformed)
	}
}

func TestRemoveSpoolValuesNormalizesCallbackOSErrorMessage(t *testing.T) {
	spool := t.TempDir()
	if err := os.WriteFile(filepath.Join(spool, "marker"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	io := &valuesCallbackErrorIO{}
	err := removeSpoolValues(spool, []string{"marker"}, io)
	var callback callbackError
	if !errors.As(err, &callback) || callback.errno != syscall.EIO || callback.Error() != "fixture unlink failure" {
		t.Fatalf("error=%v", err)
	}
}

type valuesCallbackErrorIO struct{}

func (*valuesCallbackErrorIO) Replace(string, string) error { return nil }

func (*valuesCallbackErrorIO) Unlink(string) error {
	return callbackError{message: "[Errno 5] fixture unlink failure", errno: syscall.EIO}
}
