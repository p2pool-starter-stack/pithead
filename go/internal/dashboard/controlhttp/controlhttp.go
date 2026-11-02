package controlhttp

import "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"

type Request struct {
	Operation string              `json:"operation"`
	Route     string              `json:"route"`
	Value     *wizard.ConfigValue `json:"value"`
	ID        *wizard.ConfigValue `json:"id"`
	Worker    *wizard.ConfigValue `json:"worker"`
	Version   *wizard.ConfigValue `json:"version"`
	MaxDigits *wizard.ConfigValue `json:"max_digits"`
	Error     string              `json:"error"`
}

type Result struct {
	Status int                 `json:"status,omitempty"`
	Text   *wizard.ConfigValue `json:"text,omitempty"`
	Body   *wizard.ConfigValue `json:"body,omitempty"`
	Value  *wizard.ConfigValue `json:"value,omitempty"`
	Next   string              `json:"next,omitempty"`
	Action string              `json:"action,omitempty"`
	Done   bool                `json:"done"`
}

func Handle(request Request) (Result, error) {
	switch request.Operation {
	case "header":
		if !isString(request.Value, "1") {
			return textResult(403, "Missing X-Pithead-Control header."), nil
		}
		return Result{Next: "ready"}, nil
	case "request-body":
		if request.Value == nil || request.Value.Kind != "dict" {
			return textResult(400, "Body must be a JSON object."), nil
		}
		if _, ok := request.Value.Field("config"); ok {
			return Result{Next: "placeholders"}, nil
		}
		return Result{Next: "ready"}, nil
	case "proposed":
		if request.Value == nil || request.Value.Kind != "dict" {
			return textResult(400, "'config' must be a JSON object."), nil
		}
		return Result{Next: "ready"}, nil
	case "approval":
		return approval(request.Value)
	case "version":
		return version(request.Route, request.Version), nil
	case "os-action":
		return osAction(request.Value)
	case "request":
		return Result{Action: request.Route, Next: "submit"}, nil
	case "validation":
		if request.Value.PythonTruth() {
			return Result{Status: 400, Text: request.Value.Clone()}, nil
		}
		next := "ready"
		if request.Route == "fleet" {
			next = "existing"
		}
		return Result{Next: next}, nil
	case "complete":
		return complete(request.Route, request.Value, request.ID)
	case "done":
		return Result{Done: !isString(request.Value, "previewed")}, nil
	case "error":
		return errorResult(request.Error, request.Route, request.Value), nil
	case "worker-name":
		return workerName(request.Value), nil
	case "worker-detail-name":
		return workerDetailName(request.Value), nil
	case "worker-live":
		return workerLive(request.Value, request.Worker)
	case "worker-noop":
		return workerNoop(request.Value, request.Worker, request.Version, request.MaxDigits)
	case "worker-done":
		return Result{Done: !isString(request.Value, "running")}, nil
	case "worker-record":
		return workerRecord(request.Value)
	case "worker-strip":
		return Result{Value: stripWorkerCredentials(request.Value, 0), Next: "ready"}, nil
	default:
		return Result{}, valueError("unsupported control HTTP operation: " + request.Operation)
	}
}

func approval(body *wizard.ConfigValue) (Result, error) {
	approve, _ := body.Field("approve")
	if approve == nil || approve.Kind != "bool" || !approve.Bool {
		return Result{Value: nullValue()}, nil
	}
	suffixes, ok := body.Field("payout_suffixes")
	if !ok {
		suffixes = dictValue()
	}
	if suffixes.Kind != "dict" {
		return Result{}, valueError("invalid payout confirmation")
	}
	for _, field := range suffixes.Fields {
		if (field.Key != "monero" && field.Key != "tari") || field.Value.Kind != "str" {
			return Result{}, valueError("invalid payout confirmation")
		}
	}
	return Result{Value: &wizard.ConfigValue{Kind: "dict", Fields: []wizard.ConfigField{{
		Key: "payout_suffixes", Value: suffixes.Clone(),
	}}}, Next: "approval"}, nil
}

