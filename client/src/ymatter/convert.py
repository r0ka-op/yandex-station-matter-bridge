"""Преобразования между единицами Home Assistant и Matter."""
from __future__ import annotations

MATTER_MAX = 254


def clamp(v: float, lo: float, hi: float):
    return max(lo, min(hi, v))


def hue_ha_to_matter(h: float) -> int:
    return int(clamp(round((h % 360) * MATTER_MAX / 360), 0, MATTER_MAX))


def sat_ha_to_matter(s: float) -> int:
    return int(clamp(round(s * MATTER_MAX / 100), 0, MATTER_MAX))


def hue_matter_to_ha(m: int) -> int:
    return int(clamp(round(m * 360 / MATTER_MAX), 0, 360))


def sat_matter_to_ha(m: int) -> int:
    return int(clamp(round(m * 100 / MATTER_MAX), 0, 100))


def level_clamp(level: float) -> int:
    """Яркость Matter 1..254 (0 зарезервирован под «выкл» через OnOff)."""
    return int(clamp(round(level), 1, MATTER_MAX))


def percent_to_level(p: float) -> int:
    """0% — сигнал выключения; уровень 0 нельзя отправлять в MoveToLevel."""
    if not 0 <= p <= 100:
        raise ValueError("яркость должна быть в диапазоне 0..100%")
    return 0 if p == 0 else level_clamp(p * MATTER_MAX / 100)


def level_to_percent(level: int) -> int:
    return int(clamp(round(level * 100 / MATTER_MAX), 0, 100))


def kelvin_to_mireds(k: float) -> int:
    if k <= 0:
        raise ValueError("kelvin должен быть > 0")
    return int(round(1_000_000 / k))


def mireds_to_kelvin(m: int) -> int:
    if m <= 0:
        raise ValueError("mireds должен быть > 0")
    return int(round(1_000_000 / m))


def seconds_to_tenths(s: float) -> int:
    """TransitionTime в Matter — десятые доли секунды (uint16)."""
    return int(clamp(round(s * 10), 0, 65534))
