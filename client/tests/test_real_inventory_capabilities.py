import json
import pathlib
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from ymatter.capabilities import discover_endpoint_capabilities
from ymatter.cli import _pick_target
from ymatter.client import (MaindClient, MaindHttpError, MaindMatterError,
                            NotAllowed, UnsupportedAttributeError)
from ymatter.config import Config
from ymatter.lamp import Lamp, Request
from ymatter.transport import HttpTransport, SshExecTransport

from .mock_maind import MockServer


FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "real_inventory_capabilities.public.json"


class FixtureReader:
    def __init__(self, fixture):
        self.f = fixture

    def read(self, node, endpoint, cluster, attr):
        target = self.f["target"]
        if (cluster, attr) == (29, 0):
            return [{0: v, 1: 2} for v in target["deviceTypes"]]
        if (cluster, attr) == (29, 1):
            return target["serverClusters"]
        if attr == 0xFFFB:
            return target["attributes"][str(cluster)]
        if attr == 0xFFF9:
            return target["acceptedCommands"][str(cluster)]
        if attr == 0xFFFC:
            return target["featureMaps"][str(cluster)]
        if (cluster, attr) == (768, 0x400B):
            return target["colorTemperatureMireds"]["min"]
        if (cluster, attr) == (768, 0x400C):
            return target["colorTemperatureMireds"]["max"]
        raise UnsupportedAttributeError("fixture unsupported", [], kind="UNSUPPORTED_ATTRIBUTE")


class RealInventoryFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_fixture_is_sanitized_and_not_bound_to_real_node(self):
        raw = FIXTURE.read_text(encoding="utf-8")
        self.assertEqual(self.fixture["nodeId"], 4660)
        self.assertNotEqual(self.fixture["nodeId"], 258)
        for forbidden in ("macAddress", "serialNumber", "certificate", "fabricId"):
            self.assertNotIn(forbidden, raw)

    def test_discovery_uses_real_inventory_contract(self):
        caps = discover_endpoint_capabilities(FixtureReader(self.fixture), 4660, 1)
        self.assertTrue(caps.is_light)
        self.assertEqual(caps.device_types, (269,))
        self.assertTrue(caps.supports_command(8, 0))
        self.assertTrue(caps.supports_command(768, 10))
        self.assertEqual((caps.color_temp_min_mireds, caps.color_temp_max_mireds), (154, 370))
        self.assertTrue(caps.color_temperature_supported)

    def test_http_500_is_not_reported_as_transport_failure(self):
        proc = SimpleNamespace(returncode=0, stdout=b"", stderr=(
            b"  HTTP/1.1 500 Internal Server Error\n__YMATTER_WGET_EXIT__=1\n"))
        t = SshExecTransport("station", 8765, [])
        with patch("ymatter.transport.subprocess.run", return_value=proc):
            self.assertEqual(t.request("GET", "/devices", None), (500, b""))

    def test_client_exposes_http_status(self):
        class T:
            def request(self, method, path, body):
                return 500, b"failure"
        with self.assertRaises(MaindHttpError) as caught:
            MaindClient(T()).devices()
        self.assertEqual(caught.exception.status, 500)

    def test_color_temperature_command_requires_explicit_client_opt_in(self):
        with MockServer() as srv:
            caps = discover_endpoint_capabilities(
                MaindClient(HttpTransport(srv.url)), srv.lamp.node, srv.lamp.ep)
            lamp = Lamp(MaindClient(HttpTransport(srv.url)), srv.lamp.node, srv.lamp.ep,
                        color_temp=True, capabilities=caps, sleep=lambda _: None)
            with self.assertRaises(NotAllowed):
                lamp.apply(Request(mireds=250))
            self.assertEqual(srv.lamp.invokes, [])

    def test_color_temperature_range_and_declared_command(self):
        with MockServer() as srv:
            client = MaindClient(HttpTransport(srv.url), allow_color_temperature=True)
            caps = discover_endpoint_capabilities(client, srv.lamp.node, srv.lamp.ep)
            lamp = Lamp(client, srv.lamp.node, srv.lamp.ep, color_temp=True,
                        capabilities=caps, sleep=lambda _: None)
            with self.assertRaises(ValueError):
                lamp.apply(Request(mireds=153))
            self.assertEqual(srv.lamp.invokes, [])
            self.assertTrue(lamp.apply(Request(mireds=250, transition_s=0.5)).verified)
            self.assertEqual(srv.lamp.invokes[-1], (768, 10, {
                "colorTemperatureMireds": 250,
                "transitionTime": 5,
                "optionsMask": 0,
                "optionsOverride": 0,
            }))

    def test_target_selection_uses_descriptor_not_observed_node(self):
        with MockServer() as srv:
            client = MaindClient(HttpTransport(srv.url))
            node, endpoint, caps = _pick_target(Config(), client)
            self.assertEqual((node, endpoint), (4660, 1))
            self.assertTrue(caps.is_light)

    def test_only_unsupported_attribute_is_optional(self):
        with MockServer() as srv:
            _, lamp = (MaindClient(HttpTransport(srv.url)), None)
            client = MaindClient(HttpTransport(srv.url))
            lamp = Lamp(client, srv.lamp.node, srv.lamp.ep)
            srv.lamp.mode = "errors"
            self.assertIsNone(lamp._opt(8, 0))

        class FatalClient:
            def read(self, *args):
                raise MaindMatterError("access denied", [], kind="ACCESS_DENIED")
        with self.assertRaises(MaindMatterError):
            Lamp(FatalClient(), 4660, 1)._opt(8, 0)


if __name__ == "__main__":
    unittest.main()
