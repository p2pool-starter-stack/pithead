import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/compose_project_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
UNSET = object()
if BASH is None:
    raise RuntimeError("bash is required")


class ComposeProjectParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name):
        path = self.directory / name
        path.mkdir()
        return path

    def environment(self, implementation, *, binary=None, override=UNSET, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        for key in ("BASH_ENV", "COMPOSE_PROJECT_NAME", "ENV_FILE"):
            env.pop(key, None)
        env.update(
            COMPOSE_PROJECT_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
            LC_ALL="C",
            LANG="C",
        )
        if override is not UNSET:
            env["COMPOSE_PROJECT_NAME"] = override
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, *, binary=None, override=UNSET, extra=None):
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work)],
            env=self.environment(implementation, binary=binary, override=override, extra=extra),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def compare(
        self,
        name,
        content=None,
        *,
        override=UNSET,
        filename=".env",
        binary=None,
        extra=None,
        mode=None,
    ):
        results = []
        for implementation in ("bash", "go"):
            work = self.work(name + "-" + implementation)
            path = work / filename
            if content is not None:
                path.write_bytes(content)
                if mode is not None:
                    path.chmod(mode)
            selected = dict(extra or {})
            selected["ENV_FILE"] = filename
            results.append(
                self.invoke(
                    implementation,
                    work,
                    binary=binary,
                    override=override,
                    extra=selected,
                )
            )
        expected, actual = results
        self.assertEqual(self.result(actual), self.result(expected))
        return actual

    def executable(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def helper(self, fields, *, binary=GO_BINARY):
        env = self.environment("go", binary=binary)
        env["PITHEAD_GO_HELPER"] = "config-compose-project"
        return subprocess.run(  # noqa: S603
            [str(binary)],
            input=b"\0".join(fields) + b"\0",
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_defaults_and_explicit_override_priority_match(self):
        self.assertEqual(self.compare("missing").stdout, b"pithead")
        self.assertEqual(
            self.compare("empty-override", b"COMPOSE_PROJECT_NAME=ignored\n", override="").stdout,
            b"pithead",
        )
        self.assertEqual(
            self.compare("valid-override", b"\0bad", override="other_project-2").stdout,
            b"other_project-2",
        )
        invalid = self.compare("invalid-override", b"\0bad", override="Bad/name")
        self.assertEqual(invalid.returncode, 1)

    def test_literal_quoted_empty_and_unterminated_values_match(self):
        cases = [
            ("plain", b"COMPOSE_PROJECT_NAME=pithead-gate\n"),
            ("double", b'COMPOSE_PROJECT_NAME="pithead-gate"\n'),
            ("single", b"COMPOSE_PROJECT_NAME='pithead-gate'\n"),
            ("empty", b"COMPOSE_PROJECT_NAME=\n"),
            ("empty-double", b'COMPOSE_PROJECT_NAME=""\n'),
            ("eof", b"COMPOSE_PROJECT_NAME=pithead-eof"),
        ]
        for name, content in cases:
            with self.subTest(name=name):
                self.compare(name, content)

    def test_ambiguous_and_nonliteral_assignments_match(self):
        cases = [
            ("duplicate", b"COMPOSE_PROJECT_NAME=one\nCOMPOSE_PROJECT_NAME=two\n"),
            ("space", b" COMPOSE_PROJECT_NAME=pithead-gate\n"),
            ("export", b"export COMPOSE_PROJECT_NAME=pithead-gate\n"),
            ("escape", b'COMPOSE_PROJECT_NAME="pithead-\\gate"\n'),
            ("open-quote", b'COMPOSE_PROJECT_NAME="pithead-gate\n'),
            ("expression", b"COMPOSE_PROJECT_NAME=${OTHER_PROJECT}\n"),
            ("inline", b"COMPOSE_PROJECT_NAME=pithead-gate # inline\n"),
            ("uppercase", b"COMPOSE_PROJECT_NAME=Pithead\n"),
        ]
        for name, content in cases:
            with self.subTest(name=name):
                result = self.compare(name, content)
                self.assertEqual(result.returncode, 1)

    def test_assignment_boundaries_and_raw_bytes_match(self):
        cases = [
            ("suffix", b"COMPOSE_PROJECT_NAME_SUFFIX=ignored\n"),
            ("dash-boundary", b"COMPOSE_PROJECT_NAME-extra=value\n"),
            ("crlf", b"COMPOSE_PROJECT_NAME=pithead-crlf\r\n"),
            ("invalid-byte", b"COMPOSE_PROJECT_NAME=pithead-\xff\n"),
            ("nul", b"COMPOSE_PROJECT_NAME=pithead\0other\n"),
            ("blank-first", b"\nCOMPOSE_PROJECT_NAME=pithead-next\n"),
        ]
        for name, content in cases:
            with self.subTest(name=name):
                self.compare(name, content)

    def test_values_are_not_evaluated_or_interpolated(self):
        for implementation in ("bash", "go"):
            work = self.work("no-eval-" + implementation)
            marker = work / "created"
            (work / ".env").write_text(f"COMPOSE_PROJECT_NAME=$(touch {marker})\n")
            result = self.invoke(
                implementation, work, extra={"ENV_FILE": ".env", "OTHER_PROJECT": "valid"}
            )
            self.assertEqual(result.returncode, 1)
            self.assertFalse(marker.exists())

    def test_nonregular_unreadable_and_dash_files_match(self):
        self.compare("unreadable", b"COMPOSE_PROJECT_NAME=hidden\n", mode=0)
        self.compare("dash", b"COMPOSE_PROJECT_NAME=option\n", filename="-values.env")
        results = []
        for implementation in ("bash", "go"):
            work = self.work("directory-" + implementation)
            (work / ".env").mkdir()
            results.append(self.invoke(implementation, work, extra={"ENV_FILE": ".env"}))
        self.assertEqual(self.result(results[1]), self.result(results[0]))

    def tool_path(self, name, *, include_cat, include_grep):
        path = self.work(name)
        if include_cat:
            (path / "cat").symlink_to(shutil.which("cat"))
        if include_grep:
            (path / "grep").symlink_to(shutil.which("grep"))
        return path

    def test_missing_and_function_tools_fall_back(self):
        cat_only = self.tool_path("cat-only", include_cat=True, include_grep=False)
        grep_only = self.tool_path("grep-only", include_cat=False, include_grep=True)
        self.compare(
            "missing-grep",
            b"COMPOSE_PROJECT_NAME=ignored\n",
            extra={"PATH": str(cat_only)},
        )
        result = self.compare(
            "missing-cat",
            b"COMPOSE_PROJECT_NAME=pithead-tool\n",
            extra={"PATH": str(grep_only)},
        )
        self.assertEqual(result.stdout, b"pithead-tool")
        self.compare(
            "grep-function",
            b"COMPOSE_PROJECT_NAME=ignored\n",
            extra={"COMPOSE_PROJECT_GREP_RC": "2", "COMPOSE_PROJECT_GREP_PARTIAL": "bad"},
        )

    def test_path_shadowed_cat_and_grep_fall_back(self):
        original_path = os.environ.get("PATH", "")
        cat_tools = self.work("shadow-cat-tools")
        cat_marker = self.directory / "shadow-cat-called"
        cat = cat_tools / "cat"
        cat.write_text(
            "#!/bin/sh\n"
            '":" >"$COMPOSE_PROJECT_FAKE_CAT_MARKER"\n'
            "printf 'COMPOSE_PROJECT_NAME=poisoned'\n"
        )
        cat.chmod(0o755)
        cat_result = self.compare(
            "shadow-cat",
            b"COMPOSE_PROJECT_NAME=pithead-file\n",
            extra={
                "PATH": original_path,
                "COMPOSE_PROJECT_FAKE_CAT_MARKER": str(cat_marker),
                "COMPOSE_PROJECT_HASH_CAT": str(cat),
            },
        )
        self.assertEqual(cat_result.stdout, b"pithead-file")
        self.assertFalse(cat_marker.exists())
        forged_marker = self.directory / "forged-builtins-called"
        forged = self.compare(
            "shadow-cat-forged-builtins",
            b"COMPOSE_PROJECT_NAME=pithead-file\n",
            extra={
                "PATH": str(cat_tools) + os.pathsep + original_path,
                "COMPOSE_PROJECT_FAKE_CAT_MARKER": str(cat_marker),
                "COMPOSE_PROJECT_FORGE_BUILTINS": "1",
                "COMPOSE_PROJECT_FORGED_BUILTIN_MARKER": str(forged_marker),
            },
        )
        self.assertEqual(forged.stdout, b"pithead-file")
        self.assertFalse(cat_marker.exists())
        self.assertFalse(forged_marker.exists())

        grep_tools = self.work("shadow-grep-tools")
        grep_marker = self.directory / "shadow-grep-calls"
        grep = grep_tools / "grep"
        grep.write_text(
            "#!/bin/sh\n"
            "printf 'called\\n' >>\"$COMPOSE_PROJECT_FAKE_GREP_MARKER\"\n"
            'if [ "$COMPOSE_PROJECT_FAKE_GREP_MODE" = valid ]; then\n'
            "    printf 'COMPOSE_PROJECT_NAME=pithead-synthetic\\n'\n"
            "else\n"
            "    printf 'synthetic grep failure\\n' >&2\n"
            "    exit 2\n"
            "fi\n"
        )
        grep.chmod(0o755)
        path = str(grep_tools) + os.pathsep + original_path
        valid = self.compare(
            "shadow-grep-valid",
            b"COMPOSE_PROJECT_NAME=pithead-file\n",
            extra={
                "PATH": path,
                "COMPOSE_PROJECT_FAKE_GREP_MARKER": str(grep_marker),
                "COMPOSE_PROJECT_FAKE_GREP_MODE": "valid",
            },
        )
        self.assertEqual(valid.stdout, b"pithead-synthetic")
        self.assertEqual(grep_marker.read_text().splitlines(), ["called", "called"])
        grep_marker.write_text("")
        failed = self.compare(
            "shadow-grep-failed",
            b"COMPOSE_PROJECT_NAME=pithead-file\n",
            extra={
                "PATH": original_path,
                "COMPOSE_PROJECT_FAKE_GREP_MARKER": str(grep_marker),
                "COMPOSE_PROJECT_FAKE_GREP_MODE": "failed",
                "COMPOSE_PROJECT_HASH_GREP": str(grep),
            },
        )
        self.assertEqual(self.result(failed), (1, b"", b"synthetic grep failure\n"))
        self.assertEqual(grep_marker.read_text().splitlines(), ["called", "called"])

    def test_locale_nocasematch_and_failed_producer_fall_back(self):
        self.compare(
            "locale",
            b"COMPOSE_PROJECT_NAME=pithead-locale\n",
            extra={"LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"},
        )
        result = self.compare(
            "nocasematch",
            b"COMPOSE_PROJECT_NAME=UPPER\n",
            extra={"COMPOSE_PROJECT_NOCASEMATCH": "1"},
        )
        self.assertEqual(result.stdout, b"UPPER")
        tools = self.tool_path("producer-tools", include_cat=False, include_grep=True)
        cat = tools / "cat"
        cat.write_text("#!/bin/sh\nprintf 'COMPOSE_PROJECT_NAME=wrong'\nexit 19\n")
        cat.chmod(0o755)
        result = self.compare(
            "producer-failure",
            b"COMPOSE_PROJECT_NAME=pithead-kept\n",
            extra={"PATH": str(tools)},
        )
        self.assertEqual(result.stdout, b"pithead-kept")

    def test_native_helper_keeps_values_off_argv(self):
        marker = self.directory / "argv"
        wrapper = self.executable(
            "spy",
            "import os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['COMPOSE_PROJECT_ARGV']).write_bytes(b'\\0'.join(os.fsencode(v) for v in sys.argv[1:]))\n"
            "os.execv(os.environ['COMPOSE_PROJECT_REAL_GO'], [os.environ['COMPOSE_PROJECT_REAL_GO'], *sys.argv[1:]])\n",
        )
        project_value = "secret-project-3811"
        result = self.compare(
            "spy",
            b"COMPOSE_PROJECT_NAME=file-secret-3811\n",
            override=project_value,
            binary=wrapper,
            extra={
                "COMPOSE_PROJECT_ARGV": str(marker),
                "COMPOSE_PROJECT_REAL_GO": str(GO_BINARY),
            },
        )
        self.assertEqual(result.stdout, project_value.encode())
        self.assertEqual(marker.read_bytes(), b"")
        self.assertNotIn(project_value.encode(), marker.read_bytes())

    def test_helper_protocol_accepts_valid_and_rejects_bad_frames(self):
        self.assertEqual(
            self.result(
                self.helper([b"COMPOSE_PROJECT_NAME=pithead-frame\n", b"0", b"", b"file", b"0"])
            ),
            (0, b"pithead-frame\0\0" + b"0\0", b""),
        )
        warning = b"COMPOSE_PROJECT_NAME must be a literal lowercase Compose project name."
        self.assertEqual(
            self.result(self.helper([b"", b"1", b"Bad", b"missing", b"0"])),
            (0, b"\0" + warning + b"\0" + b"1\0", b""),
        )
        good = [b"", b"0", b"", b"missing", b"0"]
        cases = [
            good[:-1],
            [*good, b"extra"],
            [b"x\0y", *good[1:]],
            [b"", b"2", b"", b"missing", b"0"],
            [b"", b"0", b"", b"other", b"0"],
            [b"", b"0", b"", b"missing", b"1"],
        ]
        for fields in cases:
            with self.subTest(fields=fields):
                self.assertEqual(self.result(self.helper(fields)), (125, b"", b""))

    def test_malformed_helpers_and_source_only_fall_back(self):
        bodies = {
            "refused": "import sys\nsys.stdin.buffer.read()\nsys.exit(125)\n",
            "failed": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'BAD')\nsys.exit(7)\n",
            "partial": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'native\\0')\n",
            "bad-verdict": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'native\\0\\0x\\0')\n",
            "trailing": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'native\\0\\00\\0extra')\n",
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                helper = self.executable("helper-" + name, body)
                result = self.compare(
                    name,
                    b"COMPOSE_PROJECT_NAME=pithead-fallback\n",
                    binary=helper,
                )
                self.assertEqual(result.stdout, b"pithead-fallback")
        self.compare(
            "source-only",
            b"COMPOSE_PROJECT_NAME=pithead-source\n",
            extra={"COMPOSE_PROJECT_WITHOUT_GO_HOOK": "1"},
        )


if __name__ == "__main__":
    unittest.main()
