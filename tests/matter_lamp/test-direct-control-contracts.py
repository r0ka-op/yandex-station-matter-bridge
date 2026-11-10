import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCHER = ROOT / "deploy" / "matter-server-direct" / "patch-direct-invoke.mjs"
CLIENT = ROOT / "tools" / "matter_lamp" / "matter-lamp-client.mjs"
INVENTORY = ROOT / "docs" / "multi_admin" / "YNDX00560_INVENTORY.json"


class DirectControlContracts(unittest.TestCase):
    def test_direct_invoke_is_narrowly_allowlisted(self):
        source = PATCHER.read_text(encoding="utf-8")
        self.assertIn('String(nodeId) === directNodeId', source)
        self.assertIn('endpointId === 1', source)
        entries = re.findall(r'\[(6|8|80|768), new Set\(\[(.*?)\]\)\]', source)
        actual = {
            int(cluster): set(re.findall(r'"([^"]+)"', commands))
            for cluster, commands in entries
        }
        self.assertEqual(
            actual,
            {
                6: {"off", "on"},
                8: {"moveToLevel"},
                80: {"changeToMode"},
                768: {"moveToHueAndSaturation", "moveToColorTemperature"},
            },
        )
        for forbidden in ("write_attribute", "commission_with_code", "remove_fabric", "invokeCommand"):
            self.assertNotIn(forbidden, source)
        self.assertIn("allowedSceneModes = new Set([1, 4, 6, 13])", source)
        self.assertIn('keys.length !== 1 || keys[0] !== "newMode"', source)

    def test_client_has_bounded_interactions_and_no_retry_loop(self):
        source = CLIENT.read_text(encoding="utf-8")
        self.assertIn("interaction_timeout_ms: 8_000", source)
        self.assertIn("response timeout; result is ambiguous", source)
        self.assertNotRegex(source, r"\bwhile\s*\(")
        self.assertNotRegex(source, r"\bsetInterval\s*\(")
        self.assertNotIn("commission_with_code", source)
        self.assertIn('vendorMode === 2', source)
        self.assertIn('readback.lastSelectedSceneId !== newMode', source)
        self.assertIn('onOff === true && vendorMode === 2', source)
        self.assertIn('enumOnlyModesIncluded: false', source)

    def test_public_inventory_is_redacted(self):
        raw = INVENTORY.read_text(encoding="utf-8")
        data = json.loads(raw)
        self.assertIn("redacted", data["classification"])
        for endpoint_id, endpoint in data["endpoints"].items():
            for cluster_id, cluster in endpoint["clusters"].items():
                if endpoint_id == "0" or int(cluster_id) >= 0x10000:
                    self.assertTrue(cluster["attributes"])
                    self.assertTrue(all(value == {"redacted": True} for value in cluster["attributes"].values()))
        for forbidden in (
            "manualCode", "qrCode", "privateKey", "operationalKey",
            "password", "ssid", "wKgKZw",
        ):
            self.assertNotIn(forbidden, raw)


if __name__ == "__main__":
    unittest.main()
