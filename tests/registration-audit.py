import re
import sys
from pathlib import Path

PATH = re.compile(
    r"(?:\$\{?(?:HERE|ROOT|SCRIPT_DIR|REPO_ROOT|TEST_DIR)\}?/|(?:\.?\.?/)?(?:tests|dashboard|scripts|build|os|\.github)/)[^\s\"'`;|&()<>{}]+"
)
SUFFIXES = {".sh", ".py", ".mjs"}


def candidates(root):
    return {
        p.relative_to(root).as_posix()
        for base in ("tests", "dashboard/tests", "scripts", "build", "os")
        for p in (root / base).rglob("*")
        if p.is_file()
        and p.suffix in SUFFIXES
        and not any(x in p.parts for x in ("node_modules", ".venv", "fixtures", "__pycache__"))
        and (
            p.name.startswith(("test", "selftest"))
            or p.name.endswith((".test.mjs", "-selftest.sh"))
            or (p.suffix == ".sh" and "--self-test)" in p.read_text())
        )
    }


def make_targets(root):
    result = {}
    current = None
    for line in (root / "Makefile").read_text().splitlines():
        m = re.match(r"^([\w-]+):([^=]*)$", line)
        if m:
            current = m[1]
            result[current] = m[2].split("#")[0] + "\n"
        elif line.startswith("\t") and current:
            result[current] += line[1:] + "\n"
        elif line and not line.startswith("#"):
            current = None
    return result


def references(root, text, parent):
    for line in text.splitlines():
        line = line.replace("${BASH_SOURCE[0]%/*}/", "$TEST_DIR/")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.search(r"(?:^|[;&])\s*(?:source|\.)\s", stripped):
            continue
        for m in PATH.finditer(line):
            prefix = line[: m.start()].strip()
            prefix = re.sub(r'^[A-Z_]+="[^\"]*"\s+', "", prefix)
            if not re.search(
                r"^(?:(?:run:|if|!|exec)\s+)*(?:bash|python3?(?: -m unittest -q)?|node(?: --test)?|pytest|for \w+ in)\s*[\"\']?$",
                prefix,
            ) and prefix not in ("", "run:", "./"):
                continue
            value = m.group().rstrip(",:")
            if "$" in value:
                if value.startswith(("$ROOT/", "${ROOT}/", "$REPO_ROOT/", "${REPO_ROOT}/")):
                    value = value.split("/", 1)[1]
                else:
                    value = str(parent / value.split("/", 1)[1])
            value = str(Path(value))
            if Path(value).is_absolute() or ".." in Path(value).parts:
                continue
            for p in root.glob(value):
                if p.is_file():
                    yield p.relative_to(root).as_posix()
        if "pytest" in line and "test-dashboard" in text:
            yield from (
                p.relative_to(root).as_posix()
                for p in (root / "dashboard/tests").rglob("test_*.py")
            )
        if "node --test" in line and "dashboard/tests/frontend" in text:
            yield from (
                p.relative_to(root).as_posix()
                for p in (root / "dashboard/tests/frontend").rglob("*.test.mjs")
            )
        if "playwright test" in line:
            yield from (
                p.relative_to(root).as_posix()
                for p in (root / "dashboard/tests/browser").glob("*.test.mjs")
            )


def audit(root):
    targets = make_targets(root)
    workflow_text = "\n".join(p.read_text() for p in (root / ".github/workflows").glob("*.yml"))
    pending = [(workflow_text, Path("."))]
    reached = set()
    used_targets = set()
    while pending:
        text, parent = pending.pop()
        text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for match in re.finditer(r"(?:^|&&|;|run:)\s*make\s+([^\n;|]+)", text, re.MULTILINE):
            for target in match[1].split():
                if target in targets and target not in used_targets:
                    used_targets.add(target)
                    pending.append((target + "\n" + targets[target], Path(".")))
        if text.splitlines()[0:1] and text.splitlines()[0] in targets:
            for dep in targets[text.splitlines()[0]].splitlines()[0].split():
                if dep in targets and dep not in used_targets:
                    used_targets.add(dep)
                    pending.append((dep + "\n" + targets[dep], Path(".")))
        for name in references(root, text, parent):
            if name in reached:
                continue
            reached.add(name)
            if name == "tests/stack/run.sh":
                for fragment in (root / "tests/stack").rglob("*.sh"):
                    if "standalone" not in fragment.parts:
                        reached.add(fragment.relative_to(root).as_posix())
                        pending.append((fragment.read_text(), fragment.relative_to(root).parent))
            if Path(name).suffix in SUFFIXES:
                pending.append(((root / name).read_text(), Path(name).parent))
    expected = candidates(root)
    allowlist = root / "tests/registration-allowlist.tsv"
    entries = []
    if allowlist.exists():
        entries = [line.split("\t") for line in allowlist.read_text().splitlines()]
    for entry in entries:
        if len(entry) != 3 or not entry[2].strip() or entry[0] not in expected:
            raise ValueError(f"stale or invalid registration exception: {entry}")
        name, caller, reason = entry
        if (
            name in reached
            or not (root / caller).is_file()
            or not any(
                Path(name).name in line and not line.lstrip().startswith("#")
                for line in (root / caller).read_text().splitlines()
            )
        ):
            raise ValueError(f"stale registration exception: {name}")
    while entries:
        remaining = []
        for name, caller, reason in entries:
            if caller in reached:
                reached.add(name)
            else:
                remaining.append((name, caller, reason))
        if len(entries) == len(remaining):
            raise ValueError("registration exceptions have no CI-reachable caller")
        entries = remaining
    return sorted(expected - reached)


if __name__ == "__main__":
    missing = audit(Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
    for name in missing:
        print(f"unregistered test: {name}")
    if missing:
        raise SystemExit(1)
    print("test registration audit: PASS")
