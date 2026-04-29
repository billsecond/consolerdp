"""Unit tests for the ConsoleRDP orchestrator.

These tests stub out every privileged primitive (chvt, xinput, x11vnc,
loginctl, lock-session) via a fake System object, so they run on any
developer laptop with no root.
"""
from __future__ import annotations

import textwrap
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from conftest import load_daemon

daemon = load_daemon()


# --------------------------------------------------------------------------- #
# Config parsing
# --------------------------------------------------------------------------- #


def _write_conf(tmp_path: Path, **overrides) -> Path:
    base = {
        "user": "alice", "console_tty": "1", "greeter_tty": "8",
        "listen": "127.0.0.1", "port": "5900",
        "single_rdp": "true", "lock_on_release": "true",
    }
    base.update(overrides)
    p = tmp_path / "consolerdp.conf"
    p.write_text(textwrap.dedent(f"""
        [seat]
        user = {base['user']}
        console_tty = {base['console_tty']}
        greeter_tty = {base['greeter_tty']}

        [bridge]
        listen = {base['listen']}
        port = {base['port']}

        [policy]
        single_rdp = {base['single_rdp']}
        lock_on_release = {base['lock_on_release']}
    """).strip())
    return p


def test_config_loads(tmp_path: Path) -> None:
    cfg = daemon.Config.load(str(_write_conf(tmp_path)))
    assert cfg.user == "alice"
    assert cfg.console_tty == 1
    assert cfg.greeter_tty == 8
    assert cfg.bridge_port == 5900
    assert cfg.single_rdp is True
    assert cfg.lock_on_release is True


def test_config_missing_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        daemon.Config.load(str(tmp_path / "nope.conf"))


# --------------------------------------------------------------------------- #
# Orchestrator behavior with a fake System
# --------------------------------------------------------------------------- #


@pytest.fixture
def fake_system():
    s = MagicMock(spec=daemon.System)
    s.list_sessions.return_value = [
        {"session": "c1", "uid": 1000, "user": "alice", "seat": "seat0"},
    ]
    s.session_show.return_value = {
        "Name": "alice", "Display": ":0", "TTY": "tty1",
        "Type": "x11", "State": "active", "Active": "yes",
    }
    return s


@pytest.fixture
def cfg(tmp_path: Path) -> "daemon.Config":
    return daemon.Config.load(str(_write_conf(tmp_path)))


@pytest.fixture
def orch(monkeypatch, cfg, fake_system):
    monkeypatch.setattr(
        daemon.pwd, "getpwnam",
        lambda u: type("P", (), {"pw_uid": 1000})(),
    )
    o = daemon.Orchestrator(cfg, sysd=fake_system)
    monkeypatch.setattr(o, "_xauth_for", lambda uid: f"/run/user/{uid}/Xauthority")
    return o


def test_takeover_rejects_wrong_user(orch):
    assert orch.takeover("mallory").startswith("ERR")


def test_takeover_succeeds(orch, fake_system):
    assert orch.takeover("alice") == "OK"
    fake_system.chvt.assert_called_with(8)
    fake_system.xinput_set_all.assert_called()
    assert orch.state.rdp_active is True
    assert orch.state.rdp_user == "alice"
    # x11vnc is started by the Xvnc shim, not the orchestrator.
    assert not hasattr(daemon.System, "start_x11vnc")


def test_takeover_refuses_double_when_single_rdp(orch):
    assert orch.takeover("alice") == "OK"
    assert orch.takeover("alice").startswith("ERR")


def test_release_is_idempotent(orch):
    assert orch.release("alice") == "OK"  # nothing active yet
    orch.takeover("alice")
    assert orch.release("alice") == "OK"
    assert orch.state.rdp_active is False


def test_release_chvts_back_and_locks(orch, fake_system):
    orch.takeover("alice")
    fake_system.chvt.reset_mock()
    orch.release("alice")
    fake_system.chvt.assert_called_with(1)
    fake_system.lock_session.assert_called()


def test_status_returns_json(orch):
    import json
    out = json.loads(orch.status())
    assert out["rdp_active"] is False
    assert out["config"]["user"] == "alice"


def test_no_session_for_user(orch, fake_system):
    fake_system.list_sessions.return_value = []
    assert orch.takeover("alice").startswith("ERR no active local")


# --------------------------------------------------------------------------- #
# Wire protocol parsing — the dispatcher inside _Handler
# --------------------------------------------------------------------------- #


def test_dispatcher_parses_kv(monkeypatch, orch):
    handler_cls = type("H", (daemon._Handler,), {"orch": orch})
    h = handler_cls.__new__(handler_cls)
    h.orch = orch
    assert h._dispatch("PING") == "PONG"
    assert h._dispatch("STATUS").startswith("{")
    assert h._dispatch("TAKEOVER user=alice") == "OK"
    assert h._dispatch("RELEASE user=alice") == "OK"
    assert h._dispatch("UNKNOWN").startswith("ERR")
    assert h._dispatch("TAKEOVER badtoken").startswith("ERR")
