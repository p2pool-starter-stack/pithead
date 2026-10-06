"""Which proxy-listed workers get a direct XMRig-API probe each poll (#2466)."""

import asyncio


class WorkerProber:
    """Probes the workers worth probing and remembers which (name, ip) rows answered.

    A row is probed when the proxy reports it ``online`` or when its previous probe answered:
    the latter keeps a RigForge rig whose miner is stopped (thermal hold, remote stop) but whose
    feed still answers. Any other row (a long-gone worker the proxy still lists) gets ``{}`` in
    its slot, so it logs no probe failure and carries no ``api_ok`` badge. The result list stays
    positionally aligned with ``workers``, as ``_merge_direct_stats`` and
    ``_reconcile_worker_config`` expect.
    """

    def __init__(self):
        self._answered = set()

    async def probe(self, client, workers):
        wanted = [
            w.get("status") == "online" or (w["name"], w["ip"]) in self._answered for w in workers
        ]
        probes = [
            client.get_stats(w["ip"], w["name"])
            for w, ok in zip(workers, wanted, strict=True)
            if ok
        ]
        probed = iter(await asyncio.gather(*probes))
        results = [next(probed) if ok else {} for ok in wanted]
        self._answered = {
            (w["name"], w["ip"]) for w, r in zip(workers, results, strict=True) if r.get("api_ok")
        }
        return results
