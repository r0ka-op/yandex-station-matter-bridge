"""Загрузка и строгая валидация config.toml (опечатки в ключах — ошибка)."""
from __future__ import annotations

import dataclasses
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


class ConfigError(ValueError):
    pass


@dataclass
class StationCfg:
    ssh_alias: str = ""
    ip: str = ""            # IPv4 Станции — для проверки, что порт не виден из LAN
    ipv6: str = ""          # то же для IPv6 (необязательно)
    transport: str = "ssh-exec"   # ssh-exec (Mini 2 Dropbear) | tunnel | direct
    api_port: int = 8765
    direct_url: str = ""    # только loopback; для запуска на самой Станции/тестов
    ssh_options: list[str] = field(default_factory=list)


@dataclass
class LampCfg:
    node_id: Optional[int] = None
    endpoint_id: Optional[int] = None
    name: str = "Эмби лампа"
    color_temp: bool = False    # explicit opt-in; command 0x0A is not hardware-tested yet
    min_kelvin: int = 2703      # inventory: 370 mired
    max_kelvin: int = 6493      # inventory: 154 mired


@dataclass
class SafetyCfg:
    require_guard: bool = True
    allow_unknown_firmware: bool = False
    extra_maind_sha256: list[str] = field(default_factory=list)
    extra_launcher_sha256: list[str] = field(default_factory=list)


@dataclass
class MqttCfg:
    host: str = "localhost"
    port: int = 1883
    username: str = ""
    password: str = ""
    tls: bool = False
    base_topic: str = "ymatter"
    discovery_prefix: str = "homeassistant"
    client_id: str = "ymatter-bridge"


@dataclass
class BridgeCfg:
    poll_interval: float = 10.0
    verify_timeout: float = 5.0
    safety_recheck_interval: float = 30.0  # каждые N секунд на poll, перед командой — всегда


@dataclass
class Config:
    station: StationCfg = field(default_factory=StationCfg)
    lamp: LampCfg = field(default_factory=LampCfg)
    safety: SafetyCfg = field(default_factory=SafetyCfg)
    mqtt: MqttCfg = field(default_factory=MqttCfg)
    bridge: BridgeCfg = field(default_factory=BridgeCfg)


def _parse_int(value, where: str) -> int:
    if isinstance(value, bool):
        raise ConfigError(f"{where}: ожидается целое число")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            pass
    raise ConfigError(f"{where}: ожидается целое число (10 или 0x...), получено {value!r}")


def _build(cls, data: dict, section: str):
    names = {f.name for f in dataclasses.fields(cls)}
    unknown = set(data) - names
    if unknown:
        raise ConfigError(f"[{section}]: неизвестные ключи {sorted(unknown)}")
    obj = cls(**data)
    for f in dataclasses.fields(cls):
        v = getattr(obj, f.name)
        if f.name in ("node_id", "endpoint_id") and v is not None:
            setattr(obj, f.name, _parse_int(v, f"[{section}].{f.name}"))
    return obj


def from_dict(data: dict) -> Config:
    unknown = set(data) - {"station", "lamp", "safety", "mqtt", "bridge"}
    if unknown:
        raise ConfigError(f"неизвестные секции {sorted(unknown)}")
    cfg = Config(
        station=_build(StationCfg, data.get("station", {}), "station"),
        lamp=_build(LampCfg, data.get("lamp", {}), "lamp"),
        safety=_build(SafetyCfg, data.get("safety", {}), "safety"),
        mqtt=_build(MqttCfg, data.get("mqtt", {}), "mqtt"),
        bridge=_build(BridgeCfg, data.get("bridge", {}), "bridge"),
    )
    env_pw = os.environ.get("YMATTER_MQTT_PASSWORD")
    if env_pw:
        cfg.mqtt.password = env_pw
    if cfg.station.transport not in ("tunnel", "ssh-exec", "direct"):
        raise ConfigError("[station].transport: tunnel | ssh-exec | direct")
    if cfg.station.transport in ("tunnel", "ssh-exec") and not cfg.station.ssh_alias:
        raise ConfigError("[station].ssh_alias обязателен для tunnel/ssh-exec")
    if cfg.station.transport == "direct" and not cfg.station.direct_url:
        raise ConfigError("[station].direct_url обязателен для direct")
    if not 1 <= cfg.station.api_port <= 65535:
        raise ConfigError("[station].api_port вне диапазона")
    if not isinstance(cfg.bridge.poll_interval, (int, float)) or cfg.bridge.poll_interval < 2:
        raise ConfigError("[bridge].poll_interval должен быть >= 2 секунд")
    if (not isinstance(cfg.bridge.safety_recheck_interval, (int, float)) or
            not 5 <= cfg.bridge.safety_recheck_interval <= 3600):
        raise ConfigError("[bridge].safety_recheck_interval должен быть 5..3600 секунд")
    if not isinstance(cfg.bridge.verify_timeout, (int, float)) or cfg.bridge.verify_timeout <= 0:
        raise ConfigError("[bridge].verify_timeout должен быть > 0")
    if cfg.lamp.min_kelvin >= cfg.lamp.max_kelvin:
        raise ConfigError("[lamp]: min_kelvin должен быть < max_kelvin")
    return cfg


def load_config(path: str | Path) -> Config:
    p = Path(path)
    try:
        with p.open("rb") as fh:
            return from_dict(tomllib.load(fh))
    except FileNotFoundError as exc:
        raise ConfigError(f"конфиг не найден: {p}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"ошибка TOML в {p}: {exc}") from exc
