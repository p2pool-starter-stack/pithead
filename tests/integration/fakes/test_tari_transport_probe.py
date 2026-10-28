import importlib.util
import json
import socket
from pathlib import Path
from unittest.mock import Mock

import pytest

PROBE = Path(__file__).resolve().parents[3] / "tests/integration/lib/tari-transport-probe.py"
spec = importlib.util.spec_from_file_location("tari_transport_probe", PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


@pytest.fixture
def session():
    client, peer = socket.socketpair()
    stream = object.__new__(probe.Stratum)
    stream.socket, stream.buffer, stream.jobs, stream.logged_in = client, b"", 0, False
    try:
        yield stream, peer
    finally:
        client.close()
        peer.close()


def test_keeps_one_socket_and_accepts_fragmented_jobs(session):
    stream, peer = session
    peer.sendall(b'{"id":1,"result":{"job":{"blob":"fixture"}}}\n{"method":')
    stream.sample()
    assert stream.logged_in and stream.jobs == 1
    peer.sendall(b'"job","params":{"blob":"next"}}\n')
    stream.sample()
    assert stream.jobs == 2
    assert peer.recv(4096).count(b'"keepalived"') == 2


def test_disconnect_is_failure_instead_of_reconnecting(session):
    stream, peer = session
    peer.shutdown(socket.SHUT_WR)
    with pytest.raises(RuntimeError, match="stratum connection closed"):
        stream.sample()


def test_stratum_error_is_failure(session):
    stream, peer = session
    peer.sendall(b'{"id":1,"error":{"message":"refused"}}\n')
    with pytest.raises(RuntimeError, match="request rejected"):
        stream.sample()


def test_only_actual_aux_template_updates_count():
    assert probe.aux_transitions("channel_state: TRANSIENT_FAILURE\nMined Tari block") == []
    assert probe.aux_transitions(
        "update_aux_data: n_aux_chains = 0, aux_nonce = 2\n"
        "update_aux_data: n_aux_chains = 1, aux_nonce = 4"
    ) == [0, 1]


def test_loglevel_restores_effective_flag_instead_of_a_fixed_default():
    config = {"Cmd": ["--loglevel", "2"], "Env": ["P2POOL_FLAGS=--mini --loglevel 4"]}
    assert probe.configured_loglevel({"Config": config}) == 4
    assert probe.configured_loglevel({"Config": {"Cmd": [], "Env": []}}) == 3


@pytest.mark.parametrize("networks", [{}, {"a": {}, "b": {}}])
def test_ambiguous_network_is_refused(networks):
    container = {"NetworkSettings": {"Networks": networks}}
    with pytest.raises(RuntimeError, match="one shared"):
        probe.shared_addresses(container, container)


def test_template_and_share_evidence_are_all_required(monkeypatch, capsys):
    live = object.__new__(probe.Probe)
    live.armed = False
    live.aux_state = 1
    live.rule = Mock()
    live.channel = Mock(side_effect=["READY"] + ["TRANSIENT_FAILURE"] * 3)
    live.mining = Mock(
        side_effect=[
            {"accepted": 10, "hashes": 100},
            {"accepted": 10, "hashes": 100},
            {"accepted": 11, "hashes": 200},
        ]
    )
    monkeypatch.setattr(
        probe, "command", Mock(return_value="update_aux_data: n_aux_chains = 0, aux_nonce = 2")
    )

    clock = iter(range(1000, 10000, 10))
    monkeypatch.setattr(probe.time, "monotonic", lambda: next(clock))

    def wait(predicate, **kwargs):
        assert not predicate()
        assert predicate()

    live.wait = wait
    live.transition(True, 0)
    assert live.armed
    live.rule.assert_called_once_with("-I")
    assert "ROW PASS suppression" in capsys.readouterr().out


def test_aux_transition_alone_cannot_pass_without_channel_loss(monkeypatch):
    live = object.__new__(probe.Probe)
    live.armed = False
    live.aux_state = 1
    live.rule = Mock()
    live.channel = Mock(return_value="READY")
    live.mining = Mock(return_value={"workers": 1, "accepted": 10, "hashes": 100})
    live.mining = Mock(return_value={"accepted": 10, "hashes": 100})
    monkeypatch.setattr(
        probe, "command", Mock(return_value="update_aux_data: n_aux_chains = 0, aux_nonce = 2")
    )

    def wait(predicate):
        assert not predicate()
        raise RuntimeError("transition timeout")

    live.wait = wait
    with pytest.raises(RuntimeError, match="transition timeout"):
        live.transition(True, 0)


def test_probe_failure_removes_only_its_fault_and_restores_log_level(monkeypatch):
    live = object.__new__(probe.Probe)
    live.pid, live.pool_ip, live.armed = "42", "fixture", False
    live.original_loglevel = 4
    live.loglevel, live.rule = Mock(), Mock()
    live.channel = Mock(return_value="READY")
    live.mining = Mock(return_value={"workers": 1, "accepted": 10, "hashes": 100})
    stream = Mock()
    stream.logged_in = True
    monkeypatch.setattr(probe, "Stratum", Mock(return_value=stream))
    monkeypatch.setattr(probe, "command", Mock(return_value=""))
    live.wait = lambda predicate: predicate()

    def fail(*args):
        live.armed = True
        raise RuntimeError("injected transition failure")

    live.transition = fail
    with pytest.raises(RuntimeError, match="injected transition"):
        live.run()
    live.rule.assert_called_once_with("-D")
    assert live.loglevel.call_args.args == (4,)
    stream.close.assert_called_once()


def test_cleanup_failure_still_closes_stratum_and_restores_log_level(monkeypatch):
    live = object.__new__(probe.Probe)
    live.pid, live.pool_ip, live.armed = "42", "fixture", False
    live.original_loglevel = 2
    live.loglevel = Mock()
    live.rule = Mock(side_effect=RuntimeError("cleanup failure"))
    live.channel = Mock(return_value="READY")
    live.mining = Mock(return_value={"workers": 1, "accepted": 10, "hashes": 100})
    stream = Mock()
    stream.logged_in = True
    monkeypatch.setattr(probe, "Stratum", Mock(return_value=stream))
    monkeypatch.setattr(probe, "command", Mock(return_value=""))
    live.wait = lambda predicate: predicate()

    def fail(*args):
        live.armed = True
        raise RuntimeError("injected transition failure")

    live.transition = fail
    with pytest.raises(RuntimeError, match="cleanup failure"):
        live.run()
    assert live.loglevel.call_args.args == (2,)
    stream.close.assert_called_once()


def test_logs_on_stderr_are_not_lost(monkeypatch):
    result = Mock(returncode=0, stdout="", stderr="update_aux_data: n_aux_chains = 0")
    monkeypatch.setattr(probe.subprocess, "run", Mock(return_value=result))
    assert probe.aux_transitions(probe.command("docker", "logs")) == [0]


def test_console_cookie_is_sent_only_on_stdin(monkeypatch):
    live = object.__new__(probe.Probe)
    live.console = {"tcp_port": 12345, "cookie": "synthetic-cookie"}
    invoke = Mock(return_value="")
    monkeypatch.setattr(probe, "command", invoke)
    live.loglevel(5)
    assert "synthetic-cookie" not in json.dumps(invoke.call_args.args)
    assert invoke.call_args.kwargs["data"] == "synthetic-cookieloglevel 5\n"


def test_independent_cleanup_works_when_tari_and_proxy_cannot_be_inspected(monkeypatch, tmp_path):
    stats = tmp_path / "local"
    stats.mkdir()
    (stats / "console").write_text(json.dumps({"tcp_port": 12345, "cookie": "synthetic-cookie"}))
    pool = {
        "State": {"Pid": 42},
        "Mounts": [{"Destination": "/stats", "Source": str(tmp_path)}],
        "Config": {"Cmd": ["--loglevel", "4"], "Env": []},
    }

    def only_p2pool(name):
        assert name == "p2pool"
        return pool

    rule = f"-A OUTPUT -p tcp --dport 18142 -m comment --comment {probe.TAG} -j REJECT"
    invoke = Mock(side_effect=[rule, "", "", ""])
    monkeypatch.setattr(probe, "inspect", only_p2pool)
    monkeypatch.setattr(probe, "command", invoke)
    assert probe.main(["cleanup"]) == 0
    assert "-D" in invoke.call_args_list[1].args
    assert invoke.call_args_list[-1].kwargs["data"] == "synthetic-cookieloglevel 4\n"


def test_independent_cleanup_restores_log_level_even_if_rule_removal_fails(monkeypatch):
    live = object.__new__(probe.Probe)
    live.pid, live.original_loglevel = "42", 2
    live.loglevel = Mock()
    rule = f"-A OUTPUT -m comment --comment {probe.TAG} -j REJECT"
    monkeypatch.setattr(
        probe, "command", Mock(side_effect=[rule, RuntimeError("rule removal failed")])
    )
    with pytest.raises(RuntimeError, match="rule removal failed"):
        live.restore()
    live.loglevel.assert_called_once_with(2)


def test_missing_opposite_aux_baseline_is_not_a_transition():
    live = object.__new__(probe.Probe)
    live.aux_state = 0
    with pytest.raises(RuntimeError, match="opposite live aux-template baseline"):
        live.transition(True, 0)


@pytest.mark.parametrize(
    ("args", "stderr", "expected"),
    [
        (
            ("docker", "exec", "dashboard", "python3"),
            "KeyError: 'private-field'",
            "proxy-summary failed: exit 1; KeyError",
        ),
        (
            ("docker", "exec", "dashboard", "python3"),
            "Traceback with private context\nKeyError: 'hashes_total'\n",
            "proxy-summary failed: exit 1; KeyError:hashes_total",
        ),
        (
            ("docker", "inspect", "tari"),
            "No such container: private-container",
            "inspect-tari failed: exit 1; container-missing",
        ),
        (
            ("sudo", "-n", "nsenter", "-t", "42", "-n", "iptables", "-I"),
            "Operation not permitted",
            "fault-rule-insert failed: exit 1; operation-not-permitted",
        ),
        (
            ("docker", "exec", "-i", "p2pool"),
            "connect: Connection refused",
            "p2pool-console-write failed: exit 1; connection-refused",
        ),
        (
            ("docker", "logs", "p2pool"),
            "arbitrary private diagnostic",
            "p2pool-log-read failed: exit 1; unclassified-stderr",
        ),
    ],
)
def test_failed_commands_identify_operation_without_printing_remote_output(
    monkeypatch, args, stderr, expected
):
    result = Mock(returncode=1, stdout="private stdout payload", stderr=stderr)
    monkeypatch.setattr(probe.subprocess, "run", Mock(return_value=result))
    with pytest.raises(RuntimeError) as caught:
        probe.command(*args, data="private stdin payload")
    assert str(caught.value) == expected
    assert stderr not in str(caught.value)
    assert "private" not in str(caught.value)


def test_timed_out_command_preserves_operation_without_command_or_output(monkeypatch):
    error = probe.subprocess.TimeoutExpired(
        cmd=["private executable"], timeout=20, output="private stdout", stderr="private stderr"
    )
    monkeypatch.setattr(probe.subprocess, "run", Mock(side_effect=error))
    with pytest.raises(RuntimeError, match="proxy-summary timed out after 20 seconds") as caught:
        probe.command("docker", "exec", "dashboard", "python3", data="private stdin")
    assert "private" not in str(caught.value)


def test_failure_diagnostic_survives_the_real_entry_point(monkeypatch, capsys):
    result = Mock(
        returncode=13, stdout="private stdout", stderr="Permission denied: private target"
    )
    monkeypatch.setattr(probe.subprocess, "run", Mock(return_value=result))
    assert probe.main([]) == 1
    output = capsys.readouterr().out
    assert (
        output
        == "ROW FAIL Tari transport probe: inspect-p2pool failed: exit 13; permission-denied\n"
    )
    assert "private" not in output
