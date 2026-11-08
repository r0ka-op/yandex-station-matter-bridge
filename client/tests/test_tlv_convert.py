import unittest

from ymatter import convert, tlv


class TlvTests(unittest.TestCase):
    def test_fixtures_from_research_repo(self):
        self.assertEqual(tlv.decode_hex("0x16041d0406040805000318"), [29, 6, 8, 768])
        self.assertEqual(tlv.decode_hex("0x0480"), 128)
        self.assertEqual(tlv.decode_hex("0x1604000401040204040405040618"), [0, 1, 2, 4, 5, 6])
        self.assertEqual(tlv.decode_hex("0x160400040105f9ff05fbff05fcff18"), [0, 1, 0xFFF9, 0xFFFB, 0xFFFC])
        self.assertEqual(tlv.decode_hex("0x0619000000"), 25)
        self.assertIs(tlv.decode_hex("0x09"), True)
        self.assertIs(tlv.decode_hex("0x08"), False)

    def test_malformed_is_rejected(self):
        for bad in ("0x16041d", "0x", "0x0480ff", "0x18", "0x05ff", "zz"):
            with self.assertRaises(tlv.TlvError, msg=bad):
                tlv.decode_hex(bad)

    def test_struct_and_null(self):
        # struct{ ctx1: uint8 4, ctx2: uint8 7 }
        self.assertEqual(tlv.decode(bytes.fromhex("15" "240104" "240207" "18")), {1: 4, 2: 7})
        self.assertIsNone(tlv.decode(bytes([0x14])))

    def test_roundtrip_uint(self):
        for v in (0, 1, 255, 256, 65535, 65536, 2**32 - 1, 2**32):
            self.assertEqual(tlv.decode(tlv.encode_uint(v)), v)


class ConvertTests(unittest.TestCase):
    def test_hue_sat(self):
        self.assertEqual(convert.hue_ha_to_matter(0), 0)
        self.assertEqual(convert.hue_ha_to_matter(360), 0)
        self.assertEqual(convert.hue_ha_to_matter(120), 85)
        self.assertEqual(convert.sat_ha_to_matter(100), 254)
        self.assertEqual(convert.hue_matter_to_ha(85), 120)
        self.assertEqual(convert.sat_matter_to_ha(254), 100)

    def test_level_bounds(self):
        self.assertEqual(convert.level_clamp(0), 1)
        self.assertEqual(convert.level_clamp(999), 254)
        self.assertEqual(convert.percent_to_level(100), 254)
        self.assertEqual(convert.percent_to_level(0), 0)

    def test_kelvin_and_transition(self):
        self.assertEqual(convert.kelvin_to_mireds(4000), 250)
        self.assertEqual(convert.mireds_to_kelvin(250), 4000)
        self.assertEqual(convert.seconds_to_tenths(1.5), 15)
        self.assertEqual(convert.seconds_to_tenths(1e9), 65534)
        with self.assertRaises(ValueError):
            convert.kelvin_to_mireds(0)


if __name__ == "__main__":
    unittest.main()
