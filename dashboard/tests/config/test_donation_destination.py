import hashlib
import importlib
import json
import re
import subprocess
from pathlib import Path

import pytest

from mining_dashboard.config import donation_destination
from mining_dashboard.config.donation_destination import load_destination

DESTINATION = Path(donation_destination.__file__).with_name("donation.json")
DESTINATION_SHA256 = "094fff4a8f5c173f52056dec0247f9ee4388da9adb7bd86ca5be3134db49b195"
ROOT = Path(__file__).resolve().parents[3]
DOCS = ("README.md", "docs/donation.md", "docs/privacy.md")
PRIMARY = "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"


@pytest.fixture
def destination():
    return {
        "recipient": "Pithead",
        "project_address": PRIMARY,
        "endpoint": "a" * 56 + ".onion:3333",
        "kind": "onion",
        "tls_fingerprint": "",
    }


def write_destination(tmp_path, data):
    path = tmp_path / "donation.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def assert_provenance(content):
    assert hashlib.sha256(content).hexdigest() == DESTINATION_SHA256, (
        "donation.json changes require an owner-approved PR and an updated SHA-256 pin"
    )


def assert_no_drift(address, documents):
    for name, text in documents.items():
        addresses = re.findall(
            r"\b[48][1-9A-HJ-NP-Za-km-z]{94}(?:[1-9A-HJ-NP-Za-km-z]{11})?\b", text
        )
        assert all(found == address for found in addresses), f"project_address drift in {name}"


def test_shipped_destination_is_empty_and_unavailable():
    assert set(json.loads(DESTINATION.read_text()).values()) == {""}
    result = load_destination()
    assert result["available"] is False
    assert result["reason"]


def test_valid_onion(tmp_path, destination):
    assert load_destination(write_destination(tmp_path, destination)) == {
        "available": True,
        **destination,
    }
    del destination["tls_fingerprint"]
    assert load_destination(write_destination(tmp_path, destination))["tls_fingerprint"] == ""


@pytest.mark.parametrize("host,port", [("donation.example", 1), ("192.0.2.1", 65535)])
def test_valid_clearnet(tmp_path, destination, host, port):
    destination.update(kind="clearnet", endpoint=f"{host}:{port}", tls_fingerprint="aB" * 32)
    assert load_destination(write_destination(tmp_path, destination)) == {
        "available": True,
        **destination,
    }


@pytest.mark.parametrize(
    "field,value",
    [
        ("recipient", ""),
        ("recipient", " " * 3),
        ("recipient", "x" * 41),
        ("recipient", "bad\nrecipient"),
        ("project_address", PRIMARY[:-1]),
        ("project_address", "8" + PRIMARY[1:]),
        ("project_address", "4" + "0" * 94),
        ("endpoint", "a" * 55 + ".onion:3333"),
        ("endpoint", "1" * 56 + ".onion:3333"),
        ("endpoint", "a" * 56 + ".onion:0"),
        ("endpoint", "a" * 56 + ".onion:65536"),
        ("endpoint", "a" * 56 + ".onion:-1"),
        ("endpoint", "a" * 56 + ".onion:3x"),
        ("endpoint", "a" * 56 + ".onion"),
        ("endpoint", "stratum://host:3333"),
        ("kind", "unknown"),
        ("tls_fingerprint", "ab" * 32),
    ],
)
def test_invalid_fields_are_value_free(tmp_path, destination, field, value):
    destination[field] = value
    result = load_destination(write_destination(tmp_path, destination))
    assert result["available"] is False
    assert field in result["reason"]
    assert set(result) == {"available", "reason"}
    assert not value or value not in result["reason"]


@pytest.mark.parametrize(
    "field", ["recipient", "project_address", "endpoint", "kind", "tls_fingerprint"]
)
@pytest.mark.parametrize("value", [None, 42, True, [], {}])
def test_invalid_types(tmp_path, destination, field, value):
    destination[field] = value
    result = load_destination(write_destination(tmp_path, destination))
    assert result == {"available": False, "reason": f"{field} must be a string"}


