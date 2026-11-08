import json
import unittest
from pathlib import Path

from ymatter import preflight as pf
from ymatter.bridge import (BridgeCore, Topics, discovery_payload, parse_command, state_payload)
from ymatter.client import MaindClient
from ymatter.config import ConfigError, from_dict
from ymatter.lamp import Lamp, LampState
from ymatter.transport import HttpTransport

from .mock_maind import MockServer

MAIND = next(iter(pf.KNOWN_MAIND))
LAUNCHER = next(iter(pf.KNOWN_LAUNCHER))
CLIENT_ROOT = Path(__file__).resolve().parents[1]


def cfg(**station):
    return from_dict({"station": {"ssh_alias": "st", "ip": "192.0.2.10", **station}})


def good_output(g4="0", g6="0", listener="1", maind=MAIND, launcher=LAUNCHER):
    return (f"ssh=ok\nguard4={g4}\nguard6={g6}\nlistener={listener}\n"
            f"sha {maind}  {pf.MAIND_PATH}\nsha {launcher}  {pf.LAUNCHER_PATH}\n")


def runner(out, rc=0):
    return lambda script: (rc, out, "")


class PreflightTests(unittest.TestCase):
    def test_all_good(self):
        checks = pf.run_preflight(cfg(), runner(good_output()), probe=lambda h, p: "closed")
        self.assertTrue(pf.passed(checks), pf.format_checks(checks))

    def test_missing_ipv6_guard_fails(self):
        checks = pf.run_preflight(cfg(), runner(good_output(g6="1")), probe=lambda h, p: "closed")
        self.assertFalse(pf.passed(checks))

    def test_unknown_firmware_fails_unless_allowed(self):
        out = good_output(maind="ab" * 32)
        self.assertFalse(pf.passed(pf.run_preflight(cfg(), runner(out), probe=lambda h, p: "closed")))
        c = from_dict({"station": {"ssh_alias": "st", "ip": "192.0.2.10"},
                       "safety": {"allow_unknown_firmware": True}})
        self.assertTrue(pf.passed(pf.run_preflight(c, runner(out), probe=lambda h, p: "closed")))
        c2 = from_dict({"station": {"ssh_alias": "st", "ip": "192.0.2.10"},
                        "safety": {"extra_maind_sha256": ["AB" * 32]}})
        self.assertTrue(pf.passed(pf.run_preflight(c2, runner(out), probe=lambda h, p: "closed")))

    def test_port_open_from_lan_is_fatal(self):
        checks = pf.run_preflight(cfg(), runner(good_output()), probe=lambda h, p: "open")
        self.assertFalse(pf.passed(checks))
        self.assertIn("ОТКРЫТ", pf.format_checks(checks))

    def test_ssh_down_stops_early(self):
        checks = pf.run_preflight(cfg(), runner("", rc=255), probe=lambda h, p: "closed")
        self.assertFalse(pf.passed(checks))
        self.assertEqual(len(checks), 1)

    def test_no_listener_is_only_a_warning(self):
        checks = pf.run_preflight(cfg(), runner(good_output(listener="0")), probe=lambda h, p: "closed")
        self.assertTrue(pf.passed(checks))

    def test_missing_station_ip_fails_closed(self):
        c = from_dict({"station": {"ssh_alias": "st"}})
        checks = pf.run_preflight(c, runner(good_output()), probe=lambda h, p: "closed")
        self.assertFalse(pf.passed(checks))

    def test_remote_script_uses_same_rule_as_guard_sh(self):
        rule = pf.guard_rule(8765)
        self.assertIn(rule, pf.remote_script(8765))
        with (CLIENT_ROOT / "station" / "guard.sh").open(encoding="utf-8") as fh:
            self.assertIn(rule, fh.read().replace("$PORT", "8765"))


class ConfigTests(unittest.TestCase):
    def test_typos_and_bad_values_rejected(self):
        with self.assertRaises(ConfigError):
            from_dict({"station": {"ssh_alias": "x", "ssh_aliass": "y"}})
        with self.assertRaises(ConfigError):
            from_dict({"station": {"transport": "tunnel"}})
        with self.assertRaises(ConfigError):
            from_dict({"station": {"ssh_alias": "x"}, "bridge": {"poll_interval": 0.5}})
        c = from_dict({"station": {"ssh_alias": "x"}, "lamp": {"node_id": "0x1234", "endpoint_id": 1}})
        self.assertEqual(c.lamp.node_id, 0x1234)


