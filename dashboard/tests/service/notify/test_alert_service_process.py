# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestProcess:
    async def test_disabled_notifier_is_noop(self):
        notifier = _FakeNotifier(enabled=False)
        svc = _svc(notifier=notifier)
        out = await svc.process(
            monero_down=True,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert out == []
        assert notifier.sent == []

    async def test_disabled_notifier_still_persists_wallet_baseline(self):
        # The payout-wallet tripwire (#375) must work on a Telegram-less stack — the default.
        # The dashboard's 72h banner reads the kv keys, so the baseline seed + change record
        # must persist every cycle; only the Telegram message stays notifier-gated.
        store, get, put = _kv_store()
        svc = _svc(notifier=_FakeNotifier(enabled=False), kv_get=get, kv_set=put)
        signals = dict(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        await svc.process(observed_wallet=_W_A, **signals)  # seed
        assert store["payout_wallet"] == _W_A
        out = await svc.process(observed_wallet=_W_B, **signals)  # tamper
        assert out == [] and svc.notifier.sent == []  # no Telegram — but the kv record lands
        assert store["payout_wallet"] == _W_B
        assert store["payout_wallet_prev8"] == _W_A[:8]
        assert float(store["payout_wallet_changed_ts"]) > 0

    async def test_disabled_notifier_still_updates_container_health_tracker(self):
        # #490: dashboard.fail_closed reads svc.containers.is_confirmed_bad("dashboard") off the
        # SAME tracker this alerting path would otherwise be the only feeder for — it must stay fed
        # every cycle even with every sink off (the default stack), or a fail_closed operator with
        # Telegram off would never see the dashboard crash/unhealthy signal used to gate the hold.
        # `now` rides the signals through to containers.update, so a healthy→unhealthy streak past
        # the 120s debounce confirms through the disabled path — proving it's genuinely fed (a
        # never-fed tracker would stay not-confirmed).
        svc = _svc(notifier=_FakeNotifier(enabled=False))
        base = dict(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )

        def snap(health, now):
            return dict(
                base,
                now=now,
                containers={
                    "dashboard": {
                        "running": True,
                        "restarting": False,
                        "restart_count": 0,
                        "health": health,
                    }
                },
            )

        await svc.process(**snap("healthy", 1000))  # known, healthy baseline
        await svc.process(**snap("unhealthy", 1000))  # streak starts
        assert svc.containers.is_confirmed_bad("dashboard") is False  # too young to gate
        await svc.process(**snap("unhealthy", 1130))  # past 120s -> confirmed
        assert svc.containers.is_confirmed_bad("dashboard") is True

    async def test_disabled_path_swallows_wallet_baseline_error(self):
        # A broken kv store must not break the data loop, Telegram on or off.
        def boom(_k, _v=None):
            raise RuntimeError("kv down")

        svc = _svc(notifier=_FakeNotifier(enabled=False), kv_get=boom, kv_set=boom)
        out = await svc.process(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
            observed_wallet=_W_A,
        )
        assert out == []

    async def test_disabled_path_swallows_container_health_update_error(self):
        # Same "never break the data loop" contract as the wallet baseline above, for the #490
        # container-health feed.
        svc = _svc(notifier=_FakeNotifier(enabled=False))
        svc.containers.update = lambda *_a, **_kw: (_ for _ in ()).throw(RuntimeError("boom"))
        out = await svc.process(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
            containers={
                "dashboard": {
                    "running": True,
                    "restarting": False,
                    "restart_count": 0,
                    "health": None,
                }
            },
        )
        assert out == []

    async def test_enabled_notifier_dispatches(self):
        notifier = _FakeNotifier()
        svc = _svc(notifier=notifier)
        # seed
        await svc.process(
            monero_down=False,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        out = await svc.process(
            monero_down=True,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert len(notifier.sent) == 1 and "DOWN" in notifier.sent[0]

    async def test_process_swallows_evaluate_error(self, monkeypatch):
        # A bug in evaluate() must never break the data loop — process() catches, logs, returns [].
        svc = _svc(notifier=_FakeNotifier())

        def boom(**_kw):
            raise RuntimeError("kaboom")

        monkeypatch.setattr(svc, "evaluate", boom)
        out = await svc.process(
            monero_down=True,
            tari_down=False,
            tari_required=True,
            miner_released=True,
            workers=[],
            workers_expected=False,
        )
        assert out == []