@pytest.mark.parametrize("field", ["recipient", "project_address", "endpoint", "kind"])
def test_missing_fields(tmp_path, destination, field):
    del destination[field]
    assert field in load_destination(write_destination(tmp_path, destination))["reason"]


@pytest.mark.parametrize("fingerprint", ["", "a" * 63, "z" * 64])
def test_clearnet_requires_fingerprint(tmp_path, destination, fingerprint):
    destination.update(
        kind="clearnet", endpoint="donation.example:3333", tls_fingerprint=fingerprint
    )
    result = load_destination(write_destination(tmp_path, destination))
    assert result == {
        "available": False,
        "reason": "tls_fingerprint must contain 64 hex characters",
    }
    del destination["tls_fingerprint"]
    assert load_destination(write_destination(tmp_path, destination)) == result


@pytest.mark.parametrize(
    "host",
    [
        "bad host",
        "-bad.example",
        "bad..example",
        "user@host",
        "a" * 64 + ".example",
        "a" * 56 + ".onion",
        ".",
        "a." * 128 + "example",
    ],
)
def test_invalid_clearnet_host(tmp_path, destination, host):
    destination.update(kind="clearnet", endpoint=f"{host}:3333", tls_fingerprint="ab" * 32)
    assert load_destination(write_destination(tmp_path, destination)) == {
        "available": False,
        "reason": "endpoint must contain a valid clearnet host",
    }


@pytest.mark.parametrize("content", ["{", "[]", "null", "42", '"secret"', b"\xff"])
def test_invalid_files(tmp_path, content):
    path = tmp_path / "donation.json"
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    result = load_destination(path)
    assert result["available"] is False
    assert "donation file" in result["reason"]
    assert "secret" not in result["reason"]


def test_unreadable_file_and_import(tmp_path, monkeypatch):
    def refuse(*args, **kwargs):
        raise PermissionError("sensitive path")

    monkeypatch.setattr(Path, "read_text", refuse)
    importlib.reload(donation_destination)
    assert load_destination(tmp_path / "absent") == {
        "available": False,
        "reason": "donation file is unreadable or invalid",
    }


def test_environment_has_no_effect(tmp_path, destination, monkeypatch):
    path = write_destination(tmp_path, destination)
    before = (load_destination(), load_destination(path))
    for prefix in ("DONATION", "XVB", "P2POOL"):
        for field in (*destination, "PATH", "CONFIG", "JSON"):
            monkeypatch.setenv(f"{prefix}_{field.upper()}", "untrusted")
    assert (load_destination(), load_destination(path)) == before
    source = Path(donation_destination.__file__).read_text()
    assert "os.environ" not in source
    assert "getenv" not in source


def test_provenance_pin():
    assert_provenance(DESTINATION.read_bytes())


def test_provenance_rejects_byte_change():
    with pytest.raises(AssertionError, match="owner-approved PR"):
        assert_provenance(DESTINATION.read_bytes() + b"\n")


def test_shipped_documentation_drift():
    address = json.loads(DESTINATION.read_text())["project_address"]
    if not address:
        pytest.skip("project_address drift skipped: empty; no documentation checked")
    assert_no_drift(address, {name: (ROOT / name).read_text() for name in DOCS})


@pytest.mark.parametrize("name", DOCS)
def test_documentation_drift_detects_every_occurrence(name):
    assert_no_drift(PRIMARY, {name: f"Address: {PRIMARY}\nRepeated: {PRIMARY}"})
    other = "4" + "a" * 94
    with pytest.raises(AssertionError, match="project_address drift"):
        assert_no_drift(PRIMARY, {name: f"Address: {PRIMARY}\nOther: {other}"})


def test_only_loader_reads_destination():
    result = subprocess.run(
        [
            "/usr/bin/git",
            "grep",
            "-l",
            "-F",
            "donation.json",
            "--",
            ".",
            ":(exclude)tests/**",
            ":(exclude)**/tests/**",
            ":(exclude)docs/**",
            ":(exclude)*.md",
            ":(exclude)**/*.md",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    )
    assert result.stdout.splitlines() == [
        "dashboard/mining_dashboard/config/donation_destination.py"
    ]
