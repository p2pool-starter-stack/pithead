import ssl
import tomllib
from pathlib import Path

import certifi
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


def test_certifi_security_floor():
    with (Path(__file__).resolve().parents[1] / "uv.lock").open("rb") as source:
        lock = tomllib.load(source)
    packages = [package for package in lock["package"] if package["name"] == "certifi"]
    assert packages
    assert all(Version(package["version"]) >= Version("2026.10.19") for package in packages)
    assert Version(certifi.__version__) >= Version("2026.10.19")


def test_virtualenv_security_floor():
    with (Path(__file__).resolve().parents[1] / "uv.lock").open("rb") as source:
        lock = tomllib.load(source)
    packages = [package for package in lock["package"] if package["name"] == "virtualenv"]
    assert packages
    assert all(Version(package["version"]) >= Version("21.14.9") for package in packages)


def test_requests_bundle_excludes_compromised_emsign_root():
    certificates = ssl.create_default_context(cafile=requests.certs.where()).get_ca_certs()
    assert certificates
    common_names = {
        value
        for certificate in certificates
        for rdn in certificate["subject"]
        for key, value in rdn
        if key == "commonName"
    }
    assert "emSign ECC Root CA - G3" not in common_names
