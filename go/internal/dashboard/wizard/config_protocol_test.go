package wizard

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

type configWireResponse struct {
	OK    bool            `json:"ok"`
	Value json.RawMessage `json:"value"`
	Error *Error          `json:"error"`
}

func TestRunConfigJSONLines(t *testing.T) {
	merge := ConfigRequest{
		Operation: "merge",
		Base:      opDict(opField("first", opInt("1"))),
		Over:      opDict(opField("second", opInt("2"))),
	}
	strip := ConfigRequest{
		Operation: "strip",
		Config:    opDict(opField("same", opBool(true)), opField("extra", opString("keep"))),
		Reference: opDict(opField("same", opInt("1"))),
	}
	var input bytes.Buffer
	for _, request := range []ConfigRequest{merge, strip} {
		encoded, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		input.Write(encoded)
		input.WriteByte('\n')
	}
	var output bytes.Buffer
	if err := RunConfig(&input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("responses = %d", len(lines))
	}
	first := decodeConfigResponse(t, lines[0])
	var merged ConfigValue
	if err := json.Unmarshal(first.Value, &merged); err != nil {
		t.Fatal(err)
	}
	if keys := opKeys(&merged); len(keys) != 2 || keys[0] != "first" || keys[1] != "second" {
		t.Fatalf("merged keys = %#v", keys)
	}
	second := decodeConfigResponse(t, lines[1])
	var stripped ConfigValue
	if err := json.Unmarshal(second.Value, &stripped); err != nil {
		t.Fatal(err)
	}
	if keys := opKeys(&stripped); len(keys) != 1 || keys[0] != "extra" {
		t.Fatalf("stripped keys = %#v", keys)
	}
}

func TestRunConfigPrepareAndName(t *testing.T) {
	prepare := ConfigRequest{
		Operation:      "prepare",
		Config:         opDict(opField("config_version", opString("1")), opField("known", opString("value"))),
		Reference:      opDict(opField("known", opString("default"))),
		LegacyDefaults: opDict(),
	}
	response := runConfigRequest(t, prepare)
	if !response.OK || response.Error != nil {
		t.Fatalf("prepare response = %#v", response)
	}
	var prepared struct {
		Config  *ConfigValue `json:"config"`
		Changes *ConfigValue `json:"changes"`
	}
	if err := json.Unmarshal(response.Value, &prepared); err != nil {
		t.Fatal(err)
	}
	if keys := opKeys(prepared.Config); len(keys) != 1 || keys[0] != "known" {
		t.Fatalf("prepared keys = %#v", keys)
	}

	name := ConfigRequest{
		Operation:   "name",
		Config:      opDict(opField("dashboard", opDict(opField("host", opString("bad.name"))))),
		Previous:    opDict(),
		DefaultHost: opString("auto"),
	}
	response = runConfigRequest(t, name)
	if response.OK || response.Error == nil || response.Error.Kind != "ValueError" {
		t.Fatalf("name response = %#v", response)
	}
}

func TestRunConfigRecoveryMapsKeyAndTypeErrors(t *testing.T) {
	valid := ConfigRequest{
		Operation: "recovery",
		Changes:   opDict(opField("changes", opList(opString("legacy removed")))),
		Attempt:   opDict(opField("disk", opString("disk-a")), opField("wipe", opString("all"))),
		Disks:     opList(opDict(opField("name", opString("disk-a")))),
		Mode:      opString("none"),
	}
	response := runConfigRequest(t, valid)
	if !response.OK || response.Error != nil {
		t.Fatalf("recovery response = %#v", response)
	}
	var recovered recoveryResult
	if err := json.Unmarshal(response.Value, &recovered); err != nil {
		t.Fatal(err)
	}
	if len(recovered.Remembered.Items) != 1 || recovered.Remembered.Items[0].Text != "legacy removed" || recovered.Mode != "none" || len(recovered.Attempt.Fields) != 2 {
		t.Fatalf("recovery value = %#v", recovered)
	}

	request := ConfigRequest{
		Operation: "recovery",
		Changes:   opDict(),
		Attempt:   opDict(),
		Disks:     opList(opDict()),
		Mode:      opString("auto"),
	}
	response = runConfigRequest(t, request)
	if response.OK || response.Error == nil || response.Error.Kind != "KeyError" || response.Error.Message != "name" {
		t.Fatalf("key response = %#v", response)
	}

	request.Disks = opList(opDict(opField("name", opList())))
	response = runConfigRequest(t, request)
	if response.OK || response.Error == nil || response.Error.Kind != "TypeError" || response.Error.Message != "unhashable type: 'list'" {
		t.Fatalf("type response = %#v", response)
	}
}

func TestRunConfigRejectsUnsupportedAndMalformedRequests(t *testing.T) {
	response := runConfigRequest(t, ConfigRequest{Operation: "unknown"})
	if response.OK || response.Error == nil || response.Error.Kind != "ValueError" {
		t.Fatalf("unsupported response = %#v", response)
	}
	var output bytes.Buffer
	if err := RunConfig(strings.NewReader("not-json\n"), &output); err != nil {
		t.Fatal(err)
	}
	response = decodeConfigResponse(t, strings.TrimSpace(output.String()))
	if response.OK || response.Error == nil {
		t.Fatalf("malformed response = %#v", response)
	}
}

func runConfigRequest(t *testing.T, request ConfigRequest) configWireResponse {
	t.Helper()
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := RunConfig(bytes.NewReader(append(encoded, '\n')), &output); err != nil {
		t.Fatal(err)
	}
	return decodeConfigResponse(t, strings.TrimSpace(output.String()))
}

func decodeConfigResponse(t *testing.T, line string) configWireResponse {
	t.Helper()
	var response configWireResponse
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		t.Fatal(err)
	}
	return response
}
