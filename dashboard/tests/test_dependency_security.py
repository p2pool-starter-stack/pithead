"""Keep the locked and loaded HTTP transport above the known vulnerable releases."""

import tomllib
from pathlib import Path

import requests
from packaging.version import Version


def test_urllib3_security_floor():
    # Both HIGH advisories are fixed in 2.8.0: CVE-2026-97687 (proxy TLS)
    # and CVE-2026-97689 (unbounded chunk-size lines).
    with (Path(__file__).resolve().parents[1] / "uv.lock").open("rb") as source:
        lock = tomllib.load(source)
    packages = [package for package in lock["package"] if package["name"] == "urllib3"]
    assert packages
    assert all(Version(package["version"]) >= Version("2.8.0") for package in packages)
    assert Version(requests.packages.urllib3.__version__) >= Version("2.8.0")
