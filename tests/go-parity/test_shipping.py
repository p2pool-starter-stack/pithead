import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")
DOCKER = shutil.which("docker")


class ShippingContractTest(unittest.TestCase):
    def run_sync(self, source, destination):
        fake_bin = source.parent / "fake-bin"
        fake_bin.mkdir(exist_ok=True)
        findmnt = fake_bin / "findmnt"
        findmnt.write_text("#!/bin/sh\nexit 1\n")
        findmnt.chmod(0o755)
        return subprocess.run(  # noqa: S603
            [BASH, str(ROOT / "os/overlay/pithead-sync")],
            env={
                **os.environ,
                "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                "PITHEAD_SYNC_SRC": str(source),
                "PITHEAD_SYNC_DST": str(destination),
                "PITHEAD_SYNC_RIGFORGE_SRC": str(source.parent / "missing-rigforge"),
                "PITHEAD_SYNC_RIGFORGE_DST": str(source.parent / "rigforge-destination"),
            },
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_appliance_sync_installs_native_cli_and_preserves_state(self):
        self.assertIsNotNone(BASH)
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            source = temp / "source"
            destination = temp / "destination"
            (source / "go/bin").mkdir(parents=True)
            destination.mkdir()
            (source / "go/bin/pithead").write_bytes(b"native-cli")
            (destination / "state.json").write_bytes(b"state")

            result = self.run_sync(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            native = destination / "go/bin/pithead"
            self.assertEqual(native.read_bytes(), b"native-cli")
            self.assertEqual(native.stat().st_mode & 0o777, 0o755)
            self.assertEqual((destination / "state.json").read_bytes(), b"state")

    def test_appliance_sync_replaces_existing_native_cli(self):
        self.assertIsNotNone(BASH)
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            source = temp / "source"
            destination = temp / "destination"
            (source / "go/bin").mkdir(parents=True)
            (destination / "go/bin").mkdir(parents=True)
            (source / "go/bin/pithead").write_bytes(b"new-native-cli")
            (destination / "go/bin/pithead").write_bytes(b"old-native-cli")

            result = self.run_sync(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((destination / "go/bin/pithead").read_bytes(), b"new-native-cli")

    def test_appliance_sync_removes_native_cli_when_source_is_absent(self):
        self.assertIsNotNone(BASH)
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            source = temp / "source"
            destination = temp / "destination"
            source.mkdir()
            (destination / "go/bin").mkdir(parents=True)
            (destination / "go/bin/pithead").write_bytes(b"old-native-cli")
            (destination / "go/bin/keep").write_bytes(b"keep")
            (destination / "state.json").write_bytes(b"state")

            result = self.run_sync(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((destination / "go/bin/pithead").exists())
            self.assertEqual((destination / "go/bin/keep").read_bytes(), b"keep")
            self.assertEqual((destination / "state.json").read_bytes(), b"state")

            shutil.rmtree(destination / "go")
            result = self.run_sync(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((destination / "go").exists())
            self.assertEqual((destination / "state.json").read_bytes(), b"state")

            (destination / "go/bin/pithead").mkdir(parents=True)
            (destination / "go/bin/pithead/keep").write_bytes(b"keep")
            result = self.run_sync(source, destination)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((destination / "go/bin/pithead/keep").read_bytes(), b"keep")
            self.assertEqual((destination / "state.json").read_bytes(), b"state")

    def test_toolchain_and_reproducible_flags_are_pinned(self):
        go_dockerfile_path = ROOT / "go/Dockerfile"
        self.assertTrue(go_dockerfile_path.is_file())
        go_dockerfile = go_dockerfile_path.read_text()
        rootfs_dockerfile = (ROOT / "os/rootfs/Dockerfile").read_text()
        runner_dockerfile = (ROOT / "tests/runner/Dockerfile").read_text()
        cli_makefile = (ROOT / "go/cli.mk").read_text()

        go_image = re.search(
            r"^FROM --platform=\$BUILDPLATFORM (\S+) AS build$", go_dockerfile, re.M
        )
        rootfs_image = re.search(r"^FROM (\S+) AS gobuild$", rootfs_dockerfile, re.M)
        runner_image = re.search(r"^FROM (\S+) AS go$", runner_dockerfile, re.M)
        go_version = re.search(r"^GO_VERSION := (\S+)$", cli_makefile, re.M)

        self.assertIsNotNone(go_image)
        self.assertIsNotNone(rootfs_image)
        self.assertIsNotNone(runner_image)
        self.assertIsNotNone(go_version)
        image = go_image.group(1)
        self.assertEqual(rootfs_image.group(1), image)
        self.assertEqual(runner_image.group(1), image)
        self.assertRegex(
            image,
            rf"^golang:{re.escape(go_version.group(1))}-trixie@sha256:[0-9a-f]{{64}}$",
        )

        self.assertIn("ENV CGO_ENABLED=0", go_dockerfile)
        self.assertIn("-trimpath -buildvcs=false -ldflags=-buildid=", go_dockerfile)
        self.assertIn("-trimpath -buildvcs=false -ldflags=-buildid=", rootfs_dockerfile)
        self.assertNotIn("require ", (ROOT / "go/go.mod").read_text())

    def test_go_cli_workflow_uses_registry_mirror_and_pr_concurrency(self):
        workflow = (ROOT / ".github/workflows/go-cli.yml").read_text()
        checkout_match = re.search(
            r"^      - uses: actions/checkout@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$",
            workflow,
            re.M,
        )
        self.assertIsNotNone(checkout_match)
        checkout = checkout_match.group()
        self.assertIn(
            f"{checkout}\n"
            "        with:\n"
            "          persist-credentials: false\n"
            "      - uses: ./.github/actions/docker-registry-mirror",
            workflow,
        )
        self.assertIn(
            "concurrency:\n"
            "  group: ${{ github.workflow }}-${{ github.ref }}\n"
            "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            workflow,
        )
        checkout_index = workflow.index(checkout)
        mirror_index = workflow.index("      - uses: ./.github/actions/docker-registry-mirror")
        suite_index = workflow.index("      - name: Run the pinned Linux CLI suites")
        self.assertLess(checkout_index, mirror_index)
        self.assertLess(mirror_index, suite_index)

    def test_dependabot_tracks_go_builder_image(self):
        config = (ROOT / ".github/dependabot.yml").read_text()
        docker_updates = config.split('- package-ecosystem: "docker"', 1)[1]
        docker_updates = docker_updates.split("  - package-ecosystem:", 1)[0]

        self.assertIn('      - "/go"\n', docker_updates)

    def test_rootfs_stages_only_the_native_cli(self):
        dockerfile = (ROOT / "os/rootfs/Dockerfile").read_text()
        self.assertIn("go build -C /src/pithead-go", dockerfile)
        self.assertIn("-o /out/pithead ./cmd/pithead", dockerfile)
        self.assertIn("COPY --from=gobuild /out/pithead /opt/pithead/go/bin/pithead", dockerfile)
        self.assertNotIn("/out/dashboard", dockerfile)

    def test_release_bundle_contains_executable_native_cli(self):
        self.assertTrue((ROOT / "pithead").is_file(), "run make before shipping tests")
        self.assertIsNotNone(BASH)
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            fake_bin = temp / "bin"
            fake_bin.mkdir()
            docker = fake_bin / "docker"
            docker.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "out=\n"
                "while [ $# -gt 0 ]; do\n"
                "  case $1 in type=local,dest=*) out=${1#type=local,dest=};; esac\n"
                "  shift\n"
                "done\n"
                '[ -n "$out" ]\n'
                'mkdir -p "$out"\n'
                "printf '#!/bin/sh\\nprintf native-cli\\n' >\"$out/pithead\"\n"
                'chmod 755 "$out/pithead"\n'
            )
            docker.chmod(0o755)
            work = temp / "work"
            work.mkdir()
            script = r"""
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { :; }
log() { :; }
image_for() { printf 'registry.example/pithead-%s' "$1"; }
get_digest() { printf 'registry.example/pithead-%s@sha256:%064d' "$1" 0; }
is_digest_ref_for() { return 0; }
source scripts/release/bundle.sh
DRY_RUN=0
COSIGN_ENABLED=0
GIT_COMMIT=0123456789abcdef0123456789abcdef01234567
TAG=v9.9.9
REGISTRY=registry.example
REPO_ROOT=$PWD
WORKDIR=$SHIPPING_WORK
BUILDX_BUILDER=fake
IMAGES=(tor monero p2pool xmrig-proxy dashboard)
build_native_artifacts "$WORKDIR/native"
PITHEAD_REQUIRE_NATIVE_BUNDLE=1 make_bundle "$WORKDIR/pithead.tar.gz" "$WORKDIR/native"
"""
            result = subprocess.run(  # noqa: S603
                [BASH, "-c", script],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                    "SHIPPING_WORK": str(work),
                },
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(work / "pithead.tar.gz", "r:gz") as bundle:
                member = bundle.getmember("pithead/go/bin/pithead")
                self.assertEqual(member.mode & 0o111, 0o111)
                extracted = bundle.extractfile(member)
                self.assertIsNotNone(extracted)
                self.assertEqual(extracted.read(), b"#!/bin/sh\nprintf native-cli\n")

    def test_release_bundle_requires_native_artifact(self):
        self.assertIsNotNone(BASH)
        script = r"""
set -uo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
source scripts/release/bundle.sh
DRY_RUN=0
WORKDIR=/tmp
PITHEAD_REQUIRE_NATIVE_BUNDLE=1 make_bundle /tmp/unused-bundle ''
"""
        result = subprocess.run(  # noqa: S603
            [BASH, "-c", script],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native Linux binary is required", result.stderr)


if os.environ.get("PITHEAD_REAL_GO_BUILD") == "1":

    class RealArtifactBuildTest(unittest.TestCase):
        def test_linux_amd64_artifact_build_is_reproducible(self):
            self.assertIsNotNone(DOCKER)
            with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
                for output in (first, second):
                    subprocess.run(  # noqa: S603
                        [
                            DOCKER,
                            "buildx",
                            "build",
                            "--no-cache",
                            "--platform",
                            "linux/amd64",
                            "--file",
                            "go/Dockerfile",
                            "--target",
                            "artifacts",
                            "--output",
                            f"type=local,dest={output}",
                            "go",
                        ],
                        cwd=ROOT,
                        timeout=180,
                        check=True,
                    )
                self.assertEqual(
                    (Path(first) / "pithead").read_bytes(),
                    (Path(second) / "pithead").read_bytes(),
                )


if __name__ == "__main__":
    unittest.main()
