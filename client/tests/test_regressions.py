"""Регрессии после проверки пакета: все тесты работают без реальной Станции."""
import json
import os
import pathlib
import io
import sys
import types
import contextlib
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from ymatter.bridge import BridgeCore, SafetyGate, Topics, parse_command, MqttRunner
from ymatter.cli import _request_from_args, _require_safe, main
from ymatter.client import MaindClient, MaindMatterError, MaindProtocolError
from ymatter.config import Config, ConfigError, from_dict
from ymatter.lamp import LampState, Request
from ymatter import preflight as pf
from ymatter.transport import HttpTransport, MaindError, SshExecTransport


class StubTransport:
    def __init__(self, payload):
        self.payload = payload
        self.sent = []

    def request(self, method, path, body):
        self.sent.append((method, path, body))
        return 200, json.dumps(self.payload).encode()


def invoke_response(status, **extras):
    return {"responses": [{"clusterId": 6, "commandId": 1, "endpointId": 1,
                            "status": status, **extras}]}


class StrictMatterStatusTests(unittest.TestCase):
    def test_known_successes_accepted(self):
        for status in (0, "Success", "invoke_callback.cpp:66: Success"):
            with self.subTest(status=status):
                t = StubTransport(invoke_response(status))
                MaindClient(t).invoke(258, 1, 6, 1, {})
                self.assertEqual(len(t.sent), 1)

    def test_unknown_success_substrings_rejected(self):
        for status in ("Unsuccessful", "Success-ish", "Success Failure", "Successful",
                       "Error: Success", "FailureSuccess", "foo: Success", False, True,
                       "success", "invoke_callback.cpp:66: Unsuccessful", 1):
            with self.subTest(status=status):
                with self.assertRaises(MaindMatterError):
                    MaindClient(StubTransport(invoke_response(status))).invoke(258, 1, 6, 1, {})

    def test_invalid_responses_do_not_count(self):
        for payload in ({"responses": []}, {"responses": [invoke_response(0)["responses"][0],
                                                           invoke_response(0)["responses"][0]]},
                        {"responses": [{"clusterId": 6, "commandId": 1, "endpointId": 1}]},
                        invoke_response(0, nodeId=259)):
            with self.subTest(payload=payload):
                with self.assertRaises(MaindProtocolError):
                    MaindClient(StubTransport(payload)).invoke(258, 1, 6, 1, {})


class LanPreflightTests(unittest.TestCase):
    @staticmethod
    def config():
        return from_dict({"station": {"ssh_alias": "dummy", "ip": "192.0.2.1"}})

    @staticmethod
    def good_script(script):
        return 0, (f"ssh=ok\nguard4=0\nguard6=0\nlistener=1\n"
                   f"sha {next(iter(pf.KNOWN_MAIND))}  {pf.MAIND_PATH}\n"
                   f"sha {next(iter(pf.KNOWN_LAUNCHER))}  {pf.LAUNCHER_PATH}\n"), ""

    def test_network_probe_error_is_fatal(self):
        for state in ("error", "unreachable", "garbage", None, "open"):
            checks = pf.run_preflight(self.config(), self.good_script, probe=lambda h, p: state)
            with self.subTest(state=state):
                self.assertFalse(pf.passed(checks))

    def test_probe_exception_is_fatal(self):
        def broken(h, p):
            raise OSError("network failure")
        checks = pf.run_preflight(self.config(), self.good_script, probe=broken)
        self.assertFalse(pf.passed(checks))
        self.assertIn("error:OSError", pf.format_checks(checks))

    def test_only_closed_filtered_pass(self):
        for state in ("closed", "filtered"):
            self.assertTrue(pf.passed(pf.run_preflight(self.config(), self.good_script,
                                                      probe=lambda h, p: state)))


