import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/env_read_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class EnvReadParityTests(unittest.TestCase):
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

    def environment(self, implementation, *, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            ENV_READ_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
            LC_ALL="C",
            LANG="C",
        )
        env.update(extra or {})
        return env

    def invoke(
        self,
        implementation,
        work,
        operation,
        *,
        fields=(),
        file=None,
        key=b"",
        binary=None,
        extra=None,
    ):
        args = [BASH, str(ADAPTER), str(ROOT), str(work), operation]
        if file is not None:
            args.extend((os.fsdecode(file), os.fsdecode(key)))
        return subprocess.run(  # noqa: S603
            args,
            input=b"\0".join(fields) + (b"\0" if fields else b""),
            env=self.environment(implementation, binary=binary, extra=extra),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def compare_decode(self, name, value, key=b"VALUE", *, binary=None, extra=None):
        expected = self.invoke(
            "bash", self.work(name + "-bash"), "decode", fields=(value, key), extra=extra
        )
        actual = self.invoke(
            "go",
            self.work(name + "-go"),
            "decode",
            fields=(value, key),
            binary=binary,
            extra=extra,
        )
        self.assertEqual(self.result(actual), self.result(expected))
        return actual

    def compare_file(
        self,
        name,
        content,
        key=b"VALUE",
        *,
        filename="values.env",
        binary=None,
        extra=None,
        mode=None,
        shared_work=False,
    ):
        results = []
        shared = self.work(name + "-shared") if shared_work else None
        for implementation in ("bash", "go"):
            work = shared or self.work(name + "-" + implementation)
            path = work / filename
            if content is not None:
                path.write_bytes(content)
                if mode is not None:
                    path.chmod(mode)
            result = self.invoke(
                implementation,
                work,
                "get",
                file=filename if filename.startswith("-") else path,
                key=key,
                binary=binary,
                extra=extra,
            )
            results.append(result)
        expected, actual = results
        self.assertEqual(self.result(actual), self.result(expected))
        return actual

    def executable(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def helper(self, operation, fields):
        env = self.environment("go")
        env["PITHEAD_GO_HELPER"] = "config-env-read"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation],
            input=b"\0".join(fields) + b"\0",
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_unquoted_empty_quoted_and_multibyte_values_match(self):
        cases = [
            ("unquoted", b"plain value"),
            ("empty", b""),
            ("empty-quoted", b'""'),
            ("single-quoted-raw", b"'raw value'"),
            ("multibyte", '"caf\u00e9 \u6f22"'.encode()),
            ("invalid-utf8", b'"bad-\xff-byte"'),
            ("leading-quote-no-close", b'"abc'),
        ]
        for name, value in cases:
            with self.subTest(name=name):
                self.compare_decode(name, value)

    def test_escape_dollar_and_control_values_match(self):
        cases = [
            ("known", b'"line\\ncarriage\\rtab\\tend"'),
            ("unknown", b'"left\\qright"'),
            ("escaped-dollar", b'"left\\$right"'),
            ("double-dollar", b'"left$$right"'),
            ("dollar-mix", b'"$$\\$$$"'),
            ("dangling-backslash", b'"tail\\\\"'),
            ("embedded-controls", b'"a\nb\rc\td"'),
        ]
        for name, value in cases:
            with self.subTest(name=name):
                self.compare_decode(name, value)

    def test_directory_newline_rejection_matches(self):
        for name, value in (("lf", b'"a\\nb"'), ("cr", b'"a\\rb"'), ("literal", b'"a\nb"')):
            with self.subTest(name=name):
                result = self.compare_decode(
                    name, value, b"DATA_DIR", extra={"ENV_READ_ERR_TRAP": "1"}
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"Directory values in .env must not contain CR or LF.", result.stderr)

    def test_file_first_match_duplicates_empty_equals_and_eof_match(self):
        cases = [
            ("first", b"VALUE=one\nVALUE=two\n", b"VALUE"),
            ("empty", b"VALUE=\n", b"VALUE"),
            ("equals", b"VALUE=keep=all=equals\n", b"VALUE"),
            ("missing-key", b"OTHER=x\n", b"VALUE"),
            ("unterminated", b"VALUE=tail", b"VALUE"),
            ("crlf", b"VALUE=tail\r\n", b"VALUE"),
            ("quoted", b'VALUE="a\\n$$b"\n', b"VALUE"),
        ]
        for name, content, key in cases:
            with self.subTest(name=name):
                self.compare_file(name, content, key)

    def test_regex_and_non_ascii_keys_preserve_grep_semantics(self):
        cases = [
            ("regex-dot", b"AB=regex\n", b"A.*"),
            ("regex-bracket", b"A1=regex\n", b"A[0-9]"),
            ("regex-anchor", b"VALUE=literal\n", b"VALUE$"),
            ("invalid-byte", b"\xff=raw\n", b"\xff"),
        ]
        for name, content, key in cases:
            with self.subTest(name=name):
                self.compare_file(name, content, key)

    def test_missing_nonregular_unreadable_binary_and_dash_paths_match(self):
        self.compare_file("missing", None)
        self.compare_file("unreadable", b"VALUE=hidden\n", mode=0)
        self.compare_file("binary", b"VALUE=before\0after\n", shared_work=True)
        self.compare_file("dash", b"VALUE=option\n", filename="-dash.env")
        results = []
        for implementation in ("bash", "go"):
            work = self.work("directory-" + implementation)
            path = work / "values.env"
            path.mkdir()
            results.append(self.invoke(implementation, work, "get", file=path, key=b"VALUE"))
        self.assertEqual(self.result(results[1]), self.result(results[0]))

    def test_literal_file_keys_use_native_helper(self):
        marker = self.directory / "argv"
        wrapper = self.executable(
            "spy",
            "import os, sys\n"
            "from pathlib import Path\n"
            "with Path(os.environ['ENV_READ_ARGV']).open('ab') as stream:\n"
            "    stream.write(b'\\0'.join(os.fsencode(v) for v in sys.argv[1:]) + b'\\n')\n"
            "os.execv(os.environ['ENV_READ_REAL_BINARY'], [os.environ['ENV_READ_REAL_BINARY'], *sys.argv[1:]])\n",
        )
        secret = b"value-secret-3811"
        result = self.compare_file(
            "spy-get",
            b"VALUE=" + secret + b"\n",
            binary=wrapper,
            extra={"ENV_READ_ARGV": str(marker), "ENV_READ_REAL_BINARY": str(GO_BINARY)},
        )
        self.assertEqual(result.stdout, secret)
        self.assertEqual(marker.read_bytes().splitlines(), [b"get"])
        self.assertNotIn(secret, marker.read_bytes())

    def test_decode_uses_native_helper_and_keeps_secret_off_argv(self):
        marker = self.directory / "decode-argv"
        wrapper = self.executable(
            "decode-spy",
            "import os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['ENV_READ_ARGV']).write_bytes(b'\\0'.join(os.fsencode(v) for v in sys.argv[1:]))\n"
            "os.execv(os.environ['ENV_READ_REAL_BINARY'], [os.environ['ENV_READ_REAL_BINARY'], *sys.argv[1:]])\n",
        )
        secret = b'"decode-secret-3811"'
        result = self.compare_decode(
            "spy-decode",
            secret,
            binary=wrapper,
            extra={"ENV_READ_ARGV": str(marker), "ENV_READ_REAL_BINARY": str(GO_BINARY)},
        )
        self.assertEqual(result.stdout, b"decode-secret-3811")
        self.assertEqual(marker.read_bytes(), b"decode")
        self.assertNotIn(secret, marker.read_bytes())

    def test_source_only_and_failed_file_producer_fall_back(self):
        self.compare_decode(
            "source-only-decode", b'"a\\nb"', extra={"ENV_READ_WITHOUT_GO_HOOK": "1"}
        )
        self.compare_file(
            "source-only-get", b"VALUE=kept\n", extra={"ENV_READ_WITHOUT_GO_HOOK": "1"}
        )
        result = self.compare_file(
            "producer-failed",
            b"VALUE=kept\n",
            extra={"ENV_READ_CAT_RC": "19", "ENV_READ_CAT_PARTIAL": "VALUE=wrong"},
        )
        self.assertEqual(result.stdout, b"kept")

    def test_missing_grep_with_available_cat_preserves_reference(self):
        path = self.directory / "cat-only"
        path.mkdir()
        cat = shutil.which("cat")
        if cat is None:
            self.skipTest("cat is required")
        (path / "cat").symlink_to(cat)
        result = self.compare_file(
            "missing-grep",
            b"VALUE=native-must-fall-back\n",
            extra={"PATH": str(path)},
        )
        self.assertEqual(result.stdout, b"")

    def test_helper_protocol_accepts_valid_frames_and_rejects_bad_ones(self):
        self.assertEqual(
            self.result(self.helper("decode", [b'"a\\nb"', b"VALUE", b"0"])),
            (0, b"a\nb\0\0" + b"0\0", b""),
        )
        self.assertEqual(
            self.result(self.helper("get", [b"VALUE=one\n", b"0", b"VALUE"])),
            (0, b"one\0\0" + b"0\0", b""),
        )
        good_decode = [b'"x"', b"VALUE", b"0"]
        good_get = [b"VALUE=x\n", b"0", b"VALUE"]
        cases = [
            ("decode", good_decode[:-1]),
            ("decode", [*good_decode, b"extra"]),
            ("decode", [b'"x"', b"VALUE", b"1"]),
            ("decode", [b'"x"', b"VALUE", b"00"]),
            ("get", good_get[:-1]),
            ("get", [*good_get, b"extra"]),
            ("get", [b"VALUE=x\n", b"9", b"VALUE"]),
            ("get", [b"VALUE=x\0bad", b"0", b"VALUE"]),
            ("get", [b"VALUE=x\n", b"0", b"A.*"]),
        ]
        for operation, fields in cases:
            with self.subTest(operation=operation, fields=fields):
                self.assertEqual(self.result(self.helper(operation, fields)), (125, b"", b""))

    def test_malformed_partial_trailing_and_failed_helpers_fall_back(self):
        bodies = {
            "refused": "import sys\nsys.stdin.buffer.read()\nsys.exit(125)\n",
            "failed": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'BAD')\nsys.exit(7)\n",
            "partial": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'native\\0')\n",
            "bad-status": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'native\\x00\\x00' + b'1\\x00')\n",
            "trailing": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'native\\x00\\x00' + b'0\\x00extra')\n",
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                helper = self.executable("helper-" + name, body)
                decoded = self.compare_decode(
                    name + "-decode", b'"fallback\\nvalue"', binary=helper
                )
                fetched = self.compare_file(name + "-get", b"VALUE=fallback\n", binary=helper)
                self.assertNotIn(
                    b"BAD", decoded.stdout + decoded.stderr + fetched.stdout + fetched.stderr
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
