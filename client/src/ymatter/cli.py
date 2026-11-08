"""CLI: ymatter doctor|devices|state|on|off|brightness|color|temp|discover|bridge."""
from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys

from .bridge import MqttRunner, Topics
from .capabilities import EndpointCapabilities, discover_endpoint_capabilities
from .client import MaindClient, MaindError, MaindMatterError
from .config import Config, ConfigError, load_config
from .convert import kelvin_to_mireds, percent_to_level, hue_ha_to_matter, sat_ha_to_matter
from .lamp import Lamp, Request
from .preflight import format_checks, passed, run_preflight
from .transport import SshRunner, StationSession


def _configure_console_encoding() -> None:
    """Keep localized CLI output usable when Windows redirects a legacy code page."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="backslashreplace")
        except (AttributeError, OSError, ValueError):
            # Test doubles and already-detached streams may not be reconfigurable.
            continue


def _preflight(cfg: Config) -> list:
    if not cfg.station.ssh_alias:
        raise SystemExit("preflight невозможен без [station].ssh_alias; "
                         "для direct/тестов используйте --skip-preflight")
    runner = SshRunner(cfg.station.ssh_alias, cfg.station.ssh_options)
    return run_preflight(cfg, runner.run)


def _require_safe(cfg: Config, skip: bool) -> None:
    if skip:
        if cfg.station.transport != "direct":
            raise SystemExit("--skip-preflight разрешён только для direct на локальном loopback (тесты)")
        print("ВНИМАНИЕ: preflight пропущен (только локальный direct)", file=sys.stderr)
        return
    checks = _preflight(cfg)
    if not passed(checks):
        print(format_checks(checks), file=sys.stderr)
        raise SystemExit("preflight не пройден — работа остановлена (fail-closed)")


def _pick_target(cfg: Config, client: MaindClient) -> tuple[int, int, EndpointCapabilities]:
    devs = client.devices()
    cands = [(d.node_id, e) for d in devs for e in d.endpoints if e != 0
             and (cfg.lamp.node_id in (None, d.node_id))
             and (cfg.lamp.endpoint_id in (None, e))]
    discovered = []
    for node, ep in cands:
        caps = discover_endpoint_capabilities(client, node, ep)
        if caps.is_light and 6 in caps.server_clusters:
            discovered.append((node, ep, caps))
    if len(discovered) != 1:
        raise SystemExit(f"не удалось однозначно выбрать лампу, кандидаты: {cands}; "
                         "задайте [lamp].node_id и endpoint_id")
    return discovered[0]


def _apply_device_temperature_range(cfg: Config, caps: EndpointCapabilities) -> None:
    if not cfg.lamp.color_temp:
        return
    if not caps.color_temperature_supported:
        raise SystemExit("color_temp enabled, but endpoint does not declare command 0x0A and bounds")
    physical_min_k = math.ceil(1_000_000 / caps.color_temp_max_mireds)
    physical_max_k = math.floor(1_000_000 / caps.color_temp_min_mireds)
    cfg.lamp.min_kelvin = max(cfg.lamp.min_kelvin, physical_min_k)
    cfg.lamp.max_kelvin = min(cfg.lamp.max_kelvin, physical_max_k)
    if cfg.lamp.min_kelvin > cfg.lamp.max_kelvin:
        raise SystemExit("configured color temperature range does not intersect device bounds")


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ymatter", description=__doc__)
    p.add_argument("-c", "--config", default=os.environ.get("YMATTER_CONFIG", "config.toml"))
    p.add_argument("--skip-preflight", action="store_true",
                   help="НЕ рекомендуется: пропустить проверки безопасности")
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor", help="проверки безопасности и связности")
    sub.add_parser("devices", help="GET /devices")
    sub.add_parser("state", help="прочитать состояние лампы")
    sub.add_parser("discover", help="read-only: кластеры и возможности лампы")
    sub.add_parser("on")
    sub.add_parser("off")
    b = sub.add_parser("brightness"); b.add_argument("percent", type=float)
    c = sub.add_parser("color"); c.add_argument("hue", type=float, help="0..360")
    c.add_argument("saturation", type=float, help="0..100")
    t = sub.add_parser("temp", help="экспериментально"); t.add_argument("kelvin", type=float)
    for x in (b, c, t):
        x.add_argument("--transition", type=float, default=0.0, help="секунды")
    sub.add_parser("bridge", help="MQTT-мост для Home Assistant")
    return p


def main(argv: list[str] | None = None) -> int:
    _configure_console_encoding()
    args = _build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(f"ошибка конфига: {exc}", file=sys.stderr)
        return 2

    if args.cmd == "doctor":
        checks = _preflight(cfg)
        print(format_checks(checks))
        return 0 if passed(checks) else 1

    _require_safe(cfg, args.skip_preflight)
    try:
        with StationSession(cfg) as session:
            client = MaindClient(session.transport,
                                 allow_color_temperature=cfg.lamp.color_temp)
            if args.cmd == "devices":
                print(json.dumps([{"nodeId": d.node_id, "endpoints": list(d.endpoints)}
                                  for d in client.devices()], indent=2))
                return 0
            node, ep, caps = _pick_target(cfg, client)
            _apply_device_temperature_range(cfg, caps)
            lamp = Lamp(client, node, ep, color_temp=cfg.lamp.color_temp,
                        capabilities=caps)
            if args.cmd == "state":
                print(json.dumps(lamp.read_state().__dict__, indent=2))
            elif args.cmd == "discover":
                return _discover(client, node, ep, caps)
            elif args.cmd == "bridge":
                MqttRunner(cfg, session, lamp, Topics(cfg, node, ep)).run()
            else:
                req = _request_from_args(args, cfg)
                res = lamp.apply(req, timeout=cfg.bridge.verify_timeout)
                print(json.dumps({"verified": res.verified, "commands": res.commands,
                                  "state": res.state.__dict__ if res.state else None}, indent=2))
                return 0 if res.verified else 3
    except ValueError as exc:      # некорректные аргументы/запрос
        print(f"некорректный запрос: {exc}", file=sys.stderr)
        return 2
    except MaindError as exc:
        print(f"ошибка: {exc}", file=sys.stderr)
        return 1
    return 0


def _request_from_args(a, cfg: Config | None = None) -> Request:
    if a.cmd == "on":
        return Request(on=True)
    if a.cmd == "off":
        return Request(on=False)
    if a.cmd == "brightness":
        if not math.isfinite(a.percent) or not 0 <= a.percent <= 100:
            raise ValueError("brightness: ожидается 0..100%")
        if a.percent == 0:
            return Request(on=False)
        return Request(level=percent_to_level(a.percent), transition_s=a.transition)
    if a.cmd == "color":
        if not math.isfinite(a.hue) or not 0 <= a.hue <= 360:
            raise ValueError("color: hue вне диапазона 0..360")
        if not math.isfinite(a.saturation) or not 0 <= a.saturation <= 100:
            raise ValueError("color: saturation вне диапазона 0..100")
        return Request(hue=hue_ha_to_matter(a.hue), saturation=sat_ha_to_matter(a.saturation),
                       transition_s=a.transition)
    if a.cmd == "temp":
        if not math.isfinite(a.kelvin):
            raise ValueError("temp: нужна конечная температура в K")
        if cfg is not None and not cfg.lamp.min_kelvin <= a.kelvin <= cfg.lamp.max_kelvin:
            raise ValueError(f"temp: диапазон {cfg.lamp.min_kelvin}..{cfg.lamp.max_kelvin} K")
        return Request(mireds=kelvin_to_mireds(a.kelvin), transition_s=a.transition)
    raise SystemExit(f"неизвестная команда {a.cmd}")


def _discover(client: MaindClient, node: int, ep: int,
              caps: EndpointCapabilities | None = None) -> int:
    if caps is None:
        caps = discover_endpoint_capabilities(client, node, ep)
    probes = {
        "descriptor.ServerList": (29, 1),
        "level.AcceptedCommandList": (8, 0xFFF9),
        "level.FeatureMap": (8, 0xFFFC),
        "color.AcceptedCommandList": (768, 0xFFF9),
        "color.FeatureMap": (768, 0xFFFC),
        "color.ColorCapabilities": (768, 0x400A),
        "color.ColorTempPhysicalMinMireds": (768, 0x400B),
        "color.ColorTempPhysicalMaxMireds": (768, 0x400C),
    }
    out = {
        "nodeId": node,
        "endpointId": ep,
        "deviceTypes": list(caps.device_types),
        "serverClusters": sorted(caps.server_clusters),
        "acceptedCommands": {str(k): sorted(v) for k, v in caps.accepted_commands.items()},
        "attributeLists": {str(k): sorted(v) for k, v in caps.attributes.items()},
        "colorTemperatureMireds": [caps.color_temp_min_mireds,
                                    caps.color_temp_max_mireds],
    }
    for name, (cl, at) in probes.items():
        try:
            out[name] = client.read(node, ep, cl, at)
        except MaindMatterError as exc:
            out[name] = f"ошибка Matter: {exc.errors}"
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
