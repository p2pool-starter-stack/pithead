package wizard

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestBuildConfigPlanDefaultAndOptionalBranches(t *testing.T) {
	request := formRequest(map[string]any{
		"machine_name":       " chosen ",
		"monero_wallet":      "monero-wallet",
		"monero_mode":        "remote",
		"monero_remote_host": "node.example.com",
		"monero_remote_rpc":  "18081",
		"monero_remote_zmq":  "18083",
		"monero_remote_auth": "on",
		"monero_remote_user": " reader ",
		"monero_remote_pass": " secret ",
		"pool":               "mini",
		"stratum_password":   "true",
		"tari_mode":          "remote",
		"tari_wallet":        "tari-wallet",
		"tari_remote_host":   "tari.example.com",
		"tari_remote_grpc":   "18142",
		"prune":              "false",
		"healthchecks_url":   " https://hc.example.com/ping ",
		"telegram_token":     " token ",
		"telegram_chat":      " chat ",
		"role":               "pithead",
		"local_miner":        "ON",
		"clearnet_sync":      "true",
		"timezone":           " Europe/Berlin ",
	})
	plan, err := BuildConfigPlan(request)
	if err != nil {
		t.Fatal(err)
	}
	password := pairValue(t, plan, "p2pool", "stratum_password").(string)
	if !regexp.MustCompile(`^[0-9a-f]{24}$`).MatchString(password) {
		t.Fatalf("password is not a 12-byte lowercase hex value: %q", password)
	}
	want := []FormOperation{
		set([]string{"dashboard", "host"}, "chosen"),
		set([]string{"monero", "wallet_address"}, "monero-wallet"),
		set([]string{"monero", "mode"}, "remote"),
		pairs([]string{"p2pool"}, [2]any{"pool", "mini"}, [2]any{"stratum_password", password}),
		set([]string{"tari", "mode"}, "remote"),
		set([]string{"tari", "wallet_address"}, "tari-wallet"),
		set([]string{"monero", "mode"}, "remote"),
		pairs([]string{"monero", "remote"}, [2]any{"host", "node.example.com"}, [2]any{"rpc_port", json.Number("18081")}, [2]any{"zmq_port", json.Number("18083")}),
		set([]string{"monero", "node_username"}, "reader"),
		set([]string{"monero", "node_password"}, "secret"),
		pairs([]string{"tari", "remote"}, [2]any{"host", "tari.example.com"}, [2]any{"grpc_port", json.Number("18142")}),
		pairs([]string{"healthchecks"}, [2]any{"ping_url", "https://hc.example.com/ping"}),
		pairs([]string{"telegram"}, [2]any{"enabled", true}, [2]any{"bot_token", "token"}, [2]any{"chat_id", "chat"}),
		set([]string{"local_miner", "enabled"}, false),
		set([]string{"local_miner", "enabled"}, true),
		set([]string{"monero", "clearnet_initial_sync"}, false),
		set([]string{"tari", "clearnet_initial_sync"}, false),
		set([]string{"dashboard", "timezone"}, "Europe/Berlin"),
	}
	assertJSONEqual(t, plan, want)
}

func TestBuildConfigPlanUsesDefaultsAndTariOverride(t *testing.T) {
	request := formRequest(map[string]any{"role": "both", "prune": "false", "clearnet_sync": "true"})
	request.TariDefault = "local"
	plan, err := BuildConfigPlan(request)
	if err != nil {
		t.Fatal(err)
	}
	assertOperation(t, plan, []string{"dashboard", "host"}, "pithead")
	assertOperation(t, plan, []string{"monero", "mode"}, "local")
	assertOperation(t, plan, []string{"tari", "mode"}, "local")
	assertOperation(t, plan, []string{"tari", "wallet_address"}, "")
	assertOperation(t, plan, []string{"monero", "prune"}, false)
	assertOperation(t, plan, []string{"local_miner", "enabled"}, true)
	assertOperation(t, plan, []string{"monero", "clearnet_initial_sync"}, true)
	assertOperation(t, plan, []string{"tari", "clearnet_initial_sync"}, true)
}

