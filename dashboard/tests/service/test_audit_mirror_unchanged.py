def _row(state_manager, **over):
    row = dict(
        id="c-1",
        ts="2026-07-20T12:00:00Z",
        source="control",
        actor="admin",
        action="commit",
        status="preview",
        keys="XVB_ENABLED",
    )
    row.update(over)
    state_manager.add_audit_event(**row)


def test_unchanged_control_row_writes_nothing(state_manager):
    _row(state_manager)
    before = state_manager._conn.total_changes
    _row(state_manager)
    assert state_manager._conn.total_changes == before


def test_terminal_result_still_replaces_preview(state_manager):
    _row(state_manager)
    _row(state_manager, status="applied")
    events = state_manager.get_audit_events()
    assert [e["status"] for e in events] == ["applied"]
