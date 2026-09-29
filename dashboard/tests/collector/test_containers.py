import json
from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import mining_dashboard.collector.containers as containers
from mining_dashboard.helper.http import MAX_RESPONSE_BYTES


class _AsyncCM:
    def __init__(self, value):
        self._value = value

    async def __aenter__(self):
        return self._value

    async def __aexit__(self, *exc):
        return False


class _Stream:
    """An aiohttp ``StreamReader``. ``read(n)`` is a SHORT read — it hands back what is buffered,
    never necessarily ``n`` bytes — and modelling that is the whole point: a bounded read written as
    a single ``read(cap)`` passes a fake that returns everything at once, then truncates any real
    body that arrives split across TCP reads. Same idiom as tests/client/test_summary_size_cap.py."""

    def __init__(self, raw, chunk=1024):
        self._raw, self._pos, self._chunk = raw, 0, chunk
        self.bytes_read = 0

    async def read(self, n=-1):
        end = len(self._raw) if n < 0 else min(len(self._raw), self._pos + min(n, self._chunk))
        chunk, self._pos = self._raw[self._pos : end], end
        self.bytes_read += len(chunk)
        return chunk


class _FakeResp:
    def __init__(self, status, payload=None, chunk=1024):
        self.status = status
        self._payload = payload or {}
        self.content = _Stream(json.dumps(self._payload).encode(), chunk)

    async def json(self):
        """Kept, though the collector no longer calls it (#1360): it is what the unbounded
        ``await response.json()`` used, so the oversized test below goes red if bounding is
        removed rather than quietly passing on a fake that models only the new shape."""
        return self._payload


def _inspect(running=True, restarting=False, restart_count=0, health=None, **extra):
    """A trimmed `GET /containers/<id>/json` payload — the fields the collector reads."""
    state = {"Running": running, "Restarting": restarting}
    if health is not None:
        state["Health"] = {"Status": health}
    payload = {"State": state, "RestartCount": restart_count}
    if "policy" in extra:
        payload["HostConfig"] = {"RestartPolicy": {"Name": extra["policy"]}}
    state.update({k: v for k, v in extra.items() if k in ("StartedAt", "ExitCode")})
    return payload


def _session(responses):
    """A fake aiohttp session whose GETs return `responses` in order."""
    session = MagicMock()
    session.get.side_effect = [_AsyncCM(r) for r in responses]
    return session


class TestGetContainerHealth:
    async def test_parses_inspect_payload(self):
        # One healthy-with-healthcheck container; the other 8 names 404 (not on this host).
        responses = [_FakeResp(200, _inspect(restart_count=2, health="unhealthy"))] + [
            _FakeResp(404)
        ] * (len(containers.MONITORED_CONTAINERS) - 1)
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            out = await containers.get_container_health()
        assert out == {
            "tor": {
                "running": True,
                "restarting": False,
                "restart_count": 2,
                "health": "unhealthy",
                "unsupervised": False,
                "exit_code": None,
                "held_since_boot": False,
            }
        }

    async def _one(self, payload, boot=1_790_000_000):
        responses = [_FakeResp(200, payload)] + [_FakeResp(404)] * (
            len(containers.MONITORED_CONTAINERS) - 1
        )
        with (
            patch.object(
                containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
            ),
            patch.object(containers, "_host_boot_epoch", return_value=boot),
        ):
            return (await containers.get_container_health())["tor"]

    async def test_restart_policy_no_is_unsupervised_and_held_when_not_started_since_boot(self):
        # #2749: StartedAt before the host booted = it has not run since boot (the LAN-guard hold).
        out = await self._one(
            _inspect(
                running=False, policy="no", StartedAt="2026-09-20T10:00:00.123456789Z", ExitCode=255
            )
        )
        assert out["unsupervised"] is True
        assert out["held_since_boot"] is True
        assert out["exit_code"] == 255

    async def test_started_since_boot_is_not_held(self):
        out = await self._one(
            _inspect(running=False, policy="no", StartedAt="2026-09-27T10:00:00Z", ExitCode=139)
        )
        assert out["held_since_boot"] is False
        assert out["exit_code"] == 139

    async def test_other_policies_are_supervised_and_unknown_boot_is_not_held(self):
        out = await self._one(
            _inspect(policy="unless-stopped", StartedAt="2026-09-20T10:00:00Z"), boot=None
        )
        assert out["unsupervised"] is False
        assert out["held_since_boot"] is False

    def test_boot_and_timestamp_parsing(self, tmp_path):
        assert containers._epoch("1970-01-01T00:01:40.5Z") == 100.5
        assert containers._epoch(None) is None
        assert containers._epoch("garbage") is None
        stat = tmp_path / "stat"
        stat.write_text("cpu 1 2 3\nbtime 1790000000\n")
        real_open = open
        with patch(
            "builtins.open", lambda p, *a, **k: real_open(stat if p == "/proc/stat" else p, *a, **k)
        ):
            assert containers._host_boot_epoch() == 1790000000
        with patch("builtins.open", side_effect=OSError):
            assert containers._host_boot_epoch() is None

    async def test_no_healthcheck_maps_to_none(self):
        # State.Health absent (no healthcheck) => health None — "no signal", never "unhealthy".
        responses = [_FakeResp(200, _inspect())] + [_FakeResp(404)] * (
            len(containers.MONITORED_CONTAINERS) - 1
        )
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            out = await containers.get_container_health()
        assert out["tor"]["health"] is None

    async def test_missing_container_is_skipped(self):
        # Remote mode / profile off: every name 404s → empty dict, no raise.
        responses = [_FakeResp(404)] * len(containers.MONITORED_CONTAINERS)
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            assert await containers.get_container_health() == {}

    async def test_per_container_error_skips_only_that_name(self):
        # One inspect blowing up must not lose the rest of the sweep.
        session = MagicMock()
        effects = [OSError("refused")] + [
            _AsyncCM(_FakeResp(200, _inspect()))
            for _ in range(len(containers.MONITORED_CONTAINERS) - 1)
        ]
        session.get.side_effect = effects
        with patch.object(containers.aiohttp, "ClientSession", return_value=_AsyncCM(session)):
            out = await containers.get_container_health()
        assert "tor" not in out
        assert len(out) == len(containers.MONITORED_CONTAINERS) - 1

    async def test_proxy_down_returns_empty(self):
        # Proxy unreachable entirely → {} and no raise (the data loop must keep running).
        with patch.object(containers.aiohttp, "ClientSession", side_effect=OSError("refused")):
            assert await containers.get_container_health() == {}

    async def test_an_oversized_inspect_skips_only_that_container(self):
        """Lowest trust class of the #1360 set — the payload shape comes from our own compose file
        — but a proxy answering with an unbounded body must cost one container, not buffer the
        whole thing into the state loop. Unbounded, ``json()`` hands back a valid payload and `tor`
        appears; bounded, the read is refused and the per-container ``continue`` skips it."""
        pad = "x" * MAX_RESPONSE_BYTES
        responses = [_FakeResp(200, {**_inspect(health="healthy"), "pad": pad}, chunk=65536)] + [
            _FakeResp(404)
        ] * (len(containers.MONITORED_CONTAINERS) - 1)
        with patch.object(
            containers.aiohttp, "ClientSession", return_value=_AsyncCM(_session(responses))
        ):
            out = await containers.get_container_health()
        assert out == {}


