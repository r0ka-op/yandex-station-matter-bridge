"""Клиент maind Matter HTTP API с allowlist и строгой проверкой ответов.

Принципы (как в исследовательском репозитории):
  * HTTP 2xx недостаточно: проверяются структура, ошибки Matter, identity
    атрибута/команды и тип TLV;
  * отсутствие поля `errors` у invoke не доказывает успех — нужен `responses`
    со статусом Success;
  * только allowlist (cluster, command/attribute); writeAttribute не реализован;
    вендорные кластеры (0x132FFC06/0A/0C) не используются.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from . import tlv
from .transport import MaindError, MaindUnavailable, Transport, dumps

ONOFF, LEVEL, COLOR, DESCRIPTOR = 6, 8, 768, 29

# (cluster, command)
ALLOWED_INVOKE = {
    (ONOFF, 0),   # Off
    (ONOFF, 1),   # On
    (LEVEL, 0),   # MoveToLevel
    (COLOR, 6),   # MoveToHueAndSaturation
}
OPTIONAL_INVOKE = {(COLOR, 10)}  # explicit opt-in; real invoke has not been exercised

_GLOBAL_ATTRS = range(0xFFF8, 0xFFFE)  # GeneratedCommandList..ClusterRevision
ALLOWED_READ = (
    {(ONOFF, 0), (LEVEL, 0),
     (COLOR, 0), (COLOR, 1), (COLOR, 7), (COLOR, 8),
     (COLOR, 0x400A), (COLOR, 0x400B), (COLOR, 0x400C),
     (DESCRIPTOR, 0), (DESCRIPTOR, 1)}
    | {(c, a) for c in (ONOFF, LEVEL, COLOR, DESCRIPTOR) for a in _GLOBAL_ATTRS}
)


class MaindProtocolError(MaindError):
    """Ответ не соответствует ожидаемой схеме."""


class MaindHttpError(MaindProtocolError):
    """HTTP reached maind, but the route returned a non-2xx status."""

    def __init__(self, method: str, path: str, status: int, body: bytes):
        super().__init__(f"{method} {path}: HTTP {status}: {body[:200]!r}")
        self.method, self.path, self.status, self.body = method, path, status, body


class MaindMatterError(MaindError):
    """Matter вернул ошибку (например, UnsupportedAttribute)."""

    def __init__(self, message: str, errors: Any = None, *, kind: str = "MATTER_ERROR"):
        super().__init__(message)
        self.errors = errors
        self.kind = kind


class UnsupportedAttributeError(MaindMatterError):
    pass


class UnsupportedClusterError(MaindMatterError):
    pass


class NotAllowed(MaindError):
    """Запрос вне allowlist — отклонён до отправки."""


@dataclass(frozen=True)
class Device:
    node_id: int
    endpoints: tuple[int, ...]


def _as_int(v: Any, what: str) -> int:
    if isinstance(v, bool):
        raise MaindProtocolError(f"{what}: bool вместо числа")
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        try:
            return int(v, 0)
        except ValueError:
            pass
    raise MaindProtocolError(f"{what}: не число: {v!r}")


# В полевых ответах встречалось "invoke_callback.cpp:66: Success".
# Разрешаем только точное Success или формат source:line: Success.
_SUCCESS_STATUS = re.compile(r"(?:[A-Za-z0-9_./+\-]+:[0-9]+:\s*)?Success\Z")


def _is_success(status: Any) -> bool:
    return (type(status) is int and status == 0) or (isinstance(status, str)
            and _SUCCESS_STATUS.fullmatch(status) is not None)


def _matter_error(message: str, errors: Any) -> MaindMatterError:
    text = json.dumps(errors, ensure_ascii=False).upper()
    if "UNSUPPORTED_ATTRIBUTE" in text or "UNSUPPORTEDATTRIBUTE" in text:
        return UnsupportedAttributeError(message, errors, kind="UNSUPPORTED_ATTRIBUTE")
    if "UNSUPPORTED_CLUSTER" in text or "UNSUPPORTEDCLUSTER" in text:
        return UnsupportedClusterError(message, errors, kind="UNSUPPORTED_CLUSTER")
    if "ACCESS_DENIED" in text or "ACCESSDENIED" in text:
        return MaindMatterError(message, errors, kind="ACCESS_DENIED")
    return MaindMatterError(message, errors)


class MaindClient:
    def __init__(self, transport: Transport, *, allow_color_temperature: bool = False):
        self.t = transport
        self.allowed_invoke = set(ALLOWED_INVOKE)
        if allow_color_temperature:
            self.allowed_invoke.update(OPTIONAL_INVOKE)

    # --- низкий уровень -------------------------------------------------
    def _json(self, method: str, path: str, payload: Any = None) -> Any:
        body = dumps(payload) if payload is not None else None
        status, data = self.t.request(method, path, body)
        if not 200 <= status < 300:
            raise MaindHttpError(method, path, status, data)
        if not data.strip():
            raise MaindProtocolError(f"{method} {path}: пустой ответ")
        try:
            return json.loads(data)
        except json.JSONDecodeError as exc:
            raise MaindProtocolError(f"{method} {path}: невалидный JSON: {exc}") from exc

    # --- устройства -----------------------------------------------------
    def devices(self) -> list[Device]:
        root = self._json("GET", "/devices")
        if isinstance(root, dict):
            for key in ("result", "devices"):
                if key in root:
                    root = root[key]
        if isinstance(root, dict) and "devices" in root:
            root = root["devices"]
        if not isinstance(root, list):
            raise MaindProtocolError("/devices: ожидался список")
        out = []
        for item in root:
            if not isinstance(item, dict) or "nodeId" not in item:
                raise MaindProtocolError(f"/devices: неожиданный элемент {item!r}")
            eps = item.get("endpoints", [])
            if not isinstance(eps, list):
                raise MaindProtocolError("/devices: endpoints не список")
            out.append(Device(_as_int(item["nodeId"], "nodeId"),
                              tuple(_as_int(e, "endpoint") for e in eps)))
        return out

    # --- чтение ---------------------------------------------------------
    def read(self, node: int, endpoint: int, cluster: int, attr: int) -> Any:
        if (cluster, attr) not in ALLOWED_READ:
            raise NotAllowed(f"чтение {cluster:#x}/{attr:#x} вне allowlist")
        req = {"nodeId": node, "endpointId": endpoint, "clusterId": cluster, "attributeId": attr}
        resp = self._json("POST", "/interaction/readAttribute", req)
        if not isinstance(resp, dict):
            raise MaindProtocolError("readAttribute: ожидался объект")
        errors = resp.get("errors")
        if errors:
            raise _matter_error(f"readAttribute {cluster:#x}/{attr:#x}: {errors!r}", errors)
        values = resp.get("values")
        if not isinstance(values, list) or len(values) != 1 or not isinstance(values[0], dict):
            raise MaindProtocolError("readAttribute: ожидалось ровно одно значение")
        v = values[0]
        if (_as_int(v.get("endpointId"), "endpointId") != endpoint
                or _as_int(v.get("clusterId"), "clusterId") != cluster
                or _as_int(v.get("attributeId"), "attributeId") != attr):
            raise MaindProtocolError("readAttribute: identity ответа не совпала с запросом")
        raw = v.get("rawValue")
        if not isinstance(raw, str):
            raise MaindProtocolError("readAttribute: нет rawValue")
        try:
            return tlv.decode_hex(raw)
        except tlv.TlvError as exc:
            raise MaindProtocolError(f"readAttribute: {exc}") from exc

    # --- команды --------------------------------------------------------
    def invoke(self, node: int, endpoint: int, cluster: int, command: int,
               fields: dict | None = None) -> None:
        if (cluster, command) not in self.allowed_invoke:
            raise NotAllowed(f"команда {cluster:#x}/{command} вне allowlist")
        req = {"nodeId": node, "endpointId": endpoint, "clusterId": cluster,
               "commandId": command, "fields": fields or {}}
        resp = self._json("POST", "/interaction/invokeCommand", req)
        if not isinstance(resp, dict):
            raise MaindProtocolError("invokeCommand: ожидался объект")
        if resp.get("errors"):
            raise _matter_error(f"invokeCommand: {resp['errors']!r}", resp["errors"])
        responses = resp.get("responses")
        if not isinstance(responses, list) or len(responses) != 1 or not isinstance(responses[0], dict):
            raise MaindProtocolError("invokeCommand: ожидался ровно один response")
        r = responses[0]
        if (_as_int(r.get("clusterId"), "clusterId") != cluster
                or _as_int(r.get("commandId"), "commandId") != command
                or _as_int(r.get("endpointId"), "endpointId") != endpoint):
            raise MaindProtocolError("invokeCommand: identity ответа не совпала")
        if "nodeId" in r and _as_int(r["nodeId"], "nodeId") != node:
            raise MaindProtocolError("invokeCommand: nodeId ответа не совпал")
        status = r.get("status")
        if status is None:
            raise MaindProtocolError("invokeCommand: отсутствует status")
        if not _is_success(status):
            raise MaindMatterError(f"invokeCommand: статус {status!r}", status)


__all__ = ["MaindClient", "Device", "MaindError", "MaindUnavailable", "MaindProtocolError",
           "MaindHttpError", "MaindMatterError", "UnsupportedAttributeError",
           "UnsupportedClusterError", "NotAllowed", "ALLOWED_INVOKE", "OPTIONAL_INVOKE",
           "ALLOWED_READ"]
