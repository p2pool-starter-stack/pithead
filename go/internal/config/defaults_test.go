package config

import (
	"errors"
	"testing"
)

const defaultsFixture = `{
  "values": {
    "first": 1,
    "nested": {"keep": 1, "replace": 2},
    "local": false,
    "monero": {"clearnet_initial_sync": false},
    "tari": {"clearnet_initial_sync": false},
    "nullable": null
  },
  "appliance": {
    "nested": {"replace": 3, "added": 4},
    "appliance_only": true
  },
  "materialize": ["nested.keep", "nested.added", "local"],
  "LEGACY_ABSENT": [
    {"path": "nested.keep", "value": 9},
    {"path": "legacy.all", "platform": false, "value": "all"},
    {"path": "legacy.appliance", "platform": "appliance", "value": true},
    {"path": "legacy.null_platform", "platform": null, "value": true},
    {"path": "legacy.other", "platform": "other", "value": true}
  ]
}`

func TestDefaultsRenderModesPlatformsAndOrder(t *testing.T) {
	defaults := mustDefaults(t, defaultsFixture)
	tests := []struct {
		name     string
		mode     string
		platform string
		want     string
	}{
		{
			name:     "new-diy",
			mode:     "anything",
			platform: "unexpected",
			want: "{\n" +
				"  \"first\": 1,\n" +
				"  \"nested\": {\n    \"keep\": 1,\n    \"replace\": 2\n  },\n" +
				"  \"local\": false,\n" +
				"  \"monero\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
				"  \"tari\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
				"  \"nullable\": null\n}\n",
		},
		{
			name:     "new-appliance",
			mode:     "new",
			platform: "appliance",
			want: "{\n" +
				"  \"first\": 1,\n" +
				"  \"nested\": {\n    \"keep\": 1,\n    \"replace\": 3,\n    \"added\": 4\n  },\n" +
				"  \"local\": false,\n" +
				"  \"monero\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
				"  \"tari\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
				"  \"nullable\": null,\n" +
				"  \"appliance_only\": true\n}\n",
		},
		{
			name:     "legacy-arbitrary-platform",
			mode:     "legacy",
			platform: "other",
			want: "{\n" +
				"  \"first\": 1,\n" +
				"  \"nested\": {\n    \"keep\": 9,\n    \"replace\": 2\n  },\n" +
				"  \"local\": false,\n" +
				"  \"monero\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
				"  \"tari\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
				"  \"nullable\": null,\n" +
				"  \"legacy\": {\n    \"all\": \"all\",\n    \"null_platform\": true,\n    \"other\": true\n  }\n}\n",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := defaults.Render(test.mode, test.platform)
			if err != nil || string(got) != test.want {
				t.Fatalf("Render() = %q, %v; want %q", got, err, test.want)
			}
		})
	}
}

func TestDefaultsDefaultOf(t *testing.T) {
	defaults := mustDefaults(t, defaultsFixture)
	for name, test := range map[string]struct {
		path, mode, platform, want string
	}{
		"leading-dot": {".nested.keep", "legacy", "diy", "9\n"},
		"string-raw":  {"legacy.all", "legacy", "diy", "all\n"},
		"false":       {"local", "new", "diy", "false\n"},
		"appliance":   {"nested.added", "new", "appliance", "4\n"},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := defaults.DefaultOf(test.path, test.mode, test.platform)
			if err != nil || string(got) != test.want {
				t.Fatalf("DefaultOf() = %q, %v; want %q", got, err, test.want)
			}
		})
	}
	for _, path := range []string{"missing", "nullable"} {
		if got, err := defaults.DefaultOf(path, "new", "diy"); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
			t.Fatalf("DefaultOf(%q) = %q, %v", path, got, err)
		}
	}
}

func TestDefaultsPathsMatchJQSplit(t *testing.T) {
	defaults := mustDefaults(t, `{"values":{"":{"leaf":1},"a":{"":2}},"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`)
	for path, want := range map[string]string{
		"..leaf": "1\n",
		"a.":     "2\n",
	} {
		got, err := defaults.DefaultOf(path, "new", "diy")
		if err != nil || string(got) != want {
			t.Fatalf("DefaultOf(%q) = %q, %v; want %q", path, got, err, want)
		}
	}
	root, err := defaults.DefaultOf("", "new", "diy")
	if err != nil || string(root) != "{\n  \"\": {\n    \"leaf\": 1\n  },\n  \"a\": {\n    \"\": 2\n  }\n}\n" {
		t.Fatalf("DefaultOf(empty) = %q, %v", root, err)
	}
	tablePaths := mustDefaults(t, `{"values":{"":{"leaf":1}},"appliance":{},"materialize":[".leaf"],"LEGACY_ABSENT":[{"path":"","value":{"whole":true}}]}`)
	installed, err := tablePaths.NewInstall("diy")
	if err != nil || string(installed) != "{\n  \"\": {\n    \"leaf\": 1\n  },\n  \"monero\": {\n    \"clearnet_initial_sync\": null\n  },\n  \"tari\": {\n    \"clearnet_initial_sync\": null\n  }\n}\n" {
		t.Fatalf("NewInstall table path = %q, %v", installed, err)
	}
	legacy, err := tablePaths.Render("legacy", "diy")
	if err != nil || string(legacy) != "{\n  \"whole\": true\n}\n" {
		t.Fatalf("Render empty table path = %q, %v", legacy, err)
	}
}

