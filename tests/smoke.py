#!/usr/bin/env python3
"""Standard-library smoke test for the orchestrator. No pytest required.

Run with:  python3 tests/smoke.py
Exits 0 on success, non-zero on failure. CI also runs the richer
pytest suite in tests/test_orchestrator.py when pytest is available.
"""
from __future__ import annotations

import importlib.util
import importlib.machinery
import json
import pathlib
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import MagicMock

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / "bin" / "consolerdp-daemon"


def load_daemon():
    loader = importlib.machinery.SourceFileLoader("consolerdp_daemon", str(BIN))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["consolerdp_daemon"] = mod
    loader.exec_module(mod)
    return mod


daemon = load_daemon()


def _write_conf(dirpath: pathlib.Path) -> pathlib.Path:
    p = dirpath / "consolerdp.conf"
    p.write_text(textwrap.dedent("""
        [seat]
        user = alice
        console_tty = 1
        greeter_tty = 8

        [bridge]
        listen = 127.0.0.1
        port = 5900

        [policy]
        single_rdp = true
        lock_on_release = true
    """).strip())
    return p


def _make_orch():
    tmp = pathlib.Path(tempfile.mkdtemp())
    cfg = daemon.Config.load(str(_write_conf(tmp)))
    sysd = MagicMock(spec=daemon.System)
    sysd.list_sessions.return_value = [
        {"session": "c1", "uid": 1000, "user": "alice", "seat": "seat0"},
    ]
    sysd.session_show.return_value = {
        "Name": "alice", "Display": ":0", "TTY": "tty1",
        "Type": "x11", "State": "active", "Active": "yes",
    }
    daemon.pwd.getpwnam = lambda u: type("P", (), {"pw_uid": 1000})()
    o = daemon.Orchestrator(cfg, sysd=sysd)
    o._xauth_for = lambda uid: f"/run/user/{uid}/Xauthority"
    return o, sysd


class OrchestratorTests(unittest.TestCase):
    def test_config_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = daemon.Config.load(str(_write_conf(pathlib.Path(d))))
        self.assertEqual(cfg.user, "alice")
        self.assertEqual(cfg.console_tty, 1)
        self.assertEqual(cfg.greeter_tty, 8)
        self.assertEqual(cfg.bridge_port, 5900)
        self.assertTrue(cfg.single_rdp)
        self.assertTrue(cfg.lock_on_release)

    def test_takeover_rejects_wrong_user(self):
        o, _ = _make_orch()
        self.assertTrue(o.takeover("mallory").startswith("ERR"))

    def test_takeover_happy_path(self):
        o, sysd = _make_orch()
        self.assertEqual(o.takeover("alice"), "OK")
        sysd.chvt.assert_called_with(8)
        sysd.xinput_set_all.assert_called()
        self.assertTrue(o.state.rdp_active)
        # x11vnc is no longer started by the orchestrator (the Xvnc
        # shim does it per RDP session). Confirm the method is gone
        # from System entirely.
        self.assertFalse(hasattr(daemon.System, "start_x11vnc"))

    def test_takeover_refuses_double(self):
        o, _ = _make_orch()
        self.assertEqual(o.takeover("alice"), "OK")
        self.assertTrue(o.takeover("alice").startswith("ERR"))

    def test_release_idempotent(self):
        o, _ = _make_orch()
        self.assertEqual(o.release("alice"), "OK")
        o.takeover("alice")
        self.assertEqual(o.release("alice"), "OK")
        self.assertFalse(o.state.rdp_active)

    def test_release_locks_and_chvts_back(self):
        o, sysd = _make_orch()
        o.takeover("alice")
        sysd.chvt.reset_mock()
        o.release("alice")
        sysd.chvt.assert_called_with(1)
        sysd.lock_session.assert_called()

    def test_status_json(self):
        o, _ = _make_orch()
        d = json.loads(o.status())
        self.assertFalse(d["rdp_active"])
        self.assertEqual(d["config"]["user"], "alice")

    def test_dispatcher_protocol(self):
        o, _ = _make_orch()
        H = type("H", (daemon._Handler,), {"orch": o})
        h = H.__new__(H)
        h.orch = o
        self.assertEqual(h._dispatch("PING"), "PONG")
        self.assertTrue(h._dispatch("STATUS").startswith("{"))
        self.assertEqual(h._dispatch("TAKEOVER user=alice"), "OK")
        self.assertEqual(h._dispatch("RELEASE  user=alice"), "OK")
        self.assertTrue(h._dispatch("UNKNOWN").startswith("ERR"))
        self.assertTrue(h._dispatch("TAKEOVER badtoken").startswith("ERR"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