func TestBuildConfigPlanExactRawChecks(t *testing.T) {
	request := formRequest(nil)
	remoteText := request.Fields["monero_mode"]
	remoteText.Text = "remote"
	remoteText.RawString = nil
	request.Fields["monero_mode"] = remoteText
	request.Fields["prune"] = input("false")
	plan, err := BuildConfigPlan(request)
	if err != nil {
		t.Fatal(err)
	}
	for _, operation := range plan {
		if strings.Join(operation.Path, ".") == "monero.remote" {
			t.Fatalf("unexpected exact-raw branch: %#v", operation)
		}
	}
	assertOperation(t, plan, []string{"monero", "prune"}, false)
	if password := pairValue(t, plan, "p2pool", "stratum_password"); password != "" {
		t.Fatalf("default password = %#v, want empty", password)
	}
}

func TestBuildConfigPlanPortFallbackAndDeferredIntegerError(t *testing.T) {
	request := formRequest(map[string]any{"monero_mode": "local", "monero_remote_rpc": "²"})
	bad := request.Fields["monero_remote_rpc"]
	bad.Digit = true
	bad.Integer = nil
	bad.IntegerError = "invalid literal for int() with base 10: '²'"
	request.Fields["monero_remote_rpc"] = bad
	if _, err := BuildConfigPlan(request); err != nil {
		t.Fatalf("inactive remote port raised: %v", err)
	}
	request.Fields["monero_mode"] = input("remote")
	_, err := BuildConfigPlan(request)
	if err == nil || err.Error() != "invalid literal for int() with base 10: '²'" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBuildConfigPlanGeneratesPassword(t *testing.T) {
	request := formRequest(map[string]any{"stratum_password": "true"})
	first, err := BuildConfigPlan(request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildConfigPlan(request)
	if err != nil {
		t.Fatal(err)
	}
	one := pairValue(t, first, "p2pool", "stratum_password").(string)
	two := pairValue(t, second, "p2pool", "stratum_password").(string)
	if !regexp.MustCompile(`^[0-9a-f]{24}$`).MatchString(one) || one == two {
		t.Fatalf("passwords were not independent 12-byte hex values: %q %q", one, two)
	}
}

func TestValidateInstallRequest(t *testing.T) {
	disks := []map[string]any{{"name": "disk-a", "state": "pithead-with-data"}, {"name": "disk-b", "state": "empty"}}
	request, err := ValidateInstallRequest(fields(map[string]any{"disk": "disk-a", "confirm": "disk-a", "wipe": "all"}), disks)
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, request, map[string]any{"disk": "disk-a", "wipe": "all"})
	request, err = ValidateInstallRequest(fields(map[string]any{"disk": "disk-b", "confirm": "disk-b", "wipe": "data"}), disks)
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, request, map[string]any{"disk": "disk-b", "wipe": "keep"})
	for name, test := range map[string]struct {
		form    map[string]any
		message string
	}{
		"unknown disk": {form: map[string]any{"disk": "missing", "confirm": "missing"}, message: "choose a disk from the list"},
		"confirmation": {form: map[string]any{"disk": "disk-a", "confirm": "disk-b"}, message: "type disk-a exactly to confirm"},
		"wipe":         {form: map[string]any{"disk": "disk-a", "confirm": "disk-a", "wipe": "invalid"}, message: "unknown wipe mode"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := ValidateInstallRequest(fields(test.form), disks)
			if err == nil || err.Error() != test.message {
				t.Fatalf("got %v, want %q", err, test.message)
			}
		})
	}
}

