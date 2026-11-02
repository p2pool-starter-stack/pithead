package controlhttp

import (
	"errors"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"
)

func cvList(values ...*wizard.ConfigValue) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "list", Items: values}
}

func cvInt(value string) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "int", Text: value}
}

func field(key string, value *wizard.ConfigValue) wizard.ConfigField {
	return wizard.ConfigField{Key: key, Value: value}
}

func TestWorkerNamePolicies(t *testing.T) {
	for _, value := range []*wizard.ConfigValue{nil, cvString(""), cvList(cvString("rig"))} {
		result, err := Handle(Request{Operation: "worker-name", Value: value})
		if err != nil || result.Status != 400 {
			t.Fatalf("worker name %#v = %#v, %v", value, result, err)
		}
	}
	result, err := Handle(Request{Operation: "worker-name", Value: cvString("rig")})
	if err != nil || result.Next != "ready" {
		t.Fatalf("worker name = %#v, %v", result, err)
	}
	result, err = Handle(Request{Operation: "worker-detail-name", Value: cvList(cvString("rig"))})
	if err != nil || result.Next != "ready" {
		t.Fatalf("truthy detail name = %#v, %v", result, err)
	}
	result, err = Handle(Request{Operation: "worker-detail-name", Value: cvString("")})
	if err != nil || result.Status != 400 {
		t.Fatalf("empty detail name = %#v, %v", result, err)
	}
}

func TestWorkerLiveUsesFirstMatch(t *testing.T) {
	data := cvDict(field("workers", cvList(
		cvDict(field("name", cvString("rig")), field("rigforge", cvDict(field("version", cvString("1.2.3"))))),
		cvDict(field("name", cvString("rig")), field("rigforge", cvDict(field("version", cvString("9.9.9"))))),
	)))
	result, err := Handle(Request{Operation: "worker-live", Value: data, Worker: cvString("rig")})
	version, _ := result.Value.Field("version")
	if err != nil || result.Next != "ready" || version.Text != "1.2.3" {
		t.Fatalf("worker live = %#v, %v", result, err)
	}
	missing, err := Handle(Request{Operation: "worker-live", Value: data, Worker: cvString("missing")})
	if err != nil || missing.Value.Kind != "dict" || len(missing.Value.Fields) != 0 {
		t.Fatalf("missing worker = %#v, %v", missing, err)
	}
	for _, emptyWorkers := range []*wizard.ConfigValue{cvDict(), cvString("")} {
		empty, emptyErr := Handle(Request{
			Operation: "worker-live", Value: cvDict(field("workers", emptyWorkers)), Worker: cvString("rig"),
		})
		if emptyErr != nil || empty.Value.Kind != "dict" || len(empty.Value.Fields) != 0 {
			t.Fatalf("empty iterable workers = %#v, %v", empty, emptyErr)
		}
	}
	oddRigforge := cvDict(field("workers", cvList(cvDict(
		field("name", cvString("rig")), field("rigforge", cvList(cvString("unexpected"))),
	))))
	odd, err := Handle(Request{Operation: "worker-live", Value: oddRigforge, Worker: cvString("rig")})
	if err != nil || odd.Value.Kind != "list" || len(odd.Value.Items) != 1 {
		t.Fatalf("truthy rigforge shape = %#v, %v", odd, err)
	}
	_, err = Handle(Request{Operation: "worker-live", Value: cvDict(field("workers", cvDict())), Worker: cvString("rig")})
	if err != nil {
		t.Fatalf("empty worker mapping = %v", err)
	}
	_, err = Handle(Request{Operation: "worker-live", Value: cvDict(field("workers", cvDict(field("rig", cvDict())))), Worker: cvString("rig")})
	assertProtocolKind(t, err, "TypeError")
}

func TestWorkerNoopVersionParity(t *testing.T) {
	for _, running := range []string{"1.2.3", "  VV01.002.0003-alpha+build ", "\x1c1.2.3\x1f", "١.٢.٣", "𝟙.𝟚.𝟛"} {
		result, err := Handle(Request{
			Operation: "worker-noop", Value: cvString(running), Worker: cvString("rig"),
			Version: cvString("v1.2.3"), MaxDigits: cvInt("4300"),
		})
		if err != nil || result.Status != 200 || result.Body.Fields[0].Value.Text != "noop" || result.Body.Fields[1].Value.Text != "rig" {
			t.Fatalf("running %q = %#v, %v", running, result, err)
		}
	}
	result, err := Handle(Request{Operation: "worker-noop", Value: cvString("1.2"), MaxDigits: cvInt("4300")})
	if err != nil || result.Next != "ready" {
		t.Fatalf("unparsed running = %#v, %v", result, err)
	}
	_, err = Handle(Request{Operation: "worker-noop", Value: cvString("¹.2.3"), MaxDigits: cvInt("4300")})
	assertProtocolKind(t, err, "ValueError")
	result, err = Handle(Request{Operation: "worker-noop", Value: cvString("¹.x.3"), MaxDigits: cvInt("4300")})
	if err != nil || result.Next != "ready" {
		t.Fatalf("isdigit conversion ran before validation = %#v, %v", result, err)
	}
	_, err = Handle(Request{Operation: "worker-noop", Value: cvString("1111.2.3"), MaxDigits: cvInt("3")})
	assertProtocolKind(t, err, "ValueError")
	result, err = Handle(Request{Operation: "worker-noop", Value: cvString("1111.x.3"), MaxDigits: cvInt("3")})
	if err != nil || result.Next != "ready" {
		t.Fatalf("digit limit ran before validation = %#v, %v", result, err)
	}
	result, err = Handle(Request{Operation: "worker-noop", Value: cvString(""), MaxDigits: cvString("bad")})
	if err != nil || result.Next != "ready" {
		t.Fatalf("false running parsed eagerly = %#v, %v", result, err)
	}
	_, err = Handle(Request{Operation: "worker-noop", Value: cvDict(field("version", cvString("1.2.3")))})
	assertProtocolKind(t, err, "TypeError")
}