# --- monerod peer observation (#2921) ----------------------------------------------------------
# The restricted RPC answers 0 for the counts, so the counts come from the healthcheck's last run in
# State.Health.Log. Anything short of a fresh, well-formed, current-run observation is unavailable
# (both None), never zero and never healthy.

_NOW = 1_800_000_000.0


def _iso(offset):
    return datetime.fromtimestamp(_NOW + offset, tz=UTC).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")


def _peers_payload(
    output='pithead-monero-peers {"outgoing":8,"incoming":2,"white":5,"grey":6}\n', **kw
):
    entry = {"Start": _iso(-31), "End": _iso(-30), "ExitCode": 0, "Output": output}
    entry.update(kw)
    return {"State": {"StartedAt": _iso(-600), "Health": {"Status": "healthy", "Log": [entry]}}}


_UNAVAILABLE = {"peers_in": None, "peers_out": None}


def test_a_fresh_current_run_observation_is_read():
    got = containers.parse_monero_peers(_peers_payload(), now=_NOW)
    assert got == {"peers_in": 2, "peers_out": 8}


def test_a_real_zero_is_a_zero_not_unavailable():
    out = 'pithead-monero-peers {"outgoing":0,"incoming":0,"white":0,"grey":0}\n'
    assert containers.parse_monero_peers(_peers_payload(out), now=_NOW) == {
        "peers_in": 0,
        "peers_out": 0,
    }


def test_a_stale_observation_is_unavailable():
    payload = _peers_payload(End=_iso(-(containers.PEERS_FRESH_SEC + 1)))
    assert containers.parse_monero_peers(payload, now=_NOW) == _UNAVAILABLE


def test_an_observation_from_before_this_container_run_is_unavailable():
    payload = _peers_payload(Start=_iso(-900), End=_iso(-899))
    payload["State"]["StartedAt"] = _iso(-600)
    assert containers.parse_monero_peers(payload, now=_NOW) == _UNAVAILABLE


def test_a_failed_last_run_is_unavailable_even_with_a_marker():
    assert containers.parse_monero_peers(_peers_payload(ExitCode=1), now=_NOW) == _UNAVAILABLE


def test_only_the_last_run_counts():
    payload = _peers_payload()
    payload["State"]["Health"]["Log"].append(
        {"Start": _iso(-2), "End": _iso(-1), "ExitCode": 0, "Output": ""}
    )
    assert containers.parse_monero_peers(payload, now=_NOW) == _UNAVAILABLE


def test_the_helper_saying_unavailable_is_unavailable():
    payload = _peers_payload("pithead-monero-peers unavailable\n")
    assert containers.parse_monero_peers(payload, now=_NOW) == _UNAVAILABLE


def test_malformed_observations_are_unavailable():
    for bad in (
        "pithead-monero-peers {not json}\n",
        "pithead-monero-peers [1,2]\n",
        'pithead-monero-peers {"outgoing":-1,"incoming":2}\n',
        'pithead-monero-peers {"outgoing":true,"incoming":2}\n',
        'pithead-monero-peers {"outgoing":"8","incoming":2}\n',
        'pithead-monero-peers {"outgoing":8}\n',
    ):
        assert containers.parse_monero_peers(_peers_payload(bad), now=_NOW) == _UNAVAILABLE, bad


def test_a_missing_or_odd_payload_is_unavailable():
    for payload in (None, {}, {"State": {}}, {"State": {"Health": {"Log": []}}}, {"State": "x"}):
        assert containers.parse_monero_peers(payload, now=_NOW) == _UNAVAILABLE
    no_start = _peers_payload()
    del no_start["State"]["StartedAt"]
    assert containers.parse_monero_peers(no_start, now=_NOW) == _UNAVAILABLE


async def test_get_monero_peers_is_unavailable_when_the_proxy_is_down():
    with patch.object(containers, "DOCKER_PROXY_URL", "http://127.0.0.1:1"):
        assert await containers.get_monero_peers() == _UNAVAILABLE