class BrightnessSafetyTests(unittest.TestCase):
    def test_mqtt_brightness_zero_is_off(self):
        for msg in (b'{"brightness":0}', b'{"state":"ON","brightness":0}'):
            r = parse_command(msg)
            self.assertEqual(r, Request(on=False))

    def test_cli_zero_percent_is_off(self):
        r = _request_from_args(SimpleNamespace(cmd="brightness", percent=0, transition=0))
        self.assertEqual(r, Request(on=False))

    def test_out_of_range_commands_fail(self):
        for value in (-0.1, 101, float("nan"), float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                _request_from_args(SimpleNamespace(cmd="brightness", percent=value, transition=0))
        for msg in ('{"brightness":-1}', '{"brightness":255}', '{"brightness":NaN}',
                    '{"color":{"h":361,"s":30}}', '{"color":{"h":0,"s":101}}',
                    '{"color_temp":1000}'):
            with self.subTest(msg=msg), self.assertRaises(ValueError):
                parse_command(msg, color_temp=True)

    def test_remote_skip_preflight_is_denied(self):
        cfg = from_dict({"station": {"ssh_alias": "station"}})
        with self.assertRaises(SystemExit):
            _require_safe(cfg, True)
        cfg = from_dict({"station": {"transport": "direct", "direct_url": "http://localhost:8765"}})
        _require_safe(cfg, True)

    def test_empty_and_huge_mqtt_commands_rejected(self):
        for body in (b'{}', b'{"state":null}', b'x' * 4097):
            with self.assertRaises(ValueError):
                parse_command(body)

    def test_ssh_exec_default(self):
        self.assertEqual(Config().station.transport, "ssh-exec")


class CliMockSmoke(unittest.TestCase):
    def test_full_cli_entry_point_with_mock_http(self):
        from .mock_maind import MockServer
        with MockServer() as srv:
            cfg = from_dict({"station": {"transport": "direct", "direct_url": srv.url}})
            output = io.StringIO()
            for command in (("devices",), ("state",), ("on",),
                            ("brightness", "30"), ("color", "120", "100"),
                            ("brightness", "0"), ("state",)):
                with (patch("ymatter.cli.load_config", return_value=cfg),
                      contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO())):
                    rc = main(['--skip-preflight', *command])
                self.assertEqual(rc, 0, (command, output.getvalue()))
            self.assertFalse(srv.lamp.on)


class DummyLamp:
    def __init__(self):
        self.reads, self.applies = 0, 0

    def read_state(self):
        self.reads += 1
        return LampState(on=True, level=55, hue=1, saturation=100, color_mode=0)

    def apply(self, *args, **kwargs):
        self.applies += 1
        return SimpleNamespace(state=self.read_state(), verified=True, commands=["off"])


class SafetyGateTests(unittest.TestCase):
    def test_periodic_poll_and_mandatory_per_command_preflight(self):
        cfg = from_dict({"station": {"ssh_alias": "st", "ip": "192.0.2.10"}})
        state = {"ok": True, "calls": 0, "time": 0.0}

        def checks():
            state["calls"] += 1
            return [pf.Check("guard", state["ok"], "test")]

        lamp = DummyLamp()
        sent = []
        gate = SafetyGate(checks, interval=30, clock=lambda: state["time"])
        core = BridgeCore(lamp, cfg, Topics(cfg, 258, 1),
                          lambda t, x, r: sent.append((t, x, r)), safety=gate)
        self.assertTrue(core.poll())
        self.assertTrue(core.poll())
        self.assertEqual(state["calls"], 1, "poll использует только живой cache")
        state["ok"] = False
        core.handle_command(b'{"state":"OFF"}')
        self.assertEqual(lamp.applies, 0)
        self.assertFalse(core.available)
        self.assertEqual(state["calls"], 2)
        self.assertFalse(core.poll())
        self.assertEqual(lamp.reads, 2)
        state["ok"] = True
        state["time"] += 31
        self.assertTrue(core.poll())
        core.handle_command(b'{"state":"OFF"}')
        self.assertEqual(lamp.applies, 1)

    def test_preflight_exceptions_block_commands(self):
        cfg = from_dict({"station": {"ssh_alias": "st"}})
        gate = SafetyGate(lambda: (_ for _ in ()).throw(OSError("boom")))
        lamp = DummyLamp()
        core = BridgeCore(lamp, cfg, Topics(cfg, 258, 1), lambda *x: None, safety=gate)
        core.handle_command(b'{"state":"ON"}')
        self.assertEqual(lamp.applies, 0)
        self.assertFalse(core.available)


class FakeMqttClient:
    def __init__(self, *args, **kwargs):
        self.messages = []
        self.subscriptions = []
    def username_pw_set(self, *a): pass
    def tls_set(self): pass
    def will_set(self, *a, **kw): pass
    def publish(self, topic, payload, **kw):
        self.messages.append((topic, payload))
        return SimpleNamespace(wait_for_publish=lambda *a: None)
    def subscribe(self, topic, qos):
        self.subscriptions.append(topic)