func TestWorkerDoneAndRecord(t *testing.T) {
	for _, status := range []string{"applied", "rejected", "rolled_back", "accepted", "failed", "noop", "throttled"} {
		value := cvDict(
			field("change_id", cvString("result-id")), field("status", cvString(status)),
			field("reason", cvString("")), field("error", cvString("fallback")),
		)
		result, err := Handle(Request{Operation: "worker-record", Value: value})
		if err != nil || result.Next != "record" || len(result.Value.Fields) != 3 || result.Value.Fields[0].Key != "change_id" || result.Value.Fields[2].Value.Text != "fallback" {
			t.Fatalf("record %q = %#v, %v", status, result, err)
		}
	}
	result, err := Handle(Request{Operation: "worker-record", Value: cvDict(field("status", cvString("running")))})
	if err != nil || result.Next != "ready" || result.Value != nil {
		t.Fatalf("running record = %#v, %v", result, err)
	}
	_, err = Handle(Request{Operation: "worker-record", Value: cvList()})
	assertProtocolKind(t, err, "TypeError")
	running, _ := Handle(Request{Operation: "worker-done", Value: cvString("running")})
	done, _ := Handle(Request{Operation: "worker-done", Value: cvString("failed")})
	if running.Done || !done.Done {
		t.Fatalf("done results = %#v, %#v", running, done)
	}
}

func TestStripWorkerCredentials(t *testing.T) {
	sentinel := cvDict(field("__secret__", cvBool(true)), field("kept", cvString("opaque")))
	notSentinel := cvDict(field("__secret__", cvInt("1")), field("nested", cvDict(field("pass", sentinel))))
	value := cvDict(field("pools", cvList(cvDict(
		field("pass", sentinel), field("tls-fingerprint", notSentinel),
		field("nested", cvDict(field("pass", sentinel))),
	))))
	result, err := Handle(Request{Operation: "worker-strip", Value: value})
	if err != nil || result.Next != "ready" {
		t.Fatalf("strip = %#v, %v", result, err)
	}
	pools, _ := result.Value.Field("pools")
	pool := pools.Items[0]
	if _, ok := pool.Field("pass"); ok {
		t.Fatal("top-level credential sentinel retained")
	}
	fingerprint, ok := pool.Field("tls-fingerprint")
	if !ok || !fingerprint.Equal(notSentinel) {
		t.Fatalf("credential leaf changed = %#v", fingerprint)
	}
	nested, _ := pool.Field("nested")
	if _, ok := nested.Field("pass"); ok {
		t.Fatal("nested credential sentinel retained")
	}
	deep := cvString("leaf")
	for index := 0; index < 7; index++ {
		deep = cvDict(field("child", deep))
	}
	stripped := stripWorkerCredentials(deep, 0)
	for index := 0; index < 7; index++ {
		stripped, _ = stripped.Field("child")
	}
	if stripped.Kind != "null" {
		t.Fatalf("depth result = %#v", stripped)
	}
}

func TestWorkerCompleteAndErrors(t *testing.T) {
	id := cvString("request-id")
	value := cvDict(field("id", cvString("result-id")), field("status", cvString("applied")))
	detail, err := Handle(Request{Operation: "complete", Route: "worker-detail", Value: value})
	if err != nil || detail.Status != 200 || !detail.Body.Equal(value) {
		t.Fatalf("detail complete = %#v, %v", detail, err)
	}
	result, err := Handle(Request{Operation: "complete", Route: "worker-apply", Value: value, ID: id})
	if err != nil || result.Status != 200 || result.Body.Fields[0].Key != "id" || result.Body.Fields[0].Value.Text != "result-id" {
		t.Fatalf("apply complete = %#v, %v", result, err)
	}
	pending, err := Handle(Request{Operation: "complete", Route: "worker-apply", Value: nullValue(), ID: id})
	if err != nil || pending.Status != 202 || pending.Body.Fields[1].Value.Text != "pending" {
		t.Fatalf("apply pending = %#v, %v", pending, err)
	}
	upgrade, err := Handle(Request{Operation: "complete", Route: "worker-upgrade", ID: id})
	if err != nil || upgrade.Status != 202 || upgrade.Body.Fields[0].Value.Text != "request-id" {
		t.Fatalf("upgrade complete = %#v, %v", upgrade, err)
	}
	for route, message := range map[string]string{
		"worker-apply":   "Failed to submit the worker config change.",
		"worker-upgrade": "Failed to submit the worker upgrade.",
	} {
		failed, err := Handle(Request{Operation: "error", Error: "submit", Route: route})
		body, _ := failed.Body.Field("error")
		if err != nil || failed.Status != 500 || body.Text != message {
			t.Fatalf("error %q = %#v, %v", route, failed, err)
		}
	}
	failedDetail, _ := Handle(Request{Operation: "error", Error: "worker-detail"})
	body, _ := failedDetail.Body.Field("error")
	if failedDetail.Status != 500 || body.Text != "Failed to build worker detail." {
		t.Fatalf("detail error = %#v", failedDetail)
	}
}

func assertProtocolKind(t *testing.T, err error, kind string) {
	t.Helper()
	var protocol protocolError
	if !errors.As(err, &protocol) || protocol.kind != kind || strings.TrimSpace(protocol.message) == "" {
		t.Fatalf("error = %#v, want %s", err, kind)
	}
}
