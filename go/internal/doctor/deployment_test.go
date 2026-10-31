package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDeploymentMissingEnvironment(t *testing.T) {
	root := t.TempDir()
	tests := []struct {
		appliance bool
		message   string
	}{
		{false, "No .env found — the stack has not been set up. Run './pithead setup'. (Skipping env-dependent checks.)"},
		{true, "The stack has not been set up — finish setup from this machine's setup page. (Skipping the checks that depend on it.)"},
	}
	for _, test := range tests {
		got, err := (Deployment{Dir: root, Appliance: test.appliance}).Findings()
		want := []Finding{{"environment-file", "warn", test.message}}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("Findings(appliance=%t) = %#v, %v; want %#v", test.appliance, got, err, want)
		}
	}
}

func TestDeploymentCompleted(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".env"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := (Deployment{Dir: root, Completed: "true\n\n"}).Findings()
	want := []Finding{
		{"environment-file", "ok", ".env present."},
		{"deployment-completed", "ok", "DEPLOYMENT_COMPLETED=true — setup finished."},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("Findings() = %#v, %v; want %#v", got, err, want)
	}
}

func TestDeploymentIncompleteSurfaces(t *testing.T) {
	root := t.TempDir()
	env := filepath.Join(root, "rendered.env")
	if err := os.WriteFile(env, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		appliance bool
		message   string
	}{
		{false, "DEPLOYMENT_COMPLETED is not true — setup may be incomplete. Run './pithead setup'."},
		{true, "Setup did not finish, so parts of this machine may be unconfigured. Its setup page closes once the machine is provisioned, so no dashboard surface resumes it — correcting this needs console access."},
	}
	for _, test := range tests {
		got, err := (Deployment{Dir: root, EnvFile: env, Completed: "false", Appliance: test.appliance}).Findings()
		want := []Finding{
			{"environment-file", "ok", env + " present."},
			{"deployment-completed", "warn", test.message},
		}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("Findings(appliance=%t) = %#v, %v; want %#v", test.appliance, got, err, want)
		}
	}
}

func TestDeploymentEnvironmentMustBeRegular(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target.env")
	if err := os.WriteFile(target, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "linked.env")); err != nil {
		t.Fatal(err)
	}
	got, err := (Deployment{Dir: root, EnvFile: "linked.env", Completed: "true"}).Findings()
	if err != nil || len(got) != 2 || got[0].Status != "ok" {
		t.Fatalf("symlink Findings() = %#v, %v", got, err)
	}
	got, err = (Deployment{Dir: root, EnvFile: ".", Completed: "true"}).Findings()
	want := []Finding{{"environment-file", "warn", "No . found — the stack has not been set up. Run './pithead setup'. (Skipping env-dependent checks.)"}}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("directory Findings() = %#v, %v; want %#v", got, err, want)
	}
}

func TestDeploymentRejectUnsupportedInputs(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".env"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []Deployment{
		{Dir: "relative"},
		{Dir: root + "/../" + filepath.Base(root)},
		{Dir: root, EnvFile: "../.env"},
		{Dir: root, EnvFile: "bad\n.env"},
		{Dir: root, Completed: "true\x00"},
	}
	for _, deployment := range cases {
		if findings, err := deployment.Findings(); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Errorf("Findings(%#v) = %#v, %v", deployment, findings, err)
		}
	}
}
