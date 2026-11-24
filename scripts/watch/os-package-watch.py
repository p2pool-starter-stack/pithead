import concurrent.futures
import http.client
import json
import sys
import time

OSV_HOST = "api.osv.dev"
OSV_QUERY = "/v1/query"
MAX_IDS = 5


def parse(text):
    packages = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 4:
            raise ValueError(
                f"line {number}: expected '<image> <ecosystem> <package> <version>', got {line!r}"
            )
        image, ecosystem, name, version = fields
        packages.setdefault((ecosystem, name, version), set()).add(image)
    if not packages:
        raise ValueError("the package list is empty")
    return packages


def post(path, body, attempts=3):
    for attempt in range(attempts):
        connection = http.client.HTTPSConnection(OSV_HOST, timeout=30)
        try:
            connection.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})
            response = connection.getresponse()
            payload = response.read()
            if response.status != 200:
                raise OSError(f"OSV answered HTTP {response.status}")
            return json.loads(payload)
        except (OSError, ValueError):
            if attempt == attempts - 1:
                raise
            time.sleep(2**attempt)
        finally:
            connection.close()


def query(ecosystem, name, version, send=post):
    body = {"package": {"ecosystem": ecosystem, "name": name}, "version": version}
    vulns = []
    while True:
        answer = send(OSV_QUERY, body)
        vulns.extend(answer.get("vulns", []))
        token = answer.get("next_page_token")
        if not token:
            return vulns
        body = {**body, "page_token": token}


def fixed_in(vuln, ecosystem, name):
    return sorted(
        {
            event["fixed"]
            for affected in vuln.get("affected", [])
            if affected.get("package", {}).get("ecosystem") == ecosystem
            and affected.get("package", {}).get("name") == name
            for rng in affected.get("ranges", [])
            for event in rng.get("events", [])
            if "fixed" in event
        }
    )


def check(packages, send=post, workers=8):
    findings, unchecked = [], []

    def one(key):
        ecosystem, name, version = key
        fixes = {}
        for vuln in query(ecosystem, name, version, send):
            fixed = fixed_in(vuln, ecosystem, name)
            if fixed:
                fixes[vuln["id"]] = fixed
        return fixes

    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        futures = {pool.submit(one, key): key for key in packages}
        for future, key in futures.items():
            try:
                fixes = future.result()
            except Exception as error:
                unchecked.append((key, f"{type(error).__name__}: {error}"))
                continue
            if fixes:
                findings.append((key, fixes))
    return sorted(findings), sorted(unchecked)


def report(tag, packages, findings, unchecked):
    lines = [
        f"Installed OS packages of release {tag}, checked weekly against OSV advisories by "
        "`scripts/watch/os-package-watch.py`. A row is an installed package with advisories "
        "the distribution has fixed in a newer package, so rebuilding the listed images picks the fixes up. This never bumps anything.",
        "",
        f"{len(findings)} of {len(packages)} recorded source packages need a rebuild.",
    ]
    if findings:
        lines += [
            "",
            "| image | ecosystem | package | installed | fixed advisories |",
            "|---|---|---|---|---|",
        ]
        for (ecosystem, name, version), fixes in findings:
            ids = sorted(fixes)
            shown = ", ".join(ids[:MAX_IDS]) + (
                f" and {len(ids) - MAX_IDS} more" if len(ids) > MAX_IDS else ""
            )
            images = ", ".join(sorted(packages[(ecosystem, name, version)]))
            lines.append(f"| {images} | {ecosystem} | {name} | {version} | {len(ids)}: {shown} |")
    if unchecked:
        lines += [
            "",
            f"**UNCHECKED:** {len(unchecked)} lookups failed, so those packages are not known to be clean.",
            "",
        ]
        lines += [
            f"- {ecosystem} {name} {version}: {error}"
            for (ecosystem, name, version), error in unchecked
        ]
    lines += ["", f"<!-- os-package-watch: fixable={len(findings)} unchecked={len(unchecked)} -->"]
    return "\n".join(lines)


def main(argv):
    if len(argv) != 3:
        print("usage: os-package-watch.py <release-tag> <os-packages.txt>", file=sys.stderr)
        return 2
    tag, path = argv[1], argv[2]
    with open(path, encoding="utf-8") as handle:
        packages = parse(handle.read())
    findings, unchecked = check(packages)
    print(report(tag, packages, findings, unchecked))
    return 1 if unchecked else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
