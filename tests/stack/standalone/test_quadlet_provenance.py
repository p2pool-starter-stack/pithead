import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REMOTE = ROOT / "os/quadlet"
FIXTURES = (REMOTE, REMOTE / "local", REMOTE / "payout")
PROVENANCE_KEYS = ("PITHEAD_REGISTRY", "STACK_VERSION")


def fixture_value(name):
    prefix = f"{name}="
    return next(
        line.removeprefix(prefix)
        for line in (REMOTE / "fixture.env").read_text().splitlines()
        if line.startswith(prefix)
    )


DEFAULT_REGISTRY = fixture_value("PITHEAD_REGISTRY")
FIXTURE_VERSION = fixture_value("STACK_VERSION")


class QuadletProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.serial = 0

    def install(self, version=None, source=False):
        self.serial += 1
        install = self.base / f"install-{self.serial}"
        install.mkdir()
        shutil.copy2(ROOT / "pithead", install / "pithead")
        if version is not None:
            (install / "VERSION").write_text(f"{version}\n")
        if source:
            marker = install / "dashboard/Dockerfile"
            marker.parent.mkdir()
            marker.touch()
        return install

    def input_env(self, fixture=REMOTE, values=None):
        self.serial += 1
        values = values or {}
        lines = [
            line
            for line in (fixture / "fixture.env").read_text().splitlines()
            if not any(line.startswith(f"{key}=") for key in PROVENANCE_KEYS)
        ]
        lines.extend(f"{key}={value}" for key, value in values.items())
        path = self.base / f"input-{self.serial}.env"
        path.write_text("\n".join(lines) + "\n")
        return path

    def render(self, install, env_file, process=None, default_env=False):
        self.serial += 1
        out = self.base / f"out-{self.serial}"
        environment = os.environ.copy()
        for key in PROVENANCE_KEYS:
            environment.pop(key, None)
        environment.update(process or {})
        args = [install / "pithead", "render-quadlet"]
        if default_env:
            shutil.copy2(env_file, install / ".env")
        else:
            args.extend(("--env", env_file))
        args.extend(("--out", out))
        result = subprocess.run(  # noqa: S603
            args,
            cwd=self.base,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return out

    def assert_fixture_parity(self, expected, actual):
        expected_files = {
            path.name: path.read_bytes()
            for path in expected.iterdir()
            if path.is_file() and path.name != "fixture.env"
        }
        actual_files = {path.name: path.read_bytes() for path in actual.iterdir()}
        self.assertEqual(actual_files, expected_files)

    def assert_stack_images(self, output, registry, version):
        def images(directory):
            return {
                path.name: line.removeprefix("Image=")
                for path in directory.glob("*.container")
                for line in path.read_text().splitlines()
                if line.startswith("Image=") and "/pithead-" in line
            }

        actual = images(output)
        self.assertEqual(set(actual), set(images(REMOTE)))
        for image in actual.values():
            self.assertTrue(image.startswith(f"{registry}/pithead-"), image)
            self.assertTrue(image.endswith(f":{version}"), image)

    def test_complete_fixtures_keep_byte_parity_through_cli(self):
        install = self.install()
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture.name):
                self.assert_fixture_parity(
                    fixture,
                    self.render(
                        install,
                        fixture / "fixture.env",
                        {
                            "PITHEAD_REGISTRY": "process-images",
                            "STACK_VERSION": "process-version",
                        },
                    ),
                )

    def test_normal_env_uses_release_build_provenance(self):
        install = self.install(version=FIXTURE_VERSION.removeprefix("v"))
        output = self.render(install, self.input_env(), default_env=True)
        self.assert_fixture_parity(REMOTE, output)

    def test_missing_and_empty_values_use_process_registry(self):
        install = self.install(version=FIXTURE_VERSION.removeprefix("v"))
        for values in ({}, {key: "" for key in PROVENANCE_KEYS}):
            with self.subTest(values=values):
                output = self.render(
                    install,
                    self.input_env(values=values),
                    {"PITHEAD_REGISTRY": "process-images"},
                )
                self.assert_stack_images(output, "process-images", FIXTURE_VERSION)

    def test_file_values_override_process_defaults_independently(self):
        install = self.install(version=FIXTURE_VERSION.removeprefix("v"))
        cases = (
            ({"PITHEAD_REGISTRY": "file-images"}, "file-images", FIXTURE_VERSION),
            ({"STACK_VERSION": "file-version"}, "process-images", "file-version"),
        )
        for values, registry, version in cases:
            with self.subTest(values=values):
                output = self.render(
                    install,
                    self.input_env(values=values),
                    {
                        "PITHEAD_REGISTRY": "process-images",
                        "STACK_VERSION": "process-version",
                    },
                )
                self.assert_stack_images(output, registry, version)

    def test_main_recomputes_version_for_release_source_and_missing_version(self):
        cases = (
            (FIXTURE_VERSION.removeprefix("v"), False, FIXTURE_VERSION),
            (FIXTURE_VERSION.removeprefix("v"), True, "dev"),
            (None, False, "dev"),
        )
        for version_file, source, expected in cases:
            with self.subTest(version_file=version_file, source=source):
                output = self.render(
                    self.install(version_file, source),
                    self.input_env(),
                    {"STACK_VERSION": "process-version"},
                )
                self.assert_stack_images(output, DEFAULT_REGISTRY, expected)

    def test_direct_renderer_refuses_missing_provenance_before_writing(self):
        install = self.install()
        env_file = self.input_env()
        output = self.base / "direct-output"
        environment = os.environ.copy()
        for key in PROVENANCE_KEYS:
            environment.pop(key, None)
        result = subprocess.run(  # noqa: S603
            [
                shutil.which("bash"),
                "-c",
                'source "$1"; render_quadlet_units "$2" "$3"',
                "quadlet-test",
                install / "pithead",
                env_file,
                output,
            ],
            cwd=install,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PITHEAD_REGISTRY and STACK_VERSION", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
