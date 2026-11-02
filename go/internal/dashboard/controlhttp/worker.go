package controlhttp

import "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"

var recordableWorkerStatuses = map[string]struct{}{
	"applied": {}, "rejected": {}, "rolled_back": {}, "accepted": {},
	"failed": {}, "noop": {}, "throttled": {},
}

func workerName(value *wizard.ConfigValue) Result {
	if value == nil || value.Kind != "str" || value.Text == "" {
		return textResult(400, "'worker' must be a non-empty string.")
	}
	return Result{Next: "ready"}
}

func workerDetailName(value *wizard.ConfigValue) Result {
	if !value.PythonTruth() {
		return textResult(400, "'name' is required.")
	}
	return Result{Next: "ready"}
}

func workerLive(data, worker *wizard.ConfigValue) (Result, error) {
	if data == nil || data.Kind != "dict" {
		return Result{}, typeError("worker data must be a mapping")
	}
	workers, ok := data.Field("workers")
	if !ok {
		workers = &wizard.ConfigValue{Kind: "list"}
	}
	if workers.Kind != "list" {
		if (workers.Kind == "dict" || workers.Kind == "str") && !workers.PythonTruth() {
			return Result{Value: dictValue(), Next: "ready"}, nil
		}
		return Result{}, typeError("workers must be a list")
	}
	for _, candidate := range workers.Items {
		if candidate == nil || candidate.Kind != "dict" {
			return Result{}, typeError("worker must be a mapping")
		}
		name, _ := candidate.Field("name")
		if !name.Equal(worker) {
			continue
		}
		rigforge, ok := candidate.Field("rigforge")
		if !ok || !rigforge.PythonTruth() {
			return Result{Value: dictValue(), Next: "ready"}, nil
		}
		return Result{Value: rigforge.Clone(), Next: "ready"}, nil
	}
	return Result{Value: dictValue(), Next: "ready"}, nil
}

func workerNoop(running, worker, version, maxDigits *wizard.ConfigValue) (Result, error) {
	if !running.PythonTruth() {
		return Result{Next: "ready"}, nil
	}
	if running.Kind != "str" {
		return Result{}, typeError("worker version must be a string")
	}
	limit, err := workerDigitLimit(maxDigits)
	if err != nil {
		return Result{}, err
	}
	parsedRunning, err := parseWorkerSemver(running.Text, limit)
	if err != nil {
		return Result{}, err
	}
	if parsedRunning == nil {
		return Result{Next: "ready"}, nil
	}
	if version == nil || version.Kind != "str" {
		return Result{}, typeError("target version must be a string")
	}
	parsedVersion, err := parseWorkerSemver(version.Text, limit)
	if err != nil {
		return Result{}, err
	}
	if parsedVersion == nil || *parsedRunning != *parsedVersion {
		return Result{Next: "ready"}, nil
	}
	body := cvObject(
		"status", stringValue("noop"),
		"worker", cloneOrNull(worker),
		"note", stringValue("already on "+version.Text),
	)
	return Result{Status: 200, Body: body}, nil
}

func workerRecord(value *wizard.ConfigValue) (Result, error) {
	if value == nil || value.Kind != "dict" {
		return Result{}, typeError("worker result must be a mapping")
	}
	status, ok := value.Field("status")
	if !ok {
		status = stringValue("unknown")
	}
	if status.Kind != "str" {
		return Result{Next: "ready"}, nil
	}
	if _, ok := recordableWorkerStatuses[status.Text]; !ok {
		return Result{Next: "ready"}, nil
	}
	changeID, _ := value.Field("change_id")
	reason, _ := value.Field("reason")
	if !reason.PythonTruth() {
		reason, _ = value.Field("error")
	}
	return Result{Next: "record", Value: cvObject(
		"change_id", cloneOrNull(changeID),
		"status", status.Clone(),
		"reason", cloneOrNull(reason),
	)}, nil
}

func stripWorkerCredentials(value *wizard.ConfigValue, depth int) *wizard.ConfigValue {
	if depth > 6 {
		return nullValue()
	}
	if value == nil {
		return nullValue()
	}
	if value.Kind == "list" {
		out := &wizard.ConfigValue{Kind: "list", Items: make([]*wizard.ConfigValue, len(value.Items))}
		for index, item := range value.Items {
			out.Items[index] = stripWorkerCredentials(item, depth+1)
		}
		return out
	}
	if value.Kind != "dict" {
		return value.Clone()
	}
	out := dictValue()
	for _, field := range value.Fields {
		if field.Key == "pass" || field.Key == "tls-fingerprint" {
			secret, _ := field.Value.Field("__secret__")
			if secret != nil && secret.Kind == "bool" && secret.Bool {
				continue
			}
			out.Fields = append(out.Fields, wizard.ConfigField{Key: field.Key, Value: field.Value.Clone()})
			continue
		}
		out.Fields = append(out.Fields, wizard.ConfigField{
			Key: field.Key, Value: stripWorkerCredentials(field.Value, depth+1),
		})
	}
	return out
}

func cvObject(values ...any) *wizard.ConfigValue {
	out := dictValue()
	for index := 0; index < len(values); index += 2 {
		out.Fields = append(out.Fields, wizard.ConfigField{Key: values[index].(string), Value: values[index+1].(*wizard.ConfigValue)})
	}
	return out
}

func cloneOrNull(value *wizard.ConfigValue) *wizard.ConfigValue {
	if value == nil {
		return nullValue()
	}
	return value.Clone()
}
