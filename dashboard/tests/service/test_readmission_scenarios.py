from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.collector import pools as pools_collector
from mining_dashboard.config.config import NODE_RECOVERY_AFTER_SEC, UPDATE_INTERVAL
from mining_dashboard.service.data_service import DataService

BOUND = NODE_RECOVERY_AFTER_SEC + UPDATE_INTERVAL


class Clock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        return self.now


def state(running=True, restarting=False, health="healthy"):
    return {"running": running, "restarting": restarting, "health": health}


DOWN = state(running=False, health=None)
STARTING = state(health="starting")


def green(peers=3):
    return {"level": "green", "reasons": [], "peers_out": peers}


OK_P2P = {"uptime": 900, "out_peers": 2, "in_peers": 1, "zmq_active": 3}
PEERLESS_P2P = {"uptime": 300, "out_peers": 0, "in_peers": 0, "zmq_active": 4}


def world(**kw):
    w = {
        "containers": {n: state() for n in ("monerod", "p2pool", "tor")},
        "reachable": True,
        "health": green(),
        "synchronized": True,
        "p2p": dict(OK_P2P),
    }
    w.update(kw)
    return w


def containers(monerod=None, p2pool=None, tor=None):
    base = {n: state() for n in ("monerod", "p2pool", "tor")}
    for name, value in (("monerod", monerod), ("p2pool", p2pool), ("tor", tor)):
        if value is not None:
            base[name] = value
    return base


SCENARIOS = {
    "apply-recreate": {
        "initial_rejected": False,
        "ever_up": False,
        "clear_at": 150,
        "expect_stop": True,
        "steps": [
            (0, containers(monerod=STARTING, p2pool=STARTING, tor=STARTING)),
            (30, containers(monerod=STARTING, p2pool=STARTING)),
            (60, containers(monerod=STARTING, p2pool=STARTING)),
            (90, containers(monerod=STARTING, p2pool=STARTING)),
            (120, containers(p2pool=STARTING)),
            (150, containers()),
            (180, containers()),
            (210, containers()),
        ],
    },
    "restart-all": {
        "initial_rejected": False,
        "ever_up": True,
        "clear_at": 150,
        "expect_stop": True,
        "steps": [
            (0, containers(monerod=DOWN, p2pool=DOWN, tor=DOWN)),
            (30, containers(monerod=DOWN, p2pool=DOWN, tor=STARTING)),
            (60, containers(monerod=STARTING, p2pool=STARTING)),
            (90, containers(monerod=STARTING, p2pool=STARTING)),
            (120, containers(p2pool=STARTING)),
            (150, containers()),
            (180, containers()),
            (210, containers()),
        ],
    },
    "restart-monerod": {
        "initial_rejected": False,
        "ever_up": True,
        "clear_at": 180,
        "expect_stop": True,
        "steps": [
            (0, containers(monerod=DOWN)),
            (30, containers(monerod=DOWN)),
            (60, containers(monerod=DOWN)),
            (90, containers(monerod=STARTING)),
            (120, containers(monerod=STARTING)),
            (150, containers()),
            (180, containers()),
            (210, containers()),
        ],
    },
    "restart-p2pool": {
        "initial_rejected": False,
        "ever_up": True,
        "clear_at": 120,
        "expect_stop": True,
        "steps": [
            (0, containers(p2pool=DOWN)),
            (30, containers(p2pool=DOWN)),
            (60, containers(p2pool=DOWN)),
            (90, containers(p2pool=STARTING)),
            (120, containers()),
            (150, containers()),
            (180, containers()),
        ],
    },
    "restart-tor": {
        "initial_rejected": False,
        "ever_up": True,
        "clear_at": 150,
        "expect_stop": True,
        "steps": [
            (0, containers(tor=state(health="unhealthy"))),
            (30, containers(tor=state(health="unhealthy"))),
            (60, containers(tor=state(health="unhealthy"))),
            (90, containers(tor=STARTING)),
            (120, containers()),
            (150, containers()),
            (180, containers()),
        ],
    },
    "reboot-start-order": {
        "initial_rejected": True,
        "ever_up": False,
        "clear_at": 150,
        "expect_stop": False,
        "steps": [
            (0, containers(monerod=DOWN, p2pool=DOWN, tor=STARTING)),
            (30, containers(monerod=STARTING, p2pool=DOWN)),
            (60, containers(monerod=STARTING, p2pool=STARTING)),
            (90, containers(monerod=STARTING, p2pool=STARTING)),
            (120, containers(p2pool=STARTING)),
            (150, containers()),
            (180, containers()),
            (210, containers()),
        ],
    },
    "p2pool-stratum-late": {
        "initial_rejected": True,
        "ever_up": False,
        "clear_at": 240,
        "expect_stop": False,
        "steps": [(t, containers()) for t in range(0, 211, 30)] + [(240, containers())],
    },
    "persisted-rejected-no-trigger": {
        "initial_rejected": True,
        "ever_up": False,
        "clear_at": 0,
        "expect_stop": False,
        "steps": [(t, containers()) for t in (0, 30, 60, 90)],
    },
    "starting-inside-start-period": {
        "initial_rejected": True,
        "ever_up": False,
        "clear_at": 240,
        "expect_stop": False,
        "steps": [(t, containers(tor=STARTING)) for t in range(0, 240, 30)]
        + [(t, containers()) for t in range(240, 331, 30)],
    },
}


