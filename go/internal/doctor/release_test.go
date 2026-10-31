package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testVerifierImage = "registry.invalid/verifier@sha256:fixture"

func TestReleaseVerificationFiles(t *testing.T) {
	dir := t.TempDir()
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got != (Finding{"release-verification", "warn", "No cosign.pub next to pithead — image pulls are NOT signature-verified. Release bundles ship the key from the first signed release."}) {
		t.Fatalf("no key = %#v, %v", got, err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "dashboard"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dashboard", "Dockerfile"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	want := Finding{"release-verification", "info", "Source checkout — images build locally and are not signature-verified, and the dashboard's one-click upgrade does not apply: upgrade with 'git pull' then './pithead upgrade'."}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got != want {
		t.Fatalf("source checkout = %#v, %v", got, err)
	}
	if err := os.Remove(filepath.Join(dir, "dashboard", "Dockerfile")); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "Dockerfile.fixture")
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "dashboard", "Dockerfile")); err != nil {
		t.Fatal(err)
	}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got != want {
		t.Fatalf("symlinked source checkout = %#v, %v", got, err)
	}
	if err := os.Remove(filepath.Join(dir, "dashboard", "Dockerfile")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "dashboard", "Dockerfile"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got.Status != "warn" || !strings.HasPrefix(got.Message, "No cosign.pub") {
		t.Fatalf("Dockerfile directory = %#v, %v", got, err)
	}
}

func TestReleaseVerificationDocker(t *testing.T) {
	dir, log := fakeReleaseInstall(t)
	t.Setenv("PITHEAD_ENGINE", "podman")

	t.Setenv("DOCKER_INFO_EXIT", "7")
	wantDIY := Finding{"release-verification", "warn", "cosign.pub is present but docker is not available to run the verifier — 'up'/'upgrade' refuse to pull until it is. Start the Docker daemon."}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got != wantDIY {
		t.Fatalf("unavailable DIY = %#v, %v", got, err)
	}
	wantAppliance := Finding{"release-verification", "warn", "The container engine is not available to run the release verifier, so no image can be pulled until it is back. The appliance image ships that engine, so this system copy is faulty."}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage, Appliance: true}).Finding(); err != nil || got != wantAppliance {
		t.Fatalf("unavailable appliance = %#v, %v", got, err)
	}

	t.Setenv("DOCKER_INFO_EXIT", "0")
	t.Setenv("DOCKER_INSPECT_EXIT", "0")
	wantOK := Finding{"release-verification", "ok", "'up' and 'upgrade' verify the release images against cosign.pub; the pinned verifier image is already here, nothing to install."}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got != wantOK {
		t.Fatalf("present image = %#v, %v", got, err)
	}

	t.Setenv("DOCKER_INSPECT_EXIT", "1")
	wantMissing := Finding{"release-verification", "warn", "The pinned release verifier image is not on this host yet — the next 'up' or 'upgrade' fetches it. If that fetch fails, the operation reports a signature failure even though nothing was tampered with. Pre-fetch it with: docker pull " + testVerifierImage}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); err != nil || got != wantMissing {
		t.Fatalf("missing image DIY = %#v, %v", got, err)
	}
	wantMissingAppliance := Finding{"release-verification", "warn", "The pinned release verifier image is not on this machine yet — the next update fetches it. If that fetch fails, the update reports a signature failure even though nothing was tampered with."}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage, Appliance: true}).Finding(); err != nil || got != wantMissingAppliance {
		t.Fatalf("missing image appliance = %#v, %v", got, err)
	}

	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	wantCalls := strings.Repeat(dir+"|info\n", 2) + strings.Repeat(dir+"|info\n"+dir+"|image inspect "+testVerifierImage+"\n", 3)
	if string(calls) != wantCalls {
		t.Fatalf("Docker calls = %q; want %q", calls, wantCalls)
	}
}

func TestReleaseVerificationMissingDocker(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cosign.pub"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir())
	got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding()
	if err != nil || got.Status != "warn" || !strings.Contains(got.Message, "docker is not available") {
		t.Fatalf("missing Docker = %#v, %v", got, err)
	}
}

func TestReleaseVerificationRelativePathRequiresFallback(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cosign.pub"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", ".")
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("relative PATH = %#v, %v", got, err)
	}
}

func TestReleaseVerificationUnsupportedInput(t *testing.T) {
	for _, release := range []ReleaseVerification{
		{Dir: "bad\x00dir", Image: testVerifierImage},
		{Dir: t.TempDir(), Image: "bad\x00image"},
	} {
		if got, err := release.Finding(); got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("unsupported input = %#v, %v", got, err)
		}
	}

	dir, _ := fakeReleaseInstall(t)
	tool := filepath.Join(strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0], "docker")
	if err := os.WriteFile(tool, []byte("exit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := (ReleaseVerification{Dir: dir, Image: testVerifierImage}).Finding(); got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("unsupported launch = %#v, %v", got, err)
	}
}

func fakeReleaseInstall(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cosign.pub"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	tools := t.TempDir()
	log := filepath.Join(tools, "calls")
	script := "#!/bin/sh\nprintf '%s|%s\\n' \"$PWD\" \"$*\" >>\"$DOCKER_LOG\"\ncase \"$*\" in\ninfo) exit \"$DOCKER_INFO_EXIT\" ;;\n'image inspect '*) exit \"$DOCKER_INSPECT_EXIT\" ;;\n*) exit 98 ;;\nesac\n"
	if err := os.WriteFile(filepath.Join(tools, "docker"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tools)
	t.Setenv("DOCKER_LOG", log)
	t.Setenv("DOCKER_INFO_EXIT", "0")
	t.Setenv("DOCKER_INSPECT_EXIT", "0")
	return dir, log
}
