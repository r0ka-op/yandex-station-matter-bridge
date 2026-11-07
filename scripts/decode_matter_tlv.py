#!/usr/bin/env python3
import argparse
import json
import struct
import sys


TYPE_NAMES = {
    0: "signed_int_1", 1: "signed_int_2", 2: "signed_int_4", 3: "signed_int_8",
    4: "unsigned_int_1", 5: "unsigned_int_2", 6: "unsigned_int_4", 7: "unsigned_int_8",
    8: "boolean_false", 9: "boolean_true", 10: "float_4", 11: "float_8",
    12: "utf8_1", 13: "utf8_2", 14: "utf8_4", 15: "utf8_8",
    16: "bytes_1", 17: "bytes_2", 18: "bytes_4", 19: "bytes_8",
    20: "null", 21: "structure", 22: "array", 23: "list", 24: "end_of_container",
}
TAG_BYTES = {0: 0, 1: 1, 2: 2, 3: 4, 4: 2, 5: 4, 6: 6, 7: 8}


class TlvError(ValueError):
    pass


class Decoder:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, count):
        if count < 0 or self.pos + count > len(self.data):
            raise TlvError(f"truncated TLV at offset {self.pos}, need {count} bytes")
        value = self.data[self.pos:self.pos + count]
        self.pos += count
        return value

    def uint(self, count):
        return int.from_bytes(self.take(count), "little", signed=False)

    def tag(self, control):
        raw = self.take(TAG_BYTES[control])
        if control == 0:
            return {"control": "anonymous"}
        if control == 1:
            return {"control": "context", "number": raw[0]}
        if control in (2, 3):
            return {"control": "common_profile", "number": int.from_bytes(raw, "little")}
        if control in (4, 5):
            return {"control": "implicit_profile", "number": int.from_bytes(raw, "little")}
        tag_width = 2 if control == 6 else 4
        return {
            "control": "fully_qualified",
            "vendor_id": int.from_bytes(raw[0:2], "little"),
            "profile_id": int.from_bytes(raw[2:4], "little"),
            "number": int.from_bytes(raw[4:4 + tag_width], "little"),
        }

    def element(self, allow_end=False):
        offset = self.pos
        control_byte = self.uint(1)
        element_type = control_byte & 0x1F
        tag_control = control_byte >> 5
        if element_type not in TYPE_NAMES:
            raise TlvError(f"reserved element type {element_type} at offset {offset}")
        if element_type == 24:
            if tag_control != 0:
                raise TlvError(f"end-of-container has a tag at offset {offset}")
            if not allow_end:
                raise TlvError(f"unexpected end-of-container at offset {offset}")
            return {"type": "end_of_container", "offset": offset}

        node = {
            "type": TYPE_NAMES[element_type],
            "offset": offset,
            "tag": self.tag(tag_control),
        }
        if 0 <= element_type <= 3:
            width = 1 << element_type
            node["value"] = int.from_bytes(self.take(width), "little", signed=True)
        elif 4 <= element_type <= 7:
            width = 1 << (element_type - 4)
            node["value"] = self.uint(width)
        elif element_type == 8:
            node["value"] = False
        elif element_type == 9:
            node["value"] = True
        elif element_type == 10:
            node["value"] = struct.unpack("<f", self.take(4))[0]
        elif element_type == 11:
            node["value"] = struct.unpack("<d", self.take(8))[0]
        elif 12 <= element_type <= 19:
            length_width = 1 << ((element_type - 12) % 4)
            length = self.uint(length_width)
            raw = self.take(length)
            node["length"] = length
            if element_type <= 15:
                try:
                    node["value"] = raw.decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise TlvError(f"invalid UTF-8 at offset {offset}: {exc}") from exc
            else:
                node["value_hex"] = raw.hex()
        elif element_type == 20:
            node["value"] = None
        elif element_type in (21, 22, 23):
            children = []
            while True:
                child = self.element(allow_end=True)
                if child["type"] == "end_of_container":
                    break
                children.append(child)
            node["children"] = children
        node["end_offset"] = self.pos
        return node

    def document(self):
        elements = []
        while self.pos < len(self.data):
            elements.append(self.element())
        return {"byte_length": len(self.data), "elements": elements, "trailing_bytes": 0}


def parse_hex(text):
    value = text.strip()
    if value.lower().startswith("0x"):
        value = value[2:]
    if not value or len(value) % 2:
        raise TlvError("hex input must contain a non-empty even number of digits")
    try:
        return bytes.fromhex(value)
    except ValueError as exc:
        raise TlvError(f"invalid hex input: {exc}") from exc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hex", required=True)
    args = parser.parse_args()
    try:
        data = parse_hex(args.hex)
        result = Decoder(data).document()
        result["input_hex"] = "0x" + data.hex()
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    except TlvError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
