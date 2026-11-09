import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CODEC = load("maind_binary_codec", "maind_binary_codec.py")
WINDOW = load("maind_commissioning_window", "maind_commissioning_window.py")


class MaindBinaryCodecTests(unittest.TestCase):
    def test_hex_preserves_all_byte_classes(self):
        expected = bytes((0x00, 0x7F, 0x80, 0xFF))
        self.assertEqual(CODEC.decode_maind_binary("007f80FF"), expected)
        self.assertEqual(CODEC.decode_maind_binary([0, 127, 128, 255]), expected)

    def test_ecm_lengths_round_trip(self):
        verifier = bytes(range(97))
        salt = bytes((0x00, 0x7F, 0x80, 0xFF)) * 4
        self.assertEqual(CODEC.decode_maind_binary(verifier.hex()), verifier)
        self.assertEqual(CODEC.decode_maind_binary(salt.hex()), salt)

    def test_empty_and_invalid_forms(self):
        self.assertEqual(CODEC.decode_maind_binary(None), b"")
        self.assertEqual(CODEC.decode_maind_binary(""), b"")
        for value in ("0", "0g", "00 7f", {"base64": "AA=="}, [256], [-1], [True], [1.0]):
            with self.assertRaises(CODEC.BinaryCodecError):
                CODEC.decode_maind_binary(value)


class DedicatedWindowRequestTests(unittest.TestCase):
    def test_exact_route_contract(self):
        request = WINDOW.WindowRequest.validate(0x1234, 0xABC, 300)
        plan = request.dry_run()
        self.assertEqual(plan["method"], "POST")
        self.assertEqual(plan["path"], "/commissioning/window")
        self.assertEqual(set(plan["body"]), {"nodeId", "discriminator", "timeout"})
        self.assertTrue(plan["maind_generates_setup_pin_salt_and_verifier"])
        self.assertFalse(plan["network_attempted"])

    def test_config_boundaries(self):
        for discriminator in (0, 4095):
            for timeout in (180, 900):
                WINDOW.WindowRequest.validate(1, discriminator, timeout)
        for args in ((0, 1, 300), (1, -1, 300), (1, 4096, 300), (1, 1, 179), (1, 1, 901)):
            with self.assertRaises(WINDOW.ValidationError):
                WINDOW.WindowRequest.validate(*args)


if __name__ == "__main__":
    unittest.main()
