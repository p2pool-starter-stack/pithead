from types import SimpleNamespace

from mining_dashboard import (
    go_documents,
    go_wizard,
    go_wizard_config,
    go_wizard_policy,
    go_wizard_preparation,
    go_wizard_state,
    go_wizard_submission,
    go_wizard_terminal,
    go_wizard_transaction,
    go_wizard_typed,
    go_wizard_values,
)


def stub(*args, **kwargs):
    return args, kwargs


def test_wizard_install_wires_every_bridge(monkeypatch):
    names = (
        "wizard_stage",
        "installer_mode",
        "status",
        "_spool_read",
        "_reference",
        "_last_attempt",
        "_rig_defaults",
        "_data_wiped",
        "_saved_role",
    )
    server = SimpleNamespace(
        **{name: stub for name in names},
        make_app=stub,
        wizard_state=stub,
    )
    installed = []
    modules = (
        go_wizard_transaction,
        go_wizard_policy,
        go_wizard_config,
        go_wizard_terminal,
        go_wizard_submission,
        go_wizard_typed,
        go_wizard_values,
        go_wizard_state,
    )
    for module in modules:
        monkeypatch.setattr(
            module,
            "install",
            lambda server, module=module: installed.append(module.__name__),
        )
    monkeypatch.setattr(go_documents, "install", lambda: installed.append("documents"))
    monkeypatch.setattr(go_wizard, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(go_wizard, "_REFERENCE_MAKE_APP", None)
    monkeypatch.setattr(go_wizard, "_REFERENCE_STATE", None)

    go_wizard.install(server)

    assert all(getattr(server, name) is getattr(go_wizard, name) for name in names)
    assert server.make_app is go_wizard.make_app
    assert server.wizard_state is go_wizard.wizard_state
    assert len(installed) == 9


def test_config_install_wires_config_and_recovery(monkeypatch):
    from mining_dashboard import wizard_config, wizard_recovery

    names = ("prepare_config", "deep_merge", "strip_defaults", "validate_machine_name")
    for name in names:
        monkeypatch.setattr(wizard_config, name, stub)
    monkeypatch.setattr(wizard_recovery, "recovery_state", stub)
    monkeypatch.setattr(go_wizard_config, "REFERENCE_FUNCTIONS", {})
    server = SimpleNamespace(**{name: stub for name in names}, recovery_state=stub)

    go_wizard_config.install(server)

    assert all(getattr(wizard_config, name) is getattr(go_wizard_config, name) for name in names)
    assert wizard_recovery.recovery_state is go_wizard_config.recovery_state
    assert server.recovery_state is go_wizard_config.recovery_state


def test_policy_install_wires_auth_form_and_install(monkeypatch):
    from mining_dashboard import wizard_install
    from mining_dashboard.wizard import form

    names = ("_canon_token", "_authed", "auth", "build_config", "validate_install_request")
    monkeypatch.setattr(wizard_install, "validate_install_request", stub)
    monkeypatch.setattr(form, "build_config", stub)
    monkeypatch.setattr(go_wizard_policy, "REFERENCE_FUNCTIONS", {})
    server = SimpleNamespace(**{name: stub for name in names})

    go_wizard_policy.install(server)

    assert all(getattr(server, name) is getattr(go_wizard_policy, name) for name in names)
    assert form.build_config is go_wizard_policy.build_config
    assert wizard_install.validate_install_request is go_wizard_policy.validate_install_request


def test_submission_terminal_and_preparation_install(monkeypatch):
    from mining_dashboard import wizard_recovery

    monkeypatch.setattr(go_wizard_submission, "REFERENCE_FUNCTIONS", {})
    submit = SimpleNamespace(_submit_rig=stub, _submit_restore_locked=stub)
    go_wizard_submission.install(submit)
    assert submit._submit_rig is go_wizard_submission._submit_rig

    names = ("handoff", "handoff_ack", "keep_role", "retry_handler")
    monkeypatch.setattr(wizard_recovery, "retry_handler", stub)
    monkeypatch.setattr(go_wizard_terminal, "REFERENCE_FUNCTIONS", {})
    terminal = SimpleNamespace(**{name: stub for name in names})
    go_wizard_terminal.install(terminal)
    assert wizard_recovery.retry_handler is go_wizard_terminal.retry_handler

    monkeypatch.setattr(go_wizard_typed, "_config", stub)
    monkeypatch.setattr(go_wizard_preparation, "REFERENCE_FUNCTIONS", {})
    go_wizard_preparation.install()
    assert go_wizard_typed._config is go_wizard_preparation.config


def test_transaction_install_wires_present_server_operations(monkeypatch):
    from mining_dashboard import wizard_transaction

    for name in go_wizard_transaction.OPERATIONS:
        monkeypatch.setattr(wizard_transaction, name, stub)
    monkeypatch.setattr(go_wizard_transaction, "REFERENCE_FUNCTIONS", {})
    server = SimpleNamespace(spool_write=stub, spool_exists=stub)

    go_wizard_transaction.install(server)

    assert wizard_transaction.spool_write is go_wizard_transaction.spool_write
    assert server.spool_write is go_wizard_transaction.spool_write
    assert server.spool_exists is go_wizard_transaction.spool_exists


def test_values_install_wires_defaults_and_recovery(monkeypatch):
    from mining_dashboard import wizard_recovery
    from mining_dashboard.wizard import defaults

    default_names = (
        "tari_disk_default",
        "new_machine_answers",
        "explicit_wizard_config",
        "disk_inventory",
    )
    recovery_names = ("remember_changes", "remove_spool")
    for name in default_names:
        monkeypatch.setattr(defaults, name, stub)
    for name in recovery_names:
        monkeypatch.setattr(wizard_recovery, name, stub)
    monkeypatch.setattr(go_wizard_values, "REFERENCE_FUNCTIONS", {})
    server = SimpleNamespace(**{name: stub for name in default_names + recovery_names})

    go_wizard_values.install(server)

    assert all(getattr(defaults, name) is getattr(go_wizard_values, name) for name in default_names)
    assert all(
        getattr(wizard_recovery, name) is getattr(go_wizard_values, name) for name in recovery_names
    )
    assert all(getattr(server, name) is getattr(go_wizard_values, name) for name in server.__dict__)
