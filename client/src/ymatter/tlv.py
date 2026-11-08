"""Минимальный декодер Matter TLV для значений атрибутов (rawValue из maind).

Поддержаны скаляры (int, bool, float, null, utf8, bytes) и контейнеры
(struct -> dict по context-тегу, array/list -> list). Любая усечённая или
некорректная последовательность даёт TlvError (fail-closed).
"""
from __future__ import annotations

import struct
from typing import Any


class TlvError(ValueError):
    pass


_TAG_LEN = {0: 0, 1: 1, 2: 2, 3: 4, 4: 2, 5: 4, 6: 6, 7: 8}
_END = object()


def _take(data: bytes, pos: int, n: int) -> tuple[bytes, int]:
    if n < 0 or pos + n > len(data):
        raise TlvError(f"усечённый TLV: offset {pos}, нужно {n} байт")
    return data[pos:pos + n], pos + n


def _read(data: bytes, pos: int):
    """Возвращает (tag, value|_END, new_pos)."""
    raw, pos = _take(data, pos, 1)
    ctrl = raw[0]
    etype, tag_ctl = ctrl & 0x1F, ctrl >> 5
    tag_raw, pos = _take(data, pos, _TAG_LEN[tag_ctl])
    tag: Any = None
    if tag_ctl == 1:
        tag = tag_raw[0]
    elif tag_ctl != 0:
        tag = tag_raw.hex()

    if etype == 24:
        if tag_ctl != 0:
            raise TlvError("end-of-container с тегом")
        return None, _END, pos
    if 0 <= etype <= 3:
        b, pos = _take(data, pos, 1 << etype)
        return tag, int.from_bytes(b, "little", signed=True), pos
    if 4 <= etype <= 7:
        b, pos = _take(data, pos, 1 << (etype - 4))
        return tag, int.from_bytes(b, "little", signed=False), pos
    if etype == 8:
        return tag, False, pos
    if etype == 9:
        return tag, True, pos
    if etype in (10, 11):
        b, pos = _take(data, pos, 4 if etype == 10 else 8)
        return tag, struct.unpack("<f" if etype == 10 else "<d", b)[0], pos
    if 12 <= etype <= 19:
        base = 12 if etype <= 15 else 16
        lb, pos = _take(data, pos, 1 << (etype - base))
        body, pos = _take(data, pos, int.from_bytes(lb, "little"))
        if base == 12:
            try:
                return tag, body.decode("utf-8"), pos
            except UnicodeDecodeError as exc:
                raise TlvError("некорректный UTF-8") from exc
        return tag, bytes(body), pos
    if etype == 20:
        return tag, None, pos
    if etype in (21, 22, 23):
        items: list = []
        keyed: dict = {}
        while True:
            t, v, pos = _read(data, pos)
            if v is _END:
                break
            items.append(v)
            if etype == 21:
                keyed[t if isinstance(t, int) else f"tag{len(keyed)}"] = v
        return tag, (keyed if etype == 21 else items), pos
    raise TlvError(f"зарезервированный тип элемента {etype}")


def decode(data: bytes) -> Any:
    tag, value, pos = _read(data, 0)
    if value is _END:
        raise TlvError("неожиданный end-of-container")
    if pos != len(data):
        raise TlvError(f"лишние байты после элемента: {len(data) - pos}")
    return value


def decode_hex(text: str) -> Any:
    s = text.strip()
    if s[:2].lower() == "0x":
        s = s[2:]
    try:
        raw = bytes.fromhex(s)
    except ValueError as exc:
        raise TlvError(f"rawValue не hex: {text!r}") from exc
    if not raw:
        raise TlvError("пустой rawValue")
    return decode(raw)


def encode_uint(value: int) -> bytes:
    """Анонимный unsigned int минимальной ширины (для тестовых моков)."""
    if value < 0:
        raise ValueError("только unsigned")
    for etype, width in ((4, 1), (5, 2), (6, 4), (7, 8)):
        if value < (1 << (8 * width)):
            return bytes([etype]) + value.to_bytes(width, "little")
    raise ValueError("слишком большое значение")


def encode_bool(value: bool) -> bytes:
    return bytes([9 if value else 8])
