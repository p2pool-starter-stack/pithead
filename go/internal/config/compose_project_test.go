package config

import "testing"

func TestComposeProjectName(t *testing.T) {
	for _, test := range []struct {
		name            string
		raw             string
		filePresent     bool
		overridePresent bool
		override        string
		project         string
		warning         string
		valid           bool
	}{
		{"missing", "", false, false, "", "pithead", "", true},
		{"empty", "", true, false, "", "pithead", "", true},
		{"literal", "COMPOSE_PROJECT_NAME=pithead-gate\n", true, false, "", "pithead-gate", "", true},
		{"double quote", "COMPOSE_PROJECT_NAME=\"pithead-gate\"\n", true, false, "", "pithead-gate", "", true},
		{"single quote", "COMPOSE_PROJECT_NAME='pithead-gate'\n", true, false, "", "pithead-gate", "", true},
		{"leading digit", "COMPOSE_PROJECT_NAME=2pithead\n", true, false, "", "2pithead", "", true},
		{"override", "COMPOSE_PROJECT_NAME=ignored\n", true, true, "chosen", "chosen", "", true},
		{"empty override", "COMPOSE_PROJECT_NAME=ignored\n", true, true, "", "pithead", "", true},
		{"multiple", "COMPOSE_PROJECT_NAME=one\nCOMPOSE_PROJECT_NAME=two\n", true, false, "", "", composeProjectAssignmentWarning, false},
		{"leading space", " COMPOSE_PROJECT_NAME=one\n", true, false, "", "", composeProjectAssignmentWarning, false},
		{"export", "export COMPOSE_PROJECT_NAME=one\n", true, false, "", "", composeProjectAssignmentWarning, false},
		{"similar name ignored", "COMPOSE_PROJECT_NAMES=one\n", true, false, "", "pithead", "", true},
		{"invalid", "COMPOSE_PROJECT_NAME=Pithead\n", true, false, "", "", composeProjectValueWarning, false},
		{"inline", "COMPOSE_PROJECT_NAME=pithead # inline\n", true, false, "", "", composeProjectValueWarning, false},
		{"carriage return", "COMPOSE_PROJECT_NAME=pithead\r\n", true, false, "", "", composeProjectValueWarning, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			project, warning, valid := ComposeProjectName([]byte(test.raw), test.filePresent, test.overridePresent, test.override)
			if project != test.project || warning != test.warning || valid != test.valid {
				t.Fatalf("ComposeProjectName() = (%q, %q, %t); want (%q, %q, %t)", project, warning, valid, test.project, test.warning, test.valid)
			}
		})
	}
}

func TestComposeProjectNameCWhitespace(t *testing.T) {
	for _, space := range []byte{' ', '\t', '\r', '\v', '\f'} {
		raw := append([]byte{space}, []byte("COMPOSE_PROJECT_NAME=pithead")...)
		_, warning, valid := ComposeProjectName(raw, true, false, "")
		if warning != composeProjectAssignmentWarning || valid {
			t.Fatalf("space %d = (%q, %t)", space, warning, valid)
		}
	}
}