func TestDefaultsNewInstall(t *testing.T) {
	defaults := mustDefaults(t, defaultsFixture)
	want := "{\n" +
		"  \"nested\": {\n    \"keep\": 1,\n    \"added\": 4\n  },\n" +
		"  \"local\": false,\n" +
		"  \"monero\": {\n    \"clearnet_initial_sync\": false\n  },\n" +
		"  \"tari\": {\n    \"clearnet_initial_sync\": false\n  }\n}\n"
	got, err := defaults.NewInstall("appliance")
	if err != nil || string(got) != want {
		t.Fatalf("NewInstall() = %q, %v; want %q", got, err, want)
	}
}

func TestDefaultsGetFallbackAndExplicitValues(t *testing.T) {
	defaults := mustDefaults(t, defaultsFixture)
	tests := []struct {
		name, path, config, platform, want string
	}{
		{"missing", "nested.keep", `{}`, "diy", "9\n"},
		{"null", "nested.keep", `{"nested":{"keep":null}}`, "diy", "9\n"},
		{"null-intermediate", "nested.keep", `{"nested":null}`, "diy", "9\n"},
		{"false", "nested.keep", `{"nested":{"keep":false}}`, "diy", "false\n"},
		{"zero", "nested.keep", `{"nested":{"keep":0}}`, "diy", "0\n"},
		{"empty-string", "nested.keep", `{"nested":{"keep":""}}`, "diy", "\n"},
		{"array", "nested.keep", `{"nested":{"keep":[]}}`, "diy", "[]\n"},
		{"missing-everywhere", "unknown", `{"unknown":null}`, "diy", "null\n"},
		{"template", "unknown", `{"unknown":"YOUR_value"}`, "diy", "YOUR_value\n"},
		{"appliance-fallback", "legacy.appliance", `{}`, "appliance", "true\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := defaults.Get(test.path, []byte(test.config), test.platform)
			if err != nil || string(got) != test.want {
				t.Fatalf("Get() = %q, %v; want %q", got, err, test.want)
			}
		})
	}
}

func TestDefaultsRejectUnsupportedInputsWithoutPartialOutput(t *testing.T) {
	for _, raw := range []string{
		``,
		`{"values":{},"values":{},"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`,
		`{"values":[],"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`,
		`{"values":{},"appliance":{},"materialize":[1],"LEGACY_ABSENT":[]}`,
		`{"values":{},"appliance":{},"materialize":[],"LEGACY_ABSENT":[{"value":1}]}`,
	} {
		if got, err := NewDefaults([]byte(raw)); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
			t.Fatalf("NewDefaults(%q) = %#v, %v", raw, got, err)
		}
	}

	defaults := mustDefaults(t, `{"values":{"scalar":1,"array":[]},"appliance":{},"materialize":[],"LEGACY_ABSENT":[{"path":"scalar.child","value":2}]}`)
	if got, err := defaults.Render("legacy", "diy"); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
		t.Fatalf("Render invalid path = %q, %v", got, err)
	}
	if got, err := defaults.Get("array.child", []byte(`{}`), "diy"); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
		t.Fatalf("Get array path = %q, %v", got, err)
	}
	if got, err := defaults.Get("scalar", []byte(`{"x":1,"x":2}`), "diy"); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
		t.Fatalf("Get duplicate config = %q, %v", got, err)
	}
	invalidMaterialize := mustDefaults(t, `{"values":{"scalar":1},"appliance":{},"materialize":["scalar.child"],"LEGACY_ABSENT":[]}`)
	if got, err := invalidMaterialize.NewInstall("diy"); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
		t.Fatalf("NewInstall invalid path = %q, %v", got, err)
	}
	if got, err := NewDefaults([]byte(`{"values":{"number":1.0},"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`)); got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
		t.Fatalf("NewDefaults unsupported number = %#v, %v", got, err)
	}
}

func TestDefaultsMethodsDoNotMutateSharedState(t *testing.T) {
	defaults := mustDefaults(t, defaultsFixture)
	before, err := defaults.Render("new", "appliance")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = defaults.Render("legacy", "appliance"); err != nil {
		t.Fatal(err)
	}
	if _, err = defaults.NewInstall("appliance"); err != nil {
		t.Fatal(err)
	}
	after, err := defaults.Render("new", "appliance")
	if err != nil || string(after) != string(before) {
		t.Fatalf("Render after overlays = %q, %v; want %q", after, err, before)
	}
}

func mustDefaults(t *testing.T, raw string) *Defaults {
	t.Helper()
	defaults, err := NewDefaults([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return defaults
}
