"""MQTT-мост для Home Assistant (MQTT light, schema: json) + MQTT discovery.

Логика (BridgeCore) отделена от MQTT-клиента (MqttRunner), чтобы тестироваться
без брокера. Состояние берётся из readback, а не из «оптимистичных» значений.
"""
from __future__ import annotations

import json
import math
import time
import logging
import queue
import signal
import threading
from typing import Callable, Optional

from . import __version__
from .client import MaindError, MaindUnavailable
from .config import Config
from .convert import (hue_ha_to_matter, hue_matter_to_ha, kelvin_to_mireds, level_clamp,
                      mireds_to_kelvin, sat_ha_to_matter, sat_matter_to_ha)
from .lamp import Lamp, LampState, Request
from .preflight import format_checks, passed, run_preflight
from .transport import SshRunner, StationSession

log = logging.getLogger("ymatter.bridge")
Publish = Callable[[str, str, bool], None]  # topic, payload, retain


def _num(v, name: str) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ValueError(f"{name}: ожидается число")
    result = float(v)
    if not math.isfinite(result):
        raise ValueError(f"{name}: ожидалось конечное число")
    return result


def parse_command(payload: bytes | str, *, color_temp: bool = False,
                  min_kelvin: int = 2700, max_kelvin: int = 6500) -> Request:
    """JSON-команда Home Assistant -> Request (строго, с проверкой типов)."""
    if len(payload) > 4096:
        raise ValueError("MQTT-команда превышает лимит 4096 байт")
    try:
        data = json.loads(payload)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError(f"невалидный JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("ожидался JSON-объект")
    req = Request()
    st = data.get("state")
    if st is not None:
        if not isinstance(st, str) or st.upper() not in ("ON", "OFF"):
            raise ValueError("state: ON или OFF")
        req.on = st.upper() == "ON"
    if "brightness" in data:
        brightness = _num(data["brightness"], "brightness")
        if not 0 <= brightness <= 254:
            raise ValueError("brightness: ожидается 0..254")
        if brightness == 0:
            # MQTT Light: нулевая яркость — выключение, а не включение на минимуме.
            return Request(on=False)
        req.level = level_clamp(brightness)
    if "color" in data:
        c = data["color"]
        if not isinstance(c, dict) or not {"h", "s"} <= set(c):
            raise ValueError("color: нужен объект {h, s}")
        hue = _num(c["h"], "color.h")
        saturation = _num(c["s"], "color.s")
        if not 0 <= hue <= 360 or not 0 <= saturation <= 100:
            raise ValueError("color: h должен быть 0..360, s — 0..100")
        req.hue = hue_ha_to_matter(hue)
        req.saturation = sat_ha_to_matter(saturation)
    if "color_temp" in data:
        if not color_temp:
            raise ValueError("color_temp не включён в конфиге")
        k = _num(data["color_temp"], "color_temp")
        if not min_kelvin <= k <= max_kelvin:
            raise ValueError(f"color_temp: ожидается {min_kelvin}..{max_kelvin} K")
        req.mireds = kelvin_to_mireds(k)
    if "transition" in data:
        req.transition_s = _num(data["transition"], "transition")
    if req.on is None and not req.has_attrs:
        raise ValueError("пустая MQTT-команда")
    req.validate()
    return req


def state_payload(st: LampState, *, color_temp: bool = False) -> dict:
    out: dict = {"state": "ON" if st.on else "OFF"}
    if st.on:
        if st.level is not None:
            out["brightness"] = st.level
        if color_temp and st.color_mode == 2 and st.mireds:
            out["color_mode"] = "color_temp"
            out["color_temp"] = mireds_to_kelvin(st.mireds)
        elif st.hue is not None and st.saturation is not None:
            out["color_mode"] = "hs"
            out["color"] = {"h": hue_matter_to_ha(st.hue), "s": sat_matter_to_ha(st.saturation)}
    return out


class Topics:
    def __init__(self, cfg: Config, node_id: int, endpoint_id: int):
        self.uid = f"{node_id:x}_{endpoint_id}"
        base = f"{cfg.mqtt.base_topic}/{self.uid}"
        self.state, self.set, self.avail = f"{base}/state", f"{base}/set", f"{base}/availability"
        self.discovery = f"{cfg.mqtt.discovery_prefix}/light/ymatter_{self.uid}/config"


def discovery_payload(cfg: Config, topics: Topics) -> dict:
    modes = ["hs"] + (["color_temp"] if cfg.lamp.color_temp else [])
    p = {
        "name": None,
        "unique_id": f"ymatter_{topics.uid}",
        "schema": "json",
        "command_topic": topics.set,
        "state_topic": topics.state,
        "availability_topic": topics.avail,
        "payload_available": "online",
        "payload_not_available": "offline",
        "brightness": True,
        "brightness_scale": 254,
        "supported_color_modes": modes,
        "device": {"identifiers": [f"ymatter_{topics.uid}"], "name": cfg.lamp.name,
                   "manufacturer": "Yandex", "model": "YNDX-00560"},
        "origin": {"name": "ymatter-bridge", "sw_version": __version__},
    }
    if cfg.lamp.color_temp:
        p.update({"color_temp_kelvin": True, "min_kelvin": cfg.lamp.min_kelvin,
                  "max_kelvin": cfg.lamp.max_kelvin})
    return p


class SafetyGate:
    """Срок жизни read-only preflight и обязательная проверка перед командой.

    ВНИМАНИЕ: проверки с интервалом не исключают изменения firewall
    между двумя пробами — это не замена безопасному lifecycle Станции.
    """

    def __init__(self, check: Callable[[], list], interval: float = 30.0,
                 clock: Callable[[], float] = time.monotonic):
        self._check, self._clock, self.interval = check, clock, interval
        self._next = float("-inf")
        self._ok = False

    def allow(self, *, force: bool = False) -> bool:
        now = self._clock()
        if not force and now < self._next:
            return self._ok
        self._next = now + self.interval
        try:
            checks = self._check()
            self._ok = passed(checks)
            if not self._ok:
                log.error("проверки безопасности: отказ\n%s", format_checks(checks))
        except Exception as exc:
            self._ok = False
            log.error("не удалось проверить безопасность: %s", exc)
        return self._ok


class BridgeCore:
    def __init__(self, lamp: Lamp, cfg: Config, topics: Topics, publish: Publish,
                 safety: Optional[SafetyGate] = None):
        self.lamp, self.cfg, self.topics, self.publish = lamp, cfg, topics, publish
        self.safety = safety
        self.available: Optional[bool] = None
        self._last_state: Optional[str] = None

    def announce(self) -> None:
        self.publish(self.topics.discovery,
                     json.dumps(discovery_payload(self.cfg, self.topics), ensure_ascii=False), True)

    def _set_available(self, ok: bool) -> None:
        if self.available is not ok:
            self.available = ok
            self.publish(self.topics.avail, "online" if ok else "offline", True)
            log.info("лампа: %s", "доступна" if ok else "недоступна")

    def _publish_state(self, st: LampState) -> None:
        payload = json.dumps(state_payload(st, color_temp=self.cfg.lamp.color_temp), sort_keys=True)
        if payload != self._last_state:
            self._last_state = payload
            self.publish(self.topics.state, payload, True)

    def poll(self) -> bool:
        if self.safety is not None and not self.safety.allow():
            self._set_available(False)
            return False
        try:
            st = self.lamp.read_state()
        except MaindUnavailable as exc:
            log.warning("API недоступен: %s", exc)
            self._set_available(False)
            return False
        except MaindError as exc:
            log.error("ошибка чтения: %s", exc)
            self._set_available(False)
            return False
        self._set_available(True)
        self._publish_state(st)
        return True

    def handle_command(self, payload: bytes | str) -> None:
        lc = self.cfg.lamp
        try:
            req = parse_command(payload, color_temp=lc.color_temp,
                                min_kelvin=lc.min_kelvin, max_kelvin=lc.max_kelvin)
        except ValueError as exc:
            log.warning("команда отклонена: %s", exc)
            return
        # НЕ используем кеш preflight для команд: перед каждой командой
        # проверяется реальное состояние защитных условий.
        if self.safety is not None and not self.safety.allow(force=True):
            log.error("команда заблокирована: preflight не пройден")
            self._set_available(False)
            return
        try:
            res = self.lamp.apply(req, verify=True, timeout=self.cfg.bridge.verify_timeout)
        except MaindError as exc:
            log.error("команда не выполнена: %s", exc)
            self._set_available(False if isinstance(exc, MaindUnavailable) else bool(self.available))
            return
        if res.state is not None:
            self._publish_state(res.state)
        if not res.verified:
            log.warning("readback не подтвердил состояние (команды: %s)", res.commands)


class MqttRunner:
    """Тонкая обёртка над paho-mqtt (>=2.0)."""

    def __init__(self, cfg: Config, session: StationSession, lamp: Lamp, topics: Topics):
        try:
            import paho.mqtt.client as mqtt
        except ImportError as exc:  # pragma: no cover
            raise SystemExit("нужен paho-mqtt: pip install 'ymatter-bridge[mqtt]'") from exc
        self.cfg, self.session, self.topics = cfg, session, topics
        self._cmds: "queue.Queue[bytes]" = queue.Queue(maxsize=32)
        self._stop = threading.Event()
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cfg.mqtt.client_id)
        if cfg.mqtt.username:
            self.client.username_pw_set(cfg.mqtt.username, cfg.mqtt.password or None)
        if cfg.mqtt.tls:
            self.client.tls_set()
        self.client.will_set(topics.avail, "offline", retain=True)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        runner = SshRunner(cfg.station.ssh_alias, cfg.station.ssh_options)
        safety = SafetyGate(lambda: run_preflight(cfg, runner.run),
                            interval=cfg.bridge.safety_recheck_interval)
        self.core = BridgeCore(lamp, cfg, topics, self._publish, safety=safety)
        self.client.on_disconnect = self._on_disconnect

    def _publish(self, topic: str, payload: str, retain: bool) -> None:
        self.client.publish(topic, payload, qos=1, retain=retain)

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        if getattr(reason_code, "is_failure", False):
            log.error("MQTT: отказ подключения: %s", reason_code)
            return
        client.subscribe(self.topics.set, qos=1)
        self.core.announce()
        self.core.available = None   # переопубликовать availability после реконнекта
        self.core._last_state = None
        self._publish(self.topics.avail, "offline", True)

    def _on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties=None):
        # LWT должен сообщить offline при нештатном разрыве; не оставляем
        # накопившиеся команды для исполнения после реконнекта.
        self.core.available = False
        while True:
            try:
                self._cmds.get_nowait()
            except queue.Empty:
                break

    def _on_message(self, client, userdata, msg):
        if getattr(msg, "retain", False):
            log.warning("пропущена retained MQTT-команда")
            return
        try:
            self._cmds.put_nowait(bytes(msg.payload))
        except queue.Full:
            log.warning("очередь команд переполнена, команда отброшена")

    def stop(self, *_):
        self._stop.set()

    def run(self) -> None:
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)
        self.client.connect_async(self.cfg.mqtt.host, self.cfg.mqtt.port, keepalive=30)
        self.client.loop_start()
        interval = self.cfg.bridge.poll_interval
        fails = 0
        next_poll = time.monotonic()
        try:
            while not self._stop.is_set():
                now = time.monotonic()
                if now >= next_poll:
                    try:
                        self.session.ensure()
                        ok = self.core.poll()
                    except MaindUnavailable as exc:
                        log.warning("туннель: %s", exc)
                        self.core._set_available(False)
                        ok = False
                    fails = 0 if ok else fails + 1
                    next_poll = time.monotonic() + min(interval * (2 ** min(fails, 3)), 60)
                try:
                    cmd = self._cmds.get(timeout=min(max(0, next_poll - time.monotonic()), 1))
                except queue.Empty:
                    continue
                try:
                    self.session.ensure()
                except MaindUnavailable as exc:
                    log.warning("туннель: %s", exc)
                    self.core._set_available(False)
                    continue
                self.core.handle_command(cmd)
        finally:
            try:
                self.client.publish(self.topics.avail, "offline", qos=1, retain=True).wait_for_publish(3)
            except Exception as exc:
                log.warning("не удалось подтвердить MQTT offline при завершении: %s", exc)
            finally:
                self.client.loop_stop()
                self.client.disconnect()
