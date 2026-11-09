#!/usr/bin/env python3
"""Offline model of maind's JSON-to-byte-container conversion.

The implementation is deliberately transport-free.  It models only the
valid input forms established by static analysis of the pinned maind binary;
uncertain values are rejected instead of emulating C++ truncation behavior.
"""
from __future__ import annotations

import re
from typing import Any


class BinaryCodecError(ValueError):
    pass


_HEX = re.compile(r"(?:[0-9A-Fa-f]{2})*")


def decode_maind_binary(value: Any) -> bytes:
    """Decode one binary JSON value accepted by maind command parsers.

    Confirmed forms are null, an even-length hexadecimal string, or an array
    of byte-valued JSON integers.  Objects (including base64 wrappers) are not
    part of this conversion path.
    """

    if value is None:
        return b""
    if isinstance(value, str):
        if _HEX.fullmatch(value) is None:
            raise BinaryCodecError("binary string must contain hex pairs only")
        return bytes.fromhex(value)
    if isinstance(value, list):
        result = bytearray()
        for index, item in enumerate(value):
            if isinstance(item, bool) or not isinstance(item, int):
                raise BinaryCodecError(f"byte {index} must be an integer")
            if not 0 <= item <= 255:
                raise BinaryCodecError(f"byte {index} must be in 0..255")
            result.append(item)
        return bytes(result)
    raise BinaryCodecError("binary value must be null, a hex string, or a byte array")