func version(route string, value *wizard.ConfigValue) Result {
	if route == "os-update" && (value == nil || value.Kind == "null") {
		return Result{Next: "ready"}
	}
	if value == nil || value.Kind != "str" || !validVersion(value.Text) {
		return textResult(400, "'version' must look like vX.Y.Z.")
	}
	return Result{Next: "ready"}
}

func validVersion(value string) bool {
	runes := []rune(value)
	if len(runes) < 6 || runes[0] != 'v' {
		return false
	}
	index := 1
	for part := 0; part < 3; part++ {
		start := index
		for index < len(runes) && unicodeDigit(runes[index]) {
			index++
		}
		if index == start {
			return false
		}
		if part < 2 {
			if index >= len(runes) || runes[index] != '.' {
				return false
			}
			index++
		}
	}
	return index == len(runes)
}

func osAction(value *wizard.ConfigValue) (Result, error) {
	if value != nil && (value.Kind == "list" || value.Kind == "dict") {
		return Result{}, typeError("unhashable type: '" + value.Kind + "'")
	}
	if value != nil && value.Kind == "str" {
		switch value.Text {
		case "check", "download", "verify", "install", "reboot":
			return Result{Action: "os-" + value.Text, Next: "ready"}, nil
		}
	}
	return textResult(400, "'action' must be one of: check, download, install, reboot, verify"), nil
}

func complete(route string, result, id *wizard.ConfigValue) (Result, error) {
	if route == "result" {
		if result == nil || result.Kind == "null" {
			return Result{Status: 202, Body: statusBody()}, nil
		}
		return Result{Status: 200, Body: result.Clone()}, nil
	}
	if route == "config" || route == "worker-detail" {
		return Result{Status: 200, Body: result.Clone()}, nil
	}
	if route == "upgrade" || route == "backup" || route == "os-update" || route == "worker-upgrade" {
		return Result{Status: 202, Body: pendingBody(id)}, nil
	}
	if route == "preview" || route == "commit" || route == "worker-apply" {
		if result == nil || result.Kind == "null" {
			return Result{Status: 202, Body: pendingBody(id)}, nil
		}
		if result.Kind != "dict" {
			return Result{}, typeError("'" + result.Kind + "' object is not a mapping")
		}
		body := &wizard.ConfigValue{Kind: "dict", Fields: []wizard.ConfigField{{Key: "id", Value: id.Clone()}}}
		for _, field := range result.Fields {
			body.Set(field.Key, field.Value.Clone())
		}
		return Result{Status: 200, Body: body}, nil
	}
	return Result{}, valueError("unsupported control HTTP route: " + route)
}

func errorResult(kind, route string, message *wizard.ConfigValue) Result {
	switch kind {
	case "json":
		return textResult(400, "Body must be JSON.")
	case "intent":
		return textResult(400, "Body must be JSON with a valid intent 'id'.")
	case "uuid":
		return textResult(400, "'id' must be a UUID.")
	case "document":
		return textResult(400, valueText(message))
	case "config-host":
		return Result{Status: 500, Body: errorBody("Invalid configuration: " + valueText(message))}
	case "config-read":
		return Result{Status: 500, Body: errorBody("Failed to read the stack config.")}
	case "worker-detail":
		return Result{Status: 500, Body: errorBody("Failed to build worker detail.")}
	case "submit":
		messages := map[string]string{
			"preview":        "Failed to submit the preview request.",
			"upgrade":        "Failed to submit the upgrade request.",
			"os-update":      "Failed to submit the OS-update request.",
			"backup":         "Failed to submit the backup request.",
			"worker-apply":   "Failed to submit the worker config change.",
			"worker-upgrade": "Failed to submit the worker upgrade.",
		}
		return Result{Status: 500, Body: errorBody(messages[route])}
	default:
		return Result{Status: 500, Body: errorBody(valueText(message))}
	}
}
