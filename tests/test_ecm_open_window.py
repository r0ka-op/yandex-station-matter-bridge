import base64
import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "tools" / "ecm_open_window.py"
SPEC = importlib.util.spec_from_file_location("ecm_open_window", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def encoded(length: int) -> dict[str, str]:
    return {"base64": base64.b64encode(bytes([0xA5]) * length).decode("ascii")}


def valid() -> dict:
    return {
        "commissioningTimeout": 300,
        "PAKEPasscodeVerifier": encoded(97),
        "discriminator": 3840,
        "iterations": 1000,
        "salt": encoded(32),
    }


class EcmValidationTests(unittest.TestCase):
    def test_valid_schema_is_redacted_and_hardcoded(self):
        request = MODULE.EcmRequest.from_mapping(valid())
        plan = request.redacted_plan()
        self.assertEqual(plan["target"], {"endpointId": 0, "clusterId": 60, "commandId": 0})
        self.assertTrue(plan["mustUseTimedInvoke"])
        self.assertFalse(plan["genericHttpParserSupportsCluster003C"])
        self.assertEqual(plan["dedicatedRouteCandidate"], "/commissioning/window")
        self.assertFalse(plan["network_attempted"])
        self.assertNotIn("base64", str(plan))
        self.assertEqual([field["tag"] for field in plan["fields"]], [0, 1, 2, 3, 4])
        self.assertEqual(plan["fields"][1]["length"], 97)
        self.assertEqual(plan["fields"][4]["length"], 32)

    def test_verifier_length_boundaries(self):
        for length in (0, 96, 98, 256):
            data = valid()
            data["PAKEPasscodeVerifier"] = encoded(length)
            with self.assertRaises(MODULE.ValidationError):
                MODULE.EcmRequest.from_mapping(data)

    def test_salt_boundaries(self):
        for length in (15, 33):
            data = valid()
            data["salt"] = encoded(length)
            with self.assertRaises(MODULE.ValidationError):
                MODULE.EcmRequest.from_mapping(data)
        for length in (16, 32):
            data = valid()
            data["salt"] = encoded(length)
            self.assertEqual(len(MODULE.EcmRequest.from_mapping(data).salt), length)

    def test_numeric_boundaries(self):
        for name, bad_values in {
            "commissioningTimeout": (0, 65536, True),
            "discriminator": (-1, 4096, True),
            "iterations": (999, 100001, True),
        }.items():
            for value in bad_values:
                data = valid()
                data[name] = value
                with self.assertRaises(MODULE.ValidationError):
                    MODULE.EcmRequest.from_mapping(data)

    def test_rejects_extra_fields_and_noncanonical_binary_forms(self):
        data = valid()
        data["commandId"] = 0
        with self.assertRaises(MODULE.ValidationError):
            MODULE.EcmRequest.from_mapping(data)
        for value in ([1] * 97, "00" * 97, {"hex": "00" * 97}):
            data = valid()
            data["PAKEPasscodeVerifier"] = value
            with self.assertRaises(MODULE.ValidationError):
                MODULE.EcmRequest.from_mapping(data)


if __name__ == "__main__":
    unittest.main()