def _world_at(step, name):
    t, c = step
    w = world()
    w["containers"] = c
    if name == "apply-recreate":
        if t < 60:
            w.update(reachable=False, synchronized=None, p2p=None, health={"level": "unknown"})
        elif t < 150:
            w.update(p2p=None)
    elif name == "restart-all":
        if t < 90:
            w.update(reachable=False, synchronized=None, p2p=None, health={"level": "unknown"})
        elif t < 150:
            w.update(p2p=None, health={"level": "unknown"})
        else:
            w.update(p2p=dict(OK_P2P))
    elif name == "restart-monerod":
        if t < 120:
            w.update(reachable=False, synchronized=None, p2p=dict(OK_P2P))
        elif t < 180:
            w.update(health=green(peers=0))
    elif name == "restart-p2pool":
        if t < 120:
            w.update(p2p=None)
    elif name == "restart-tor":
        if 30 <= t < 150:
            w.update(health=green(peers=0))
    elif name == "reboot-start-order":
        if t < 60:
            w.update(reachable=False, synchronized=None, p2p=None, health={"level": "unknown"})
        elif t < 150:
            w.update(p2p=None)
    elif name == "p2pool-stratum-late":
        if t < 240:
            w.update(p2p=dict(PEERLESS_P2P))
    return t, w


def _svc(initial_rejected, ever_up, clock, starts, stops):
    sm = MagicMock()
    sm.load_snapshot.return_value = None
    svc = DataService(sm, MagicMock(), MagicMock())
    svc.docker_control = MagicMock()
    svc.docker_control.stop = AsyncMock(side_effect=lambda _name: stops.append(clock.now) or True)
    svc.docker_control.start = AsyncMock(side_effect=lambda _name: starts.append(clock.now) or True)
    svc.miner_released = True
    svc.workers_rejected = initial_rejected
    svc.monero_health.ever_up = ever_up
    svc.monero_health._clock = clock
    svc.mining_guard._clock = clock
    svc.mining_guard._wall = lambda: 1000 + clock.now
    return svc


async def _cycle(svc, w):
    monero_sync = {"health": dict(w["health"]), "reachable": w["reachable"]}
    if w["synchronized"] is not None:
        monero_sync["synchronized"] = w["synchronized"]
    monero_down = svc.monero_health.update(w["reachable"])
    with (
        patch.object(ds_mod, "get_container_health", AsyncMock(return_value=w["containers"])),
        patch.object(
            pools_collector,
            "get_p2pool_log_signals",
            AsyncMock(return_value={"lag": 0, "monerod_unsynced": False}),
        ),
    ):
        await svc._update_mining_guard(monero_sync, {"p2p": w["p2p"]} if w["p2p"] else {})
    await svc._apply_worker_rejection(monero_down, False)


@pytest.mark.parametrize("name", sorted(SCENARIOS))
async def test_readmission_bound_after_stack_operation(name):
    spec = SCENARIOS[name]
    clock = Clock()
    starts, stops = [], []
    svc = _svc(spec["initial_rejected"], spec["ever_up"], clock, starts, stops)
    rejected_during_hold = False
    with patch.object(ds_mod, "TARI_REQUIRED", False):
        for step in spec["steps"]:
            t, w = _world_at(step, name)
            clock.now = t
            await _cycle(svc, w)
            if svc.workers_rejected and not starts:
                rejected_during_hold = True

    if spec["expect_stop"]:
        assert stops and stops[0] < spec["clear_at"], (
            f"{name}: proxy never stopped before the clear"
        )
        assert len(stops) == 1, f"{name}: proxy stopped {len(stops)} times"
    else:
        svc.docker_control.stop.assert_not_awaited()
    assert starts, f"{name}: xmrig-proxy was never readmitted within the scripted window"
    assert starts[0] >= spec["clear_at"], (
        f"{name}: readmitted at {starts[0]} before the last trigger cleared at {spec['clear_at']}"
    )
    assert starts[0] <= spec["clear_at"] + BOUND, (
        f"{name}: readmitted at {starts[0]}, later than the bound "
        f"{spec['clear_at']}+{BOUND} from the last trigger clearing"
    )
    assert len(starts) == 1
    assert not svc.workers_rejected
    if spec["expect_stop"]:
        assert rejected_during_hold