func TestRunFormJSONLines(t *testing.T) {
	request := formRequest(map[string]any{"disk": "disk-a", "confirm": "wrong"})
	request.Operation = "install"
	request.Disks = []map[string]any{{"name": "disk-a", "state": "empty"}}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := RunForm(bytes.NewReader(append(encoded, '\n')), &output); err != nil {
		t.Fatal(err)
	}
	var response struct {
		OK    bool   `json:"ok"`
		Error *Error `json:"error"`
	}
	if err := json.Unmarshal(output.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.OK || response.Error == nil || response.Error.Kind != "ValueError" || response.Error.Message != "type disk-a exactly to confirm" {
		t.Fatalf("unexpected response: %s", output.String())
	}
}

func TestRunFormReportsInventoryKeyErrors(t *testing.T) {
	request := formRequest(map[string]any{"disk": "disk-a", "confirm": "disk-a", "wipe": "all"})
	request.Operation = "install"
	for _, test := range []struct {
		disks   []map[string]any
		message string
	}{
		{[]map[string]any{{"state": "empty"}}, "'name'"},
		{[]map[string]any{{"name": "disk-a"}}, "'state'"},
	} {
		request.Disks = test.disks
		encoded, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		if err := RunForm(bytes.NewReader(append(encoded, '\n')), &output); err != nil {
			t.Fatal(err)
		}
		var response struct {
			Error *Error `json:"error"`
		}
		if err := json.Unmarshal(output.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.Error == nil || response.Error.Kind != "KeyError" || response.Error.Message != test.message {
			t.Fatalf("unexpected response: %s", output.String())
		}
	}
}

func formRequest(values map[string]any) FormRequest {
	return FormRequest{
		Operation: "build",
		Defaults: map[string]any{
			"dashboard.host":          "pithead",
			"dashboard.timezone":      "auto",
			"monero.mode":             "local",
			"monero.remote.rpc_port":  18081,
			"monero.remote.zmq_port":  18083,
			"p2pool.pool":             "mini",
			"p2pool.stratum_password": "",
			"tari.mode":               "off",
			"tari.remote.grpc_port":   18142,
		},
		Fields: fields(values),
	}
}

func fields(values map[string]any) map[string]Field {
	result := map[string]Field{}
	for name, value := range values {
		result[name] = input(value)
	}
	return result
}

func input(value any) Field {
	if value == nil {
		return Field{Text: "None", Present: true, Lower: "none"}
	}
	text, ok := value.(string)
	if !ok {
		text = ""
	}
	trimmed := strings.TrimSpace(text)
	field := Field{Text: trimmed, Present: true, Truth: text != "", Lower: strings.ToLower(text)}
	if raw, ok := value.(string); ok {
		field.RawString = &raw
	}
	if text != "" && strings.IndexFunc(text, func(r rune) bool { return r < '0' || r > '9' }) == -1 {
		field.Digit = true
		field.Integer = json.RawMessage(text)
	}
	return field
}

func assertOperation(t *testing.T, operations []FormOperation, path []string, value any) {
	t.Helper()
	for _, operation := range operations {
		if strings.Join(operation.Path, ".") == strings.Join(path, ".") && operation.Pairs == nil {
			if encoded, _ := json.Marshal(operation.Value); string(encoded) == mustJSON(value) {
				return
			}
		}
	}
	t.Fatalf("missing operation %v=%#v in %#v", path, value, operations)
}

func pairValue(t *testing.T, operations []FormOperation, path, key string) any {
	t.Helper()
	for _, operation := range operations {
		if strings.Join(operation.Path, ".") == path {
			for _, pair := range operation.Pairs {
				if pair[0] == key {
					return pair[1]
				}
			}
		}
	}
	t.Fatalf("missing pair %s.%s", path, key)
	return nil
}

func assertJSONEqual(t *testing.T, got, want any) {
	t.Helper()
	if mustJSON(got) != mustJSON(want) {
		t.Fatalf("got %s\nwant %s", mustJSON(got), mustJSON(want))
	}
}

func mustJSON(value any) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}
