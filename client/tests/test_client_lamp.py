import unittest

from ymatter.client import (MaindClient, MaindMatterError, MaindProtocolError, NotAllowed)
from ymatter.lamp import Lamp, Request
from ymatter.transport import HttpTransport, MaindUnavailable
from ymatter.config import ConfigError

from .mock_maind import MockServer


def make(srv, **kw):
    client = MaindClient(HttpTransport(srv.url, timeout=2),
                         allow_color_temperature=bool(kw.get("color_temp")))
    lamp = Lamp(client, srv.lamp.node, srv.lamp.ep, sleep=lambda s: None, **kw)
    return client, lamp


class ClientTests(unittest.TestCase):
    def test_devices_and_read(self):
        with MockServer() as srv:
            client, _ = make(srv)
            devs = client.devices()
            self.assertEqual((devs[0].node_id, devs[0].endpoints), (4660, (0, 1)))
            self.assertIs(client.read(4660, 1, 6, 0), False)
            self.assertEqual(client.read(4660, 1, 29, 1), [29, 6, 8, 768])

    def test_allowlist_blocks_before_sending(self):
        with MockServer() as srv:
            client, _ = make(srv)
            with self.assertRaises(NotAllowed):
                client.invoke(4660, 1, 0x132FFC06, 0, {})      # вендорный кластер
            with self.assertRaises(NotAllowed):
                client.invoke(4660, 1, 6, 2, {})               # Toggle не в allowlist
            with self.assertRaises(NotAllowed):
                client.read(4660, 1, 0x132FFC06, 0)
            self.assertEqual(srv.lamp.invokes, [])
            self.assertEqual(srv.lamp.reads, 0)

    def test_protocol_failures_are_errors_not_success(self):
        for mode, exc in (("http503", MaindProtocolError), ("badjson", MaindProtocolError),
                          ("errors", MaindMatterError), ("wrongid", MaindProtocolError)):
            with MockServer() as srv:
                client, _ = make(srv)
                srv.lamp.mode = mode
                with self.assertRaises(exc, msg=f"read/{mode}"):
                    client.read(4660, 1, 6, 0)
        for mode, exc in (("failstatus", MaindMatterError), ("nostatus", MaindProtocolError),
                          ("errors", MaindMatterError), ("wrongid", MaindProtocolError),
                          ("http503", MaindProtocolError)):
            with MockServer() as srv:
                client, _ = make(srv)
                srv.lamp.mode = mode
                with self.assertRaises(exc, msg=f"invoke/{mode}"):
                    client.invoke(4660, 1, 6, 1, {})

    def test_unavailable_when_nothing_listens(self):
        client = MaindClient(HttpTransport("http://127.0.0.1:1", timeout=1))
        with self.assertRaises(MaindUnavailable):
            client.devices()

    def test_non_loopback_url_is_refused(self):
        for url in ("http://192.168.1.50:8765", "http://example.com", "https://127.0.0.1:8765"):
            with self.assertRaises(ConfigError, msg=url):
                HttpTransport(url)


class LampTests(unittest.TestCase):
    def test_on_comes_before_level_and_color_when_off(self):
        with MockServer() as srv:
            _, lamp = make(srv)
            res = lamp.apply(Request(on=True, level=200, hue=85, saturation=244))
            self.assertEqual(res.commands, ["on", "level", "color"])
            self.assertTrue(res.verified)
            self.assertEqual((srv.lamp.on, srv.lamp.level, srv.lamp.hue, srv.lamp.sat),
                             (True, 200, 85, 244))

    def test_no_redundant_on_when_already_on(self):
        with MockServer() as srv:
            srv.lamp.on = True
            _, lamp = make(srv)
            res = lamp.apply(Request(level=64))
            self.assertEqual(res.commands, ["level"])
            self.assertTrue(res.verified)

    def test_brightness_alone_turns_lamp_on(self):
        with MockServer() as srv:
            _, lamp = make(srv)
            res = lamp.apply(Request(level=64))
            self.assertEqual(res.commands, ["on", "level"])
            self.assertTrue(srv.lamp.on and res.verified)

    def test_off_sends_only_off(self):
        with MockServer() as srv:
            srv.lamp.on = True
            _, lamp = make(srv)
            res = lamp.apply(Request(on=False, level=50))
            self.assertEqual(res.commands, ["off"])
            self.assertFalse(srv.lamp.on)
            self.assertTrue(res.verified)

    def test_stale_readback_is_retried_until_confirmed(self):
        with MockServer() as srv:
            srv.lamp.on = True
            _, lamp = make(srv)
            srv.lamp.stale_reads = 6   # первые ~6 чтений показывают старое состояние
            res = lamp.apply(Request(level=30), timeout=30)
            self.assertTrue(res.verified)
            self.assertGreater(res.attempts, 1)

    def test_unconfirmed_state_is_reported_not_hidden(self):
        with MockServer() as srv:
            srv.lamp.on = True
            _, lamp = make(srv)
            srv.lamp.stale_reads = 10_000
            t = iter(range(0, 1000))
            lamp._now = lambda: float(next(t))
            res = lamp.apply(Request(level=30), timeout=3)
            self.assertFalse(res.verified)

    def test_color_temp_disabled_by_default(self):
        with MockServer() as srv:
            _, lamp = make(srv)
            with self.assertRaises(ValueError):
                lamp.apply(Request(mireds=250))
            self.assertEqual(srv.lamp.reads, 0)   # отказ до обращения к сети

    def test_color_temp_when_enabled(self):
        with MockServer() as srv:
            _, lamp = make(srv, color_temp=True)
            res = lamp.apply(Request(on=True, mireds=250))
            self.assertEqual(res.commands, ["on", "color_temp"])
            self.assertTrue(res.verified)
            self.assertEqual(srv.lamp.color_mode, 2)

    def test_request_validation(self):
        for bad in (Request(hue=10), Request(hue=10, saturation=10, mireds=300),
                    Request(level=0), Request(level=255), Request(transition_s=-1)):
            with self.assertRaises(ValueError):
                bad.validate()

    def test_hue_wraparound_matches(self):
        with MockServer() as srv:
            srv.lamp.on = True
            _, lamp = make(srv)
            res = lamp.apply(Request(hue=0, saturation=100))
            self.assertTrue(res.verified)


if __name__ == "__main__":
    unittest.main()
