import os
import shlex
import subprocess
from pathlib import Path

import pytest
from test_go_shipping import test_container_entrypoint_selection_preserves_exec as selection_check

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("dry_run", [0, 1])
@pytest.mark.parametrize("mutation", [False, True])
def test_release_publish_requires_native_artifacts_before_signing(tmp_path, dry_run, mutation):
    source = (ROOT / "scripts/release/bundle.sh").read_text()
    seam = 'PITHEAD_REQUIRE_NATIVE_BUNDLE=1 make_bundle "$bundle" "$native_dir"'
    assert source.count(seam) == 1
    if mutation:
        source = source.replace(seam, 'make_bundle "$bundle"')
    bundle = tmp_path / "bundle.sh"
    bundle.write_text(source)
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_TEST_WORK=str(tmp_path),
        PITHEAD_TEST_BUNDLE=str(bundle),
        PITHEAD_TEST_DRY_RUN=str(dry_run),
    )
    script = r"""
set --
source scripts/release/release.sh >/dev/null 2>&1
source "$PITHEAD_TEST_BUNDLE"
WORKDIR=$PITHEAD_TEST_WORK DRY_RUN=$PITHEAD_TEST_DRY_RUN COSIGN_ENABLED=1 TAG=v9.9.9
printf 'fixture\n' >"$WORKDIR/appliance-rigforge.md"
require_appliance_draft() { :; }
stage() { :; }
appliance_assets() { :; }
write_manifest() { : >"$1"; }
build_native_artifacts() { mkdir -p "$1"; printf 'built\n' >>"$WORKDIR/trace"; }
make_bundle() {
    [ "${PITHEAD_REQUIRE_NATIVE_BUNDLE:-0}" = 1 ] || exit 51
    [ "$DRY_RUN" = 1 ] || { [ "${2:-}" = "$WORKDIR/native-linux-amd64" ] && [ -d "$2" ]; } || exit 52
    printf 'bundled\n' >>"$WORKDIR/trace"
    : >"$1"
}
append_bundle_sha256() { :; }
sign_bundle() { printf 'signature' >"$2"; printf 'signed\n' >>"$WORKDIR/trace"; }
cosign() { :; }
gh() { :; }
confirm() { return 1; }
publish
"""
    result = subprocess.run(
        ["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, timeout=15, check=False
    )
    if mutation:
        assert result.returncode == 51
    else:
        assert result.returncode == 0, result.stderr
        expected = ["bundled", "signed"] if dry_run else ["built", "bundled", "signed"]
        assert (tmp_path / "trace").read_text().splitlines() == expected


@pytest.mark.parametrize("failure", ["none", "build", "artifact", "archive"])
def test_native_artifact_builder_selects_linux_and_refuses_failures(tmp_path, failure):
    env = os.environ.copy()
    env.update(PITHEAD_IMPL="go", PITHEAD_TEST_WORK=str(tmp_path), PITHEAD_TEST_FAILURE=failure)
    script = r"""
set --
source scripts/release/release.sh >/dev/null 2>&1
REPO_ROOT=$PWD
WORKDIR=$PITHEAD_TEST_WORK GIT_COMMIT=0123456789abcdef0123456789abcdef01234567
git() {
    printf '%s\n' "$@" >"$PITHEAD_TEST_WORK/archive-arguments"
    [ "$*" = "-C $REPO_ROOT archive --format=tar $GIT_COMMIT go/" ] || return 17
    [ "$PITHEAD_TEST_FAILURE" != archive ] || return 18
    mkdir -p "$PITHEAD_TEST_WORK/archive/go"
    cp "$REPO_ROOT/go/Dockerfile" "$PITHEAD_TEST_WORK/archive/go/Dockerfile"
    tar -cf - -C "$PITHEAD_TEST_WORK/archive" go
}
docker() {
    printf '%s\n' "$@" >"$PITHEAD_TEST_WORK/arguments"
    [ "$PITHEAD_TEST_FAILURE" != build ] || return 19
    if [ "$PITHEAD_TEST_FAILURE" != artifact ]; then
        printf '#!/bin/sh\nexit 0\n' >"$PITHEAD_TEST_WORK/output/pithead"
        cp "$PITHEAD_TEST_WORK/output/pithead" "$PITHEAD_TEST_WORK/output/dashboard"
        chmod +x "$PITHEAD_TEST_WORK/output/"*
    fi
}
build_native_artifacts "$PITHEAD_TEST_WORK/output"
"""
    result = subprocess.run(
        ["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, timeout=15, check=False
    )
    assert (result.returncode == 0) == (failure == "none")
    if failure == "archive":
        assert not (tmp_path / "arguments").exists()
        return
    arguments = (tmp_path / "arguments").read_text().splitlines()
    assert arguments[:4] == ["buildx", "build", "--platform", "linux/amd64"]
    assert arguments[arguments.index("--builder") + 1] == "pithead-release"
    assert arguments[arguments.index("--file") + 1] == str(tmp_path / "native-source/go/Dockerfile")
    assert arguments[arguments.index("--target") + 1] == "artifacts"
    assert arguments[-1] == str(tmp_path / "native-source/go")


def test_selector_source_mutation_is_detected(tmp_path, monkeypatch):
    import test_go_shipping

    original = test_go_shipping._entrypoint

    def mutated(path):
        entrypoint = original(path)
        source = entrypoint.read_text()
        seam = 'exec "${PITHEAD_DASHBOARD_GO_BINARY:-/app/go/bin/dashboard}"'
        assert source.count(seam) == 1
        entrypoint.write_text(source.replace(seam, "exec python3 -u -m mining_dashboard.main"))
        return entrypoint

    monkeypatch.setattr(test_go_shipping, "_entrypoint", mutated)
    with pytest.raises(AssertionError):
        selection_check(tmp_path, "go")


def test_dashboard_selector_is_independent_of_cli_fallback():
    compose = (ROOT / "docker-compose.yml").read_text()
    assert "- PITHEAD_IMPL=${PITHEAD_DASHBOARD_IMPL:-python}" in compose
    dashboard = compose.split("  dashboard:\n", 1)[1].split("\n  caddy:", 1)[0]
    assert "pithead-go: ./go" in dashboard
    assert "target: go-production" in dashboard
    pin = (ROOT / "os/rootfs/Dockerfile").read_text().splitlines()[0].split(" AS ")[0]
    assert pin in (ROOT / "dashboard/Dockerfile").read_text()
    artifacts = (ROOT / "go/Dockerfile").read_text()
    assert pin.removeprefix("FROM ") in artifacts.splitlines()[0]
    assert "GOOS=$TARGETOS GOARCH=$TARGETARCH" in artifacts


def test_root_context_allowlist_covers_rootfs_inputs_and_excludes_runtime_secrets():
    rules = (ROOT / ".dockerignore").read_text().splitlines()
    assert rules[0] == "**"
    for line in (ROOT / "os/rootfs/Dockerfile").read_text().splitlines():
        if line.startswith("COPY ") and not line.startswith("COPY --from="):
            for source in shlex.split(line)[1:-1]:
                assert f"!{source}" in rules
    for path in (".env", "config.json", "data/", "backups/", "os/rauc/certs/", "os/certs-test/"):
        assert f"!{path}" not in rules
    assert "go/bin/" in rules
    assert "build/tari/config.toml" in rules


@pytest.mark.parametrize("dry_run", [0, 1])
def test_release_images_use_prepared_go_source_before_building(tmp_path, dry_run):
    env = os.environ.copy()
    env.update(PITHEAD_TEST_WORK=str(tmp_path), PITHEAD_TEST_DRY_RUN=str(dry_run))
    script = r"""
set --
source scripts/release/release.sh >/dev/null 2>&1
WORKDIR=$PITHEAD_TEST_WORK DRY_RUN=$PITHEAD_TEST_DRY_RUN IMAGES=(dashboard)
stage() { :; }
ghcr_login() { :; }
ensure_buildx_builder() { :; }
prepare_native_source() {
    NATIVE_SOURCE_DIR=$WORKDIR/frozen
    printf 'prepared\n' >>"$WORKDIR/trace"
}
retry_registry_write() {
    shift
    printf '%s\n' "$@" >"$WORKDIR/arguments"
    printf 'built\n' >>"$WORKDIR/trace"
}
build_rootfs_image() {
    [ "$NATIVE_SOURCE_DIR" = "$WORKDIR/frozen" ] || exit 51
    printf 'rootfs\n' >>"$WORKDIR/trace"
}
build_images
"""
    result = subprocess.run(
        ["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, timeout=15, check=False
    )
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "trace").read_text().splitlines() == ["prepared", "built", "rootfs"]
    arguments = (tmp_path / "arguments").read_text().splitlines()
    assert arguments[arguments.index("--build-context") + 1] == f"pithead-go={tmp_path}/frozen/go"
    assert arguments[arguments.index("--target") + 1] == "go-production"
