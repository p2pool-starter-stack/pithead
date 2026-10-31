package doctor

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type ReleaseVerification struct {
	Dir       string
	Image     string
	Appliance bool
}

func (release ReleaseVerification) Finding() (Finding, error) {
	if strings.ContainsRune(release.Dir, 0) || strings.ContainsRune(release.Image, 0) {
		return Finding{}, ErrUnsupportedProbeInput
	}
	if releaseRegularFile(filepath.Join(release.Dir, "dashboard", "Dockerfile")) {
		return Finding{"release-verification", "info", "Source checkout — images build locally and are not signature-verified, and the dashboard's one-click upgrade does not apply: upgrade with 'git pull' then './pithead upgrade'."}, nil
	}
	if !releaseRegularFile(filepath.Join(release.Dir, "cosign.pub")) {
		return Finding{"release-verification", "warn", "No cosign.pub next to pithead — image pulls are NOT signature-verified. Release bundles ship the key from the first signed release."}, nil
	}
	available, err := release.cosignAvailable()
	if err != nil {
		return Finding{}, err
	}
	if !available {
		message := "cosign.pub is present but docker is not available to run the verifier — 'up'/'upgrade' refuse to pull until it is. Start the Docker daemon."
		if release.Appliance {
			message = "The container engine is not available to run the release verifier, so no image can be pulled until it is back. The appliance image ships that engine, so this system copy is faulty."
		}
		return Finding{"release-verification", "warn", message}, nil
	}

	command := exec.Command("docker", "image", "inspect", release.Image)
	command.Dir = release.Dir
	err = command.Run()
	if unsupportedLaunch(err) {
		return Finding{}, ErrUnsupportedProbeInput
	}
	if err == nil {
		return Finding{"release-verification", "ok", "'up' and 'upgrade' verify the release images against cosign.pub; the pinned verifier image is already here, nothing to install."}, nil
	}
	message := "The pinned release verifier image is not on this host yet — the next 'up' or 'upgrade' fetches it. If that fetch fails, the operation reports a signature failure even though nothing was tampered with. Pre-fetch it with: docker pull " + release.Image
	if release.Appliance {
		message = "The pinned release verifier image is not on this machine yet — the next update fetches it. If that fetch fails, the update reports a signature failure even though nothing was tampered with."
	}
	return Finding{"release-verification", "warn", message}, nil
}

func (release ReleaseVerification) cosignAvailable() (bool, error) {
	pathValue := os.Getenv("PATH")
	if pathValue == "" {
		return false, ErrUnsupportedProbeInput
	}
	for _, path := range filepath.SplitList(pathValue) {
		if path == "" || !filepath.IsAbs(path) {
			return false, ErrUnsupportedProbeInput
		}
	}
	if _, err := exec.LookPath("docker"); errors.Is(err, exec.ErrDot) {
		return false, ErrUnsupportedProbeInput
	} else if err != nil {
		return false, nil
	}
	command := exec.Command("docker", "info")
	command.Dir = release.Dir
	err := command.Run()
	if unsupportedLaunch(err) {
		return false, ErrUnsupportedProbeInput
	}
	return err == nil, nil
}

func releaseRegularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