class BridgePayloadTests(unittest.TestCase):
    def test_parse_command_ok(self):
        r = parse_command(b'{"state":"ON","brightness":128,"color":{"h":120,"s":100},"transition":2}')
        self.assertEqual((r.on, r.level, r.hue, r.saturation, r.transition_s), (True, 128, 85, 254, 2.0))

    def test_parse_command_rejects_garbage(self):
        bad = [b"nope", b"[1]", b'{"state":"TOGGLE"}', b'{"brightness":"hi"}', b'{"brightness":true}',
               b'{"color":{"h":1}}', b'{"color_temp":4000}', b'{"transition":-5}']
        for payload in bad:
            with self.assertRaises(ValueError, msg=payload):
                parse_command(payload)

    def test_color_temp_requires_flag_and_bounds(self):
        with self.assertRaises(ValueError):
            parse_command(b'{"color_temp":1000}', color_temp=True, min_kelvin=2700, max_kelvin=6500)
        r = parse_command(b'{"color_temp":2700}', color_temp=True, min_kelvin=2700, max_kelvin=6500)
        self.assertEqual(r.mireds, 370)

    def test_state_payload(self):
        self.assertEqual(state_payload(LampState(on=False)), {"state": "OFF"})
        p = state_payload(LampState(on=True, level=200, hue=85, saturation=254, color_mode=0))
        self.assertEqual(p, {"state": "ON", "brightness": 200, "color_mode": "hs",
                             "color": {"h": 120, "s": 100}})
        p = state_payload(LampState(on=True, level=10, color_mode=2, mireds=250), color_temp=True)
        self.assertEqual((p["color_mode"], p["color_temp"]), ("color_temp", 4000))

    def test_discovery_payload(self):
        c = cfg()
        t = Topics(c, 4660, 1)
        d = discovery_payload(c, t)
        self.assertEqual(d["schema"], "json")
        self.assertEqual(d["supported_color_modes"], ["hs"])
        self.assertEqual(d["brightness_scale"], 254)
        self.assertNotIn("color_temp_kelvin", d)
        self.assertEqual(t.discovery, "homeassistant/light/ymatter_1234_1/config")
        json.dumps(d)  # сериализуется


class BridgeCoreTests(unittest.TestCase):
    def setUp(self):
        self.srv = MockServer().__enter__()
        self.addCleanup(self.srv.__exit__, None, None, None)
        self.cfg = cfg()
        client = MaindClient(HttpTransport(self.srv.url, timeout=2))
        lamp = Lamp(client, 4660, 1, sleep=lambda s: None)
        self.sent = []
        self.core = BridgeCore(lamp, self.cfg, Topics(self.cfg, 4660, 1),
                               lambda t, p, r: self.sent.append((t, p, r)))

    def topics(self):
        return [t for t, _, _ in self.sent]

    def test_poll_publishes_availability_and_state_once(self):
        self.assertTrue(self.core.poll())
        self.assertTrue(self.core.poll())
        self.assertEqual(self.topics().count("ymatter/1234_1/availability"), 1)
        self.assertEqual(self.topics().count("ymatter/1234_1/state"), 1)   # без дублей

    def test_command_applies_and_publishes_readback_state(self):
        self.core.handle_command(b'{"state":"ON","brightness":150,"color":{"h":0,"s":100}}')
        self.assertTrue(self.srv.lamp.on)
        state = json.loads([p for t, p, _ in self.sent if t.endswith("/state")][-1])
        self.assertEqual((state["state"], state["brightness"]), ("ON", 150))

    def test_bad_command_does_not_touch_lamp(self):
        self.core.handle_command(b'{"brightness":"x"}')
        self.assertEqual(self.srv.lamp.invokes, [])

    def test_api_down_marks_unavailable_then_recovers(self):
        self.core.poll()
        self.srv.lamp.mode = "http503"
        self.assertFalse(self.core.poll())
        self.assertEqual(self.core.available, False)
        self.srv.lamp.mode = "ok"
        self.assertTrue(self.core.poll())
        self.assertEqual(self.core.available, True)
        avail = [p for t, p, _ in self.sent if t.endswith("/availability")]
        self.assertEqual(avail, ["online", "offline", "online"])


if __name__ == "__main__":
    unittest.main()
