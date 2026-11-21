import glob
import pathlib
import re

ROOT = pathlib.Path(".")
ENTRY = re.compile(r'(?m)^  - package-ecosystem: "([a-z-]+)"\n')
DIR_LIST_ITEM = re.compile(r'^\s{6}- "(/[^"]+)"$', re.M)
DIR_SINGLE = re.compile(r'^\s*directory: "(/[^"]*)"$', re.M)
COPY_FROM = re.compile(r"--from=([^\s]+)")
IGNORE_KEY = re.compile(r"(?m)^    ignore:$")
LABELS_KEY = re.compile(r"(?m)^    labels:")
DEPENDENCY_NAME = re.compile(r'dependency-name: "([^"]+)"')
UV_STAGE = re.compile(r"(?m)^FROM ghcr\.io/astral-sh/uv:[0-9][^\s]* AS uv$")


def read(path):
    return (ROOT / path).read_text()


def entries(text):
    parts = ENTRY.split(text)
    return list(zip(parts[1::2], parts[2::2], strict=True))


def directories(body):
    return DIR_SINGLE.findall(body) + DIR_LIST_ITEM.findall(body)


def manifest_ok(ecosystem, directory):
    if "*" in directory:
        matched = [pathlib.Path(p) for p in glob.glob(f".{directory}")]
        if not matched:
            return f"{ecosystem} directory glob {directory} matches no directory"
    else:
        matched = [pathlib.Path(f".{directory}")]
    for path in matched:
        if ecosystem == "docker" and not (path / "Dockerfile").is_file():
            return f"docker entry {directory} has no Dockerfile"
        if ecosystem == "docker-compose" and not (
            list(path.glob("docker-compose*.y*ml")) or list(path.glob("compose*.y*ml"))
        ):
            return f"docker-compose entry {directory} has no compose file"
        if ecosystem == "github-actions" and path == pathlib.Path("."):
            if not (ROOT / ".github/workflows").is_dir():
                return "github-actions root entry has no .github/workflows"
        if ecosystem == "github-actions" and path != pathlib.Path("."):
            if not ((path / "action.yml").is_file() or (path / "action.yaml").is_file()):
                return f"github-actions entry {directory} has no action.yml"
        if ecosystem == "pre-commit" and not (path / ".pre-commit-config.yaml").is_file():
            return f"pre-commit entry {directory} has no .pre-commit-config.yaml"
        if ecosystem == "uv" and not (path / "pyproject.toml").is_file():
            return f"uv entry {directory} has no pyproject.toml"
        if ecosystem == "npm" and not (path / "package.json").is_file():
            return f"npm entry {directory} has no package.json"
    return None


def check_entries(text, problems):
    rows = entries(text)
    by_eco = {}
    for ecosystem, body in rows:
        by_eco.setdefault(ecosystem, []).append(body)
    if LABELS_KEY.search(text):
        problems.append("entries must keep the default `dependencies` label (no labels: key)")
    actions = by_eco.get("github-actions", [])
    if not any("/.github/actions/*" in directories(body) for body in actions):
        problems.append("github-actions must cover the composite actions via /.github/actions/*")
    dockers = by_eco.get("docker", [])
    tracked = [
        d
        for d in ("/tests/runner", "/tests/integration/mergemine")
        if any(d in directories(body) and not IGNORE_KEY.search(body) for body in dockers)
    ]
    for name in ("/tests/runner", "/tests/integration/mergemine"):
        if name not in tracked:
            problems.append(f"{name} must sit in a docker entry without an ignore block")
    for body in dockers:
        if IGNORE_KEY.search(body) and "/tests/runner" in directories(body):
            problems.append(
                "/tests/runner must not sit in the ignore-blocked shipped-image docker entry"
            )
    compose = by_eco.get("docker-compose", [])
    mini = [body for body in compose if "/tests/integration/mini-stack" in directories(body)]
    if not mini:
        problems.append("a docker-compose entry for /tests/integration/mini-stack must exist")
    elif not set(DEPENDENCY_NAME.findall(mini[0])) <= {"pithead-dashboard"}:
        problems.append(
            "the mini-stack docker-compose entry may ignore only the locally built pithead-dashboard image"
        )
    if not any("/" in directories(body) for body in compose):
        problems.append("the root docker-compose.yml entry must stay in place")
    if not any(directories(body) == ["/"] for body in by_eco.get("pre-commit", [])):
        problems.append("a pre-commit entry for / must exist")
    for ecosystem, body in rows:
        for directory in directories(body):
            problem = manifest_ok(ecosystem, directory)
            if problem:
                problems.append(problem)


def check_rootfs(text, problems):
    if "go env GOVERSION" not in text:
        problems.append(
            "os/rootfs go-version guards must read `go env GOVERSION` from the builder image"
        )
    if "go1." in text:
        problems.append("os/rootfs must not hard-code a go1.x toolchain literal")


def check_uv_stage(text, name, problems):
    if not UV_STAGE.search(text):
        problems.append(
            f"{name} must pin uv as a named `FROM ghcr.io/astral-sh/uv:<pin> AS uv` stage"
        )
    if "--from=uv " not in text:
        problems.append(f"{name} must COPY --from=uv")


def check_copy_from(dockerfiles, problems):
    for path in dockerfiles:
        for ref in COPY_FROM.findall(re.sub(r"(?m)^\s*#.*$", "", path.read_text())):
            if "/" in ref or "." in ref:
                problems.append(
                    f"{path}: COPY --from={ref} is an image reference; Dependabot only reads FROM"
                )


def main():
    problems = []
    check_entries(read(".github/dependabot.yml"), problems)
    check_rootfs(read("os/rootfs/Dockerfile"), problems)
    check_uv_stage(read("dashboard/Dockerfile"), "dashboard/Dockerfile", problems)
    check_uv_stage(read("tests/runner/Dockerfile"), "tests/runner/Dockerfile", problems)
    dockerfiles = [
        p for p in sorted(ROOT.rglob("Dockerfile*")) if ".git" not in p.parts and p.is_file()
    ]
    check_copy_from(dockerfiles, problems)
    if problems:
        for problem in problems:
            print(f"dependabot coverage: {problem}")
        raise SystemExit(1)
    print("dependabot coverage: all surfaces tracked, no Dependabot-invisible pins")


if __name__ == "__main__":
    main()
