package wizard

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestPreparationSourceAndObject(t *testing.T) {
	for _, test := range []struct {
		name string
		req  PreparationRequest
		next string
	}{
		{name: "form", req: PreparationRequest{Phase: "source"}, next: "build"},
		{name: "raw", req: PreparationRequest{Phase: "source", Raw: true}, next: "parse"},
		{name: "object", req: PreparationRequest{Phase: "object", Config: configDict()}, next: "prepare"},
	} {
		t.Run(test.name, func(t *testing.T) {
			result, err := HandlePreparation(test.req)
			if err != nil || result.Next != test.next {
				t.Fatalf("result=%+v err=%v", result, err)
			}
		})
	}
	if _, err := HandlePreparation(PreparationRequest{Phase: "object", Config: &ConfigValue{Kind: "list"}}); err == nil || err.Error() != "the top level must be a JSON object" {
		t.Fatalf("unexpected object error: %v", err)
	}
}

func TestPreparationPreparePreviousDefaultsAndValidate(t *testing.T) {
	reference := configDict()
	referenceDashboard := configDict()
	referenceDashboard.Set("host", &ConfigValue{Kind: "str", Text: "auto"})
	reference.Set("dashboard", referenceDashboard)
	legacy := configDict()
	config := configDict()
	config.Set("dashboard", configDict())
	prepared, err := HandlePreparation(PreparationRequest{
		Phase: "prepare", Config: config, Reference: reference, LegacyDefaults: legacy,
	})
	if err != nil || prepared.Next != "previous" || prepared.Changes.Kind != "list" {
		t.Fatalf("prepared=%+v err=%v", prepared, err)
	}

	empty, err := HandlePreparation(PreparationRequest{
		Phase: "previous", Config: prepared.Config, Changes: prepared.Changes, Previous: configDict(),
	})
	if err != nil || empty.Next != "defaults" {
		t.Fatalf("empty previous=%+v err=%v", empty, err)
	}
	previous := configDict()
	previous.Set("dashboard", configDict())
	existing, err := HandlePreparation(PreparationRequest{
		Phase: "previous", Config: prepared.Config, Changes: prepared.Changes, Previous: previous,
	})
	if err != nil || existing.Next != "validate" {
		t.Fatalf("existing previous=%+v err=%v", existing, err)
	}

	defaults := configDict()
	defaultDashboard := configDict()
	defaultDashboard.Set("host", &ConfigValue{Kind: "str", Text: "default-host"})
	defaults.Set("dashboard", defaultDashboard)
	merged, err := HandlePreparation(PreparationRequest{
		Phase: "defaults", Config: prepared.Config, Reference: reference,
		Defaults: defaults, LegacyDefaults: legacy, Changes: prepared.Changes,
	})
	if err != nil || merged.Next != "validate" {
		t.Fatalf("merged=%+v err=%v", merged, err)
	}
	mergedDashboard, _ := merged.Config.Field("dashboard")
	mergedHost, _ := mergedDashboard.Field("host")
	if mergedHost == nil || mergedHost.Text != "default-host" {
		t.Fatalf("defaults not merged: %+v", merged.Config)
	}
	validated, err := HandlePreparation(PreparationRequest{
		Phase: "validate", Config: merged.Config, Previous: configDict(),
		DefaultHost: &ConfigValue{Kind: "str", Text: "fallback"}, Changes: merged.Changes,
	})
	if err != nil || validated.Next != "ready" {
		t.Fatalf("validated=%+v err=%v", validated, err)
	}
}

func TestPreparationStopsAtPrepareError(t *testing.T) {
	result, err := HandlePreparation(PreparationRequest{
		Phase: "prepare", Config: configDict(), Reference: &ConfigValue{Kind: "list"},
		LegacyDefaults: configDict(),
	})
	if err == nil || err.Error() != "reference must be an object" {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Next != "" || result.Config != nil || result.Changes != nil {
		t.Fatalf("partial result escaped: %+v", result)
	}
}

func TestPreparationUsesPreviousAgainAtValidation(t *testing.T) {
	config := configDict()
	dashboard := configDict()
	dashboard.Set("host", &ConfigValue{Kind: "str", Text: "legacy.name"})
	config.Set("dashboard", dashboard)
	previous := config.Clone()
	if _, err := HandlePreparation(PreparationRequest{
		Phase: "validate", Config: config, Previous: previous,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := HandlePreparation(PreparationRequest{
		Phase: "validate", Config: config, Previous: configDict(),
	}); err == nil {
		t.Fatal("validation accepted legacy name without matching previous config")
	}
}

func TestRunPreparationContinuesAfterInputError(t *testing.T) {
	input := strings.Join([]string{
		`{"phase":"object","config":["list",[]]}`,
		`{"phase":"source","raw":true}`,
	}, "\n") + "\n"
	var output bytes.Buffer
	if err := RunPreparation(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("responses=%q", output.String())
	}
	var first, second Response
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatal(err)
	}
	if first.Error == nil || first.Error.Kind != "ValueError" || !second.OK {
		t.Fatalf("first=%+v second=%+v", first, second)
	}
}
