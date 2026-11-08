"""Высокоуровневое управление лампой: план команд, readback-проверка."""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Optional

from .capabilities import EndpointCapabilities
from .client import COLOR, LEVEL, ONOFF, MaindClient, UnsupportedAttributeError
from .convert import seconds_to_tenths

LEVEL_TOL = 2
HUE_TOL = 2
SAT_TOL = 2
MIREDS_TOL = 5
HUE_MODULUS = 254


@dataclass(frozen=True)
class LampState:
    on: Optional[bool] = None
    level: Optional[int] = None
    hue: Optional[int] = None
    saturation: Optional[int] = None
    color_mode: Optional[int] = None   # 0 = HS, 1 = XY, 2 = температура
    mireds: Optional[int] = None


@dataclass
class Request:
    on: Optional[bool] = None
    level: Optional[int] = None        # Matter 1..254
    hue: Optional[int] = None          # Matter 0..254
    saturation: Optional[int] = None   # Matter 0..254
    mireds: Optional[int] = None
    transition_s: float = 0.0

    def validate(self) -> None:
        if (self.hue is None) != (self.saturation is None):
            raise ValueError("hue и saturation задаются вместе")
        if self.hue is not None and self.mireds is not None:
            raise ValueError("нельзя одновременно задавать цвет (hs) и температуру")
        if self.level is not None and not 1 <= self.level <= 254:
            raise ValueError("level вне 1..254")
        if self.hue is not None and not (0 <= self.hue <= 254 and 0 <= self.saturation <= 254):
            raise ValueError("hue/saturation вне 0..254")
        if self.mireds is not None and not 1 <= self.mireds <= 1000:
            raise ValueError("mireds вне 1..1000")
        if not 0 <= self.transition_s <= 6553:
            raise ValueError("transition вне 0..6553 с")

    @property
    def has_attrs(self) -> bool:
        return any(v is not None for v in (self.level, self.hue, self.mireds))


@dataclass
class Command:
    cluster: int
    command: int
    fields: dict
    label: str


@dataclass
class ApplyResult:
    state: Optional[LampState]
    verified: bool
    commands: list[str] = field(default_factory=list)
    attempts: int = 0


def _hue_dist(a: int, b: int) -> int:
    d = abs(a - b) % HUE_MODULUS
    return min(d, HUE_MODULUS - d)


