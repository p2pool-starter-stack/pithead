from mining_dashboard.service.sync_reason import RemoteSyncReason, describe_remote_wait


class TestDescribeRemoteWait:
    def test_local_node_has_no_reason(self):
        assert (
            describe_remote_wait(
                "Tari", "127.0.0.1:18142", is_local=True, sync_status={"is_syncing": True}
            )
            is None
        )

    def test_disabled_chain_has_no_reason(self):
        assert (
            describe_remote_wait(
                "Tari", "127.0.0.1:18142", is_local=None, sync_status={"is_syncing": True}
            )
            is None
        )

    def test_remote_node_synced_has_no_reason(self):
        status = {"reachable": True, "is_syncing": False, "initial_sync_achieved": True}
        assert (
            describe_remote_wait("Tari", "192.168.1.172:18142", is_local=False, sync_status=status)
            is None
        )

    def test_remote_node_still_syncing_renders_reason_and_address(self):
        status = {
            "reachable": True,
            "is_syncing": True,
            "initial_sync_achieved": False,
            "base_node_state": "HEADER_SYNC",
        }
        reason = describe_remote_wait(
            "Tari", "192.168.1.172:18142", is_local=False, sync_status=status
        )
        assert reason == RemoteSyncReason(
            chain="Tari",
            address="192.168.1.172:18142",
            initial_sync_achieved=False,
            state="HEADER_SYNC",
            short_desc=None,
            error=None,
        )
        line = reason.render(waited_seconds=720)
        assert "192.168.1.172:18142" in line
        assert "HEADER_SYNC" in line
        assert "initial sync not yet achieved" in line
        assert "12 min" in line

    def test_rpc_error_renders_the_error(self):
        status = {"reachable": False, "is_syncing": False, "error": "unavailable"}
        reason = describe_remote_wait(
            "Tari", "192.168.1.172:18142", is_local=False, sync_status=status
        )
        line = reason.render(waited_seconds=30)
        assert "192.168.1.172:18142" in line
        assert "unavailable" in line
        assert "30 sec" in line

    def test_short_desc_included_when_exposed(self):
        status = {
            "reachable": True,
            "is_syncing": True,
            "initial_sync_achieved": False,
            "base_node_state": "BLOCK_SYNC",
            "sync_state": "BLOCK",
            "short_desc": "downloading blocks",
        }
        reason = describe_remote_wait(
            "Tari", "192.168.1.172:18142", is_local=False, sync_status=status
        )
        assert "downloading blocks" in reason.render(waited_seconds=5)


class TestRenderChangeIdentity:
    def test_reason_equality_ignores_waited_seconds(self):
        """The state-change identity a caller debounces logging on must not include the wait
        duration — otherwise every poll would count as "a change" and defeat #2353's
        once-per-state-change requirement."""
        a = RemoteSyncReason(chain="Tari", address="x", state="HEADER_SYNC")
        b = RemoteSyncReason(chain="Tari", address="x", state="HEADER_SYNC")
        assert a == b
        assert a.render(1) != a.render(1000)
