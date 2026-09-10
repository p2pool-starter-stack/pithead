# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestWorkerProbeSsrfWiring:
    """End-to-end SSRF guard (#122): a miner controls its own row in xmrig-proxy's ``/workers``
    list (name at index 0, IP at index 1). Prove that an internal/loopback IP or a crafted name
    can't make the dashboard probe an internal target — the exact tier-1 mirror of the deferred
    live test in #206. Threads the real proxy-row → probe path (``_normalize_proxy_workers`` then
    the same task construction as DataService.run), so the parsed IP — never the name — is the only
    thing ever used as a host."""

    @staticmethod
    def _row(name, ip):
        # A full positional xmrig-proxy 6.x row (>= _PX_MIN_FIELDS): 1 active conn, some hashrate.
        return [name, ip, 1, 0, 0, 0, 0, 0, 1.0, 2.0, 0, 0, 0]

    async def _probe(self, raw_workers):
        workers = _normalize_proxy_workers({"workers": raw_workers})
        session = _RecordingSession()
        client = XMRigWorkerClient(session)
        # Mirror DataService.run's probe fan-out verbatim (data_service.py:632).
        results = await asyncio.gather(*[client.get_stats(w["ip"], w["name"]) for w in workers])
        return workers, results, session.urls

    async def test_internal_ip_worker_is_never_probed(self):
        # Every class the guard blocks: cloud metadata (link-local), loopback, the stack's own
        # docker bridge (socket proxies / Tor / monerod), multicast, unspecified, and a name that
        # isn't a bare IP. LAN/public miner IPs are intentionally NOT here — those are real miners.
        for ip in (
            "169.254.169.254",  # cloud metadata (link-local)
            "127.0.0.1",  # loopback
            "172.28.0.2",  # internal docker bridge (default MINING_NET_CIDR)
            "224.0.0.1",  # multicast
            "0.0.0.0",  # unspecified
            "p2pool",  # a worker name, not a bare IP
            "",  # missing
        ):
            _, results, urls = await self._probe([self._row("evil", ip)])
            assert results == [{}], f"probed an internal/invalid target {ip!r}"
            assert urls == [], f"issued a request to internal/invalid target {ip!r}"

    async def test_real_worker_is_probed_internal_neighbour_is_not(self):
        workers, results, urls = await self._probe(
            [self._row("rig", "8.8.8.8"), self._row("evil", "169.254.169.254")]
        )
        # Exactly one probe, to the real miner only.
        assert urls == ["http://8.8.8.8:8080/1/summary"]
        assert results[0].get("api_ok") is True
        assert results[1] == {}

    async def test_malicious_name_is_never_used_as_a_host(self):
        # The name is fully attacker-controlled; it must never end up in the request URL.
        _, _, urls = await self._probe([self._row("169.254.169.254", "8.8.8.8")])
        assert urls == ["http://8.8.8.8:8080/1/summary"]
        assert all("169.254.169.254" not in u for u in urls)