class Lamp:
    def __init__(self, client: MaindClient, node_id: int, endpoint_id: int, *,
                 color_temp: bool = False,
                 capabilities: EndpointCapabilities | None = None,
                 sleep: Callable[[float], None] = time.sleep,
                 monotonic: Callable[[], float] = time.monotonic):
        self.c, self.node, self.ep = client, node_id, endpoint_id
        self.color_temp = color_temp
        self.capabilities = capabilities
        self._sleep, self._now = sleep, monotonic

    # --- чтение ---------------------------------------------------------
    def _opt(self, cluster: int, attr: int):
        try:
            return self.c.read(self.node, self.ep, cluster, attr)
        except UnsupportedAttributeError:
            return None

    def _declared_attr(self, cluster: int, attr: int) -> bool:
        return self.capabilities is None or self.capabilities.supports_attribute(cluster, attr)

    def _require_command(self, cluster: int, command: int, label: str) -> None:
        if (hasattr(self.c, "allowed_invoke")
                and (cluster, command) not in self.c.allowed_invoke):
            from .client import NotAllowed
            raise NotAllowed(f"{label}: command {cluster:#x}/{command} is not enabled")
        if self.capabilities is not None and not self.capabilities.supports_command(cluster, command):
            raise ValueError(f"{label}: command {command} is not declared by the selected endpoint")

    def read_on(self) -> Optional[bool]:
        v = self.c.read(self.node, self.ep, ONOFF, 0)
        if not isinstance(v, bool):
            from .client import MaindProtocolError
            raise MaindProtocolError(f"OnOff: ожидался bool, получено {v!r}")
        return v

    def read_state(self) -> LampState:
        on = self.read_on()
        level = self._opt(LEVEL, 0) if self._declared_attr(LEVEL, 0) else None
        hue = self._opt(COLOR, 0) if self._declared_attr(COLOR, 0) else None
        saturation = self._opt(COLOR, 1) if self._declared_attr(COLOR, 1) else None
        color_mode = self._opt(COLOR, 8) if self._declared_attr(COLOR, 8) else None
        mireds = self._opt(COLOR, 7) if self.color_temp and self._declared_attr(COLOR, 7) else None
        from .client import MaindProtocolError
        for name, value, upper in (("level", level, 254), ("hue", hue, 254),
                                   ("saturation", saturation, 254),
                                   ("color_mode", color_mode, 255), ("mireds", mireds, 65534)):
            if value is not None and (type(value) is not int or not 0 <= value <= upper):
                raise MaindProtocolError(f"{name}: неожиданный TLV-тип/значение {value!r}")
        return LampState(on, level, hue, saturation, color_mode, mireds)

    # --- план -----------------------------------------------------------
    def _check(self, req: Request) -> None:
        req.validate()
        if req.mireds is not None and not self.color_temp:
            raise ValueError("цветовая температура выключена в конфиге ([lamp].color_temp)")
        if req.mireds is not None and self.capabilities is not None:
            if not self.capabilities.color_temperature_supported:
                raise ValueError("color temperature is not fully declared by this endpoint")
            lo, hi = (self.capabilities.color_temp_min_mireds,
                      self.capabilities.color_temp_max_mireds)
            if not lo <= req.mireds <= hi:
                raise ValueError(f"mireds: device range is {lo}..{hi}")
        if req.mireds is not None:
            # Validate the optional command before plan() can prepend an On command.
            self._require_command(COLOR, 10, "color_temp")

    def plan(self, req: Request, current_on: Optional[bool]) -> list[Command]:
        self._check(req)
        if req.on is False:
            self._require_command(ONOFF, 0, "off")
            return [Command(ONOFF, 0, {}, "off")]
        tt = seconds_to_tenths(req.transition_s)
        opts = {"transitionTime": tt, "optionsMask": 0, "optionsOverride": 0}
        cmds: list[Command] = []
        wants_on = req.on is True or req.has_attrs
        # Matter: пока лампа выключена, Level/Color без ExecuteIfOff игнорируются —
        # поэтому On всегда идёт первым.
        if wants_on and current_on is not True:
            self._require_command(ONOFF, 1, "on")
            cmds.append(Command(ONOFF, 1, {}, "on"))
        if req.level is not None:
            self._require_command(LEVEL, 0, "level")
            cmds.append(Command(LEVEL, 0, {"level": req.level, **opts}, "level"))
        if req.hue is not None:
            self._require_command(COLOR, 6, "color")
            cmds.append(Command(COLOR, 6, {"hue": req.hue, "saturation": req.saturation, **opts}, "color"))
        elif req.mireds is not None:
            self._require_command(COLOR, 10, "color_temp")
            cmds.append(Command(COLOR, 10, {"colorTemperatureMireds": req.mireds, **opts}, "color_temp"))
        return cmds

    def _matches(self, req: Request, st: LampState) -> bool:
        if req.on is False:
            return st.on is False
        if (req.on is True or req.has_attrs) and st.on is not True:
            return False
        if req.level is not None and (st.level is None or abs(st.level - req.level) > LEVEL_TOL):
            return False
        if req.hue is not None:
            if st.hue is None or st.saturation is None or st.color_mode not in (None, 0):
                return False
            if _hue_dist(st.hue, req.hue) > HUE_TOL or abs(st.saturation - req.saturation) > SAT_TOL:
                return False
        if req.mireds is not None:
            if st.mireds is None or st.color_mode not in (None, 2):
                return False
            if abs(st.mireds - req.mireds) > MIREDS_TOL:
                return False
        return True

    # --- применение -----------------------------------------------------
    def apply(self, req: Request, *, verify: bool = True, timeout: float = 5.0,
              interval: float = 0.5) -> ApplyResult:
        self._check(req)   # до любых обращений к сети
        cmds = self.plan(req, self.read_on() if req.on is not False else None)
        for c in cmds:
            self.c.invoke(self.node, self.ep, c.cluster, c.command, c.fields)
        labels = [c.label for c in cmds]
        if not verify:
            return ApplyResult(None, False, labels, 0)
        deadline = self._now() + timeout
        attempts, st = 0, None
        while True:
            attempts += 1
            st = self.read_state()
            if self._matches(req, st):
                return ApplyResult(st, True, labels, attempts)
            if self._now() >= deadline:
                return ApplyResult(st, False, labels, attempts)
            self._sleep(interval)
