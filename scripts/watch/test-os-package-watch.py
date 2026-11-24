import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "os_package_watch", pathlib.Path(__file__).with_name("os-package-watch.py")
)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

LIST = """\
tor Alpine:v3.24 openssl 3.5.4-r0
tor Alpine:v3.24 musl 1.2.5-r10
monero Ubuntu:24.04:LTS openssl 3.0.13-0ubuntu3.5
p2pool Ubuntu:24.04:LTS openssl 3.0.13-0ubuntu3.5
os-rootfs Debian:13 glibc 2.41-12

"""

FIXED = {
    "id": "ALPINE-CVE-2025-1",
    "affected": [
        {
            "package": {"ecosystem": "Alpine:v3.24", "name": "openssl"},
            "ranges": [
                {"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "3.5.5-r0"}]}
            ],
        },
        {
            "package": {"ecosystem": "Alpine:v3.23", "name": "openssl"},
            "ranges": [
                {"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "3.5.1-r0"}]}
            ],
        },
    ],
}
UNFIXED = {
    "id": "UBUNTU-CVE-2025-2",
    "affected": [
        {
            "package": {"ecosystem": "Ubuntu:24.04:LTS", "name": "openssl"},
            "ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "0"}]}],
        }
    ],
}
OTHER_RELEASE_ONLY = {
    "id": "DEBIAN-CVE-2025-3",
    "affected": [
        {
            "package": {"ecosystem": "Debian:12", "name": "glibc"},
            "ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "2.36-9"}]}],
        }
    ],
}

calls = []


def fake_send(url, body):
    calls.append(body)
    package = body["package"]
    key = (package["ecosystem"], package["name"], body["version"])
    if key == ("Alpine:v3.24", "musl", "1.2.5-r10"):
        raise OSError("connection reset")
    if key == ("Alpine:v3.24", "openssl", "3.5.4-r0"):
        if "page_token" not in body:
            return {"vulns": [], "next_page_token": "p2"}
        return {"vulns": [FIXED]}
    if key[1] == "openssl":
        return {"vulns": [UNFIXED]}
    return {"vulns": [OTHER_RELEASE_ONLY]}


failures = []


def expect(name, condition):
    print(("  ok: " if condition else "  FAIL: ") + name)
    if not condition:
        failures.append(name)


packages = watch.parse(LIST)
expect(
    "parse merges identical packages across images",
    packages[("Ubuntu:24.04:LTS", "openssl", "3.0.13-0ubuntu3.5")] == {"monero", "p2pool"},
)
expect("parse keys one lookup per ecosystem, package and version", len(packages) == 4)
for bad in ("tor Alpine:v3.24 openssl\n", "", "\n\n"):
    try:
        watch.parse(bad)
        expect(f"parse refuses {bad!r}", False)
    except ValueError:
        expect(f"parse refuses {bad!r}", True)

findings, unchecked = watch.check(packages, send=fake_send, workers=2)
expect(
    "only an advisory fixed for the same ecosystem and package is a rebuild need",
    [k for k, _ in findings] == [("Alpine:v3.24", "openssl", "3.5.4-r0")],
)
expect(
    "the fixed version comes from the matching ecosystem",
    findings[0][1] == {"ALPINE-CVE-2025-1": ["3.5.5-r0"]},
)
expect(
    "a paged answer is followed to its last page", any(c.get("page_token") == "p2" for c in calls)
)
expect(
    "a failed lookup is reported unchecked, not clean",
    [k for k, _ in unchecked] == [("Alpine:v3.24", "musl", "1.2.5-r10")],
)

text = watch.report("v9.9.9", packages, findings, unchecked)
expect(
    "the report has one table row per finding",
    "| tor | Alpine:v3.24 | openssl | 3.5.4-r0 | 1: ALPINE-CVE-2025-1 |\n" in text + "\n",
)
expect(
    "the report names the unchecked package",
    "- Alpine:v3.24 musl 1.2.5-r10: OSError: connection reset" in text,
)
expect(
    "the report carries the machine-readable counts",
    text.endswith("<!-- os-package-watch: fixable=1 unchecked=1 -->"),
)

many = {f"X-{i}": ["2"] for i in range(7)}
text = watch.report("v9.9.9", {("E", "p", "1"): {"a", "b"}}, [(("E", "p", "1"), many)], [])
expect("a long advisory list is cut to five ids", "7: X-0, X-1, X-2, X-3, X-4 and 2 more" in text)
expect("a shared package lists every image", "| a, b | E | p | 1 | 7:" in text)
expect(
    "a clean run reports zero findings",
    watch.report("v9.9.9", packages, [], []).endswith("fixable=0 unchecked=0 -->"),
)

if failures:
    sys.exit(f"os-package-watch test: {len(failures)} failed")
print("os-package-watch test OK")
