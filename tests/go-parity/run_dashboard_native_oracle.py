import os
import subprocess
import sys
from pathlib import Path

# ruff: noqa: S603, S607


ROOT = Path(__file__).resolve().parents[2]
DASHBOARD = ROOT / "dashboard"
PLUGIN = "dashboard_native_oracle_plugin"
FROZEN_ORACLE = "a73ffced33800de9435779a9cabef53864455acb"


def original_tests():
    result = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", FROZEN_ORACLE, "--", "dashboard/tests"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    paths = []
    for name in result.stdout.splitlines():
        path = Path(name)
        if path.suffix == ".py" and path.name.startswith("test"):
            paths.append(str(path.relative_to("dashboard")))
    if not paths:
        raise RuntimeError(f"frozen dashboard oracle is empty at {FROZEN_ORACLE}")
    return paths


def _has_test_selection(arguments):
    for argument in arguments:
        candidate = Path(argument.split("::", 1)[0])
        if argument.endswith(".py") or ".py::" in argument:
            return True
        if not argument.startswith("-") and (DASHBOARD / candidate).exists():
            return True
    return False


def command(arguments):
    for index, argument in enumerate(arguments):
        if argument == "-p" and index + 1 < len(arguments):
            if arguments[index + 1].removeprefix("no:").startswith("dashboard_"):
                raise ValueError("dashboard plugins are owned by the native-oracle launcher")
        if argument.startswith("-p") and argument[2:].removeprefix("no:").startswith("dashboard_"):
            raise ValueError("dashboard plugins are owned by the native-oracle launcher")
    selected = arguments if _has_test_selection(arguments) else [*arguments, *original_tests()]
    return [sys.executable, "-m", "pytest", "-p", PLUGIN, *selected]


def environment(source=None):
    env = dict(os.environ if source is None else source)
    env["PITHEAD_IMPL"] = "go"
    env.pop("PYTEST_PLUGINS", None)
    env.pop("PYTEST_ADDOPTS", None)
    paths = [str(ROOT / "tests/go-parity"), str(DASHBOARD)]
    if current := env.get("PYTHONPATH"):
        paths.append(current)
    env["PYTHONPATH"] = os.pathsep.join(paths)
    env.setdefault("PITHEAD_DASHBOARD_GO_BINARY", str(ROOT / "go/bin/dashboard"))
    return env


def main(arguments=None):
    try:
        pytest_command = command(list(sys.argv[1:] if arguments is None else arguments))
    except ValueError as error:
        print(f"native-oracle: {error}", file=sys.stderr)
        return 2
    return subprocess.run(pytest_command, cwd=DASHBOARD, env=environment(), check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