class MqttCallbackTests(unittest.TestCase):
    def test_retained_command_ignored_disconnect_drains_and_reconnect_offline(self):
        cfg = from_dict({'station': {'ssh_alias': 'station'}})
        mockclient = FakeMqttClient()
        module = types.ModuleType('paho.mqtt.client')
        module.CallbackAPIVersion = SimpleNamespace(VERSION2=2)
        module.Client = lambda *a, **k: mockclient
        pkg = types.ModuleType('paho')
        subpkg = types.ModuleType('paho.mqtt')
        pkg.mqtt = subpkg
        subpkg.client = module
        with patch.dict(sys.modules, {'paho': pkg, 'paho.mqtt': subpkg,
                                      'paho.mqtt.client': module}):
            runner = MqttRunner(cfg, SimpleNamespace(), DummyLamp(), Topics(cfg, 258, 1))
        runner._on_message(None, None, SimpleNamespace(retain=True, payload=b'{"state":"ON"}'))
        self.assertTrue(runner._cmds.empty())
        runner._on_message(None, None, SimpleNamespace(retain=False, payload=b'{"state":"ON"}'))
        self.assertFalse(runner._cmds.empty())
        runner._on_disconnect(None, None, None, None)
        self.assertTrue(runner._cmds.empty())
        runner._on_connect(mockclient, None, None, SimpleNamespace(is_failure=False))
        self.assertIn(runner.topics.set, mockclient.subscriptions)
        self.assertIn((runner.topics.avail, 'offline'), mockclient.messages)
        self.assertTrue(any(t == runner.topics.discovery for t, _ in mockclient.messages))


class TransportLimitsTests(unittest.TestCase):
    def test_ssh_exec_large_response_fails(self):
        t = SshExecTransport("station", 8765, [])
        proc = SimpleNamespace(returncode=0, stdout=b"a" * 8, stderr=b"")
        with patch("ymatter.transport.MAX_BODY", 7), patch("ymatter.transport.subprocess.run", return_value=proc):
            with self.assertRaises(MaindError):
                t.request("GET", "/devices", None)

    def test_http_response_over_limit_fails(self):
        from .mock_maind import MockServer
        with MockServer() as srv:
            with patch("ymatter.transport.MAX_BODY", 8):
                with self.assertRaises(MaindError):
                    HttpTransport(srv.url).request("GET", "/devices", None)


@unittest.skipUnless(os.name == "posix" and shutil.which("sh"), "guard.sh требует Unix shell")
class ShellGuardTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = pathlib.Path(self.dir.name)
        # Эмулятор iptables/ip6tables, возвращает реалистичные коды -C/-S/-I/-D.
        mock = r'''#!/bin/sh
base="${0##*/}"
file="$MOCK_ROOT/$base.state"
case "${1:-}" in
  -S) exit 0 ;;
  -C) [ -f "$file" ]; exit $? ;;
  -I) [ "${FAIL_INSERT:-}" != "$base" ] || exit 1
      touch "$file"; exit 0 ;;
  -D) [ "${FAIL_DELETE:-}" != "$base" ] || exit 1
      rm -f "$file"; exit 0 ;;
  *) exit 3 ;;
esac
'''
        for bin in ("iptables", "ip6tables"):
            x = self.root / bin
            x.write_text(mock)
            x.chmod(0o755)
        self.script = pathlib.Path(__file__).resolve().parents[1] / "station" / "guard.sh"

    def call(self, op, **envvars):
        env = dict(os.environ, MOCK_ROOT=str(self.root),
                   PATH=f"{self.root}:{os.environ.get('PATH', '')}", GUARD_PORT="65432")
        env.update(envvars)
        return subprocess.run(["sh", str(self.script), op], capture_output=True, text=True, env=env)

    def test_install_idempotent_remove_and_status(self):
        self.assertEqual(self.call("install").returncode, 0)
        self.assertEqual(self.call("install").returncode, 0)
        self.assertEqual(self.call("status").returncode, 0)
        self.assertEqual(self.call("remove").returncode, 0)
        self.assertFalse((self.root / "iptables.state").exists())
        self.assertFalse((self.root / "ip6tables.state").exists())
        self.assertEqual(self.call("status").returncode, 1)
        self.assertEqual(self.call("remove").returncode, 0)  # уже удалены

    def test_delete_errors_are_not_suppressed(self):
        self.assertEqual(self.call("install").returncode, 0)
        self.assertNotEqual(self.call("remove", FAIL_DELETE="iptables").returncode, 0)
        self.assertTrue((self.root / "iptables.state").exists())
        self.assertTrue((self.root / "ip6tables.state").exists())
        self.assertNotEqual(self.call("remove", FAIL_DELETE="ip6tables").returncode, 0)
        self.assertTrue((self.root / "ip6tables.state").exists())

    def test_failed_ipv6_install_is_not_success(self):
        self.assertNotEqual(self.call("install", FAIL_INSERT="ip6tables").returncode, 0)
        self.assertTrue((self.root / "iptables.state").exists())
        self.assertFalse((self.root / "ip6tables.state").exists())

    def test_invalid_ports_are_rejected(self):
        for p in ("0", "-1", "123;echo bad", "100000", "008765"):
            with self.subTest(p=p):
                self.assertEqual(self.call("install", GUARD_PORT=p).returncode, 64)


if __name__ == "__main__":
    unittest.main()
