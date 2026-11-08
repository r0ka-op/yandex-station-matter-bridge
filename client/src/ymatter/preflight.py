"""Проверки безопасности перед работой с API (fail-closed).

Один SSH-вызов собирает факты со Станции, затем проверяется:
  1. SSH доступен;
  2. loopback-guard для TCP/<port> стоит и в IPv4, и в IPv6;
  3. SHA-256 maind и quasar_launcher2 известны (после OTA поведение API
     может измениться);
  4. порт НЕ доступен с этого хоста по LAN (прямая проба);
  5. (информационно) listener API сейчас есть.
"""
from __future__ import annotations

import socket
from dataclasses import dataclass
from typing import Callable

from .config import Config

KNOWN_MAIND = {"7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1"}
KNOWN_LAUNCHER = {"e7af45d49ea9626c7bfc1d72c648663c82e024a8c9d538b0aa6f8317288f5054"}
MAIND_PATH = "/system/vendor/quasar/maind"
LAUNCHER_PATH = "/system/vendor/quasar/quasar_launcher2"


def guard_rule(port: int) -> str:
    return f"INPUT ! -i lo -p tcp --dport {port} -j REJECT --reject-with tcp-reset"


def remote_script(port: int) -> str:
    rule = guard_rule(port)
    hexport = f"{port:04X}"
    return (
        'echo "ssh=ok"\n'
        f'echo "guard4=$(iptables -C {rule} >/dev/null 2>&1; echo $?)"\n'
        f'echo "guard6=$(ip6tables -C {rule} >/dev/null 2>&1; echo $?)"\n'
        f'echo "listener=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null '
        f"| grep -ciE ':{hexport} [0-9A-F:]+ 0A')\"\n"
        f"sha256sum {MAIND_PATH} {LAUNCHER_PATH} 2>/dev/null | sed 's/^/sha /'\n"
    )


@dataclass
class Check:
    name: str
    ok: bool
    detail: str
    warn_only: bool = False


def tcp_probe(host: str, port: int, timeout: float = 2.0) -> str:
    """'open' | 'closed' | 'filtered' | 'error'."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return "open"
    except ConnectionRefusedError:
        return "closed"
    except (socket.timeout, TimeoutError):
        return "filtered"
    except OSError:
        return "error"


def _parse(out: str) -> tuple[dict[str, str], dict[str, str]]:
    kv, sha = {}, {}
    for line in out.splitlines():
        if line.startswith("sha "):
            parts = line.split()
            if len(parts) >= 3:
                sha[parts[2]] = parts[1].lower()
        elif "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv, sha


def run_preflight(cfg: Config, run: Callable[[str], tuple[int, str, str]],
                  probe: Callable[[str, int], str] = tcp_probe) -> list[Check]:
    port = cfg.station.api_port
    checks: list[Check] = []
    rc, out, err = run(remote_script(port))
    kv, sha = _parse(out)
    if rc != 0 or kv.get("ssh") != "ok":
        checks.append(Check("ssh", False, f"Станция недоступна по SSH (rc={rc}): {err.strip()[:150]}"))
        return checks
    checks.append(Check("ssh", True, "доступна"))

    for fam, key in (("IPv4", "guard4"), ("IPv6", "guard6")):
        present = kv.get(key) == "0"
        checks.append(Check(f"guard {fam}", present,
                            "loopback-guard установлен" if present else
                            f"guard отсутствует (rc={kv.get(key, '?')}) — запустите station/guard.sh install"))

    sf = cfg.safety
    for label, path, known, extra in (
        ("maind", MAIND_PATH, KNOWN_MAIND, sf.extra_maind_sha256),
        ("quasar_launcher2", LAUNCHER_PATH, KNOWN_LAUNCHER, sf.extra_launcher_sha256),
    ):
        h = sha.get(path)
        allowed = known | {x.lower() for x in extra}
        if h is None:
            checks.append(Check(f"sha256 {label}", False, "хеш не получен", sf.allow_unknown_firmware))
        elif h in allowed:
            checks.append(Check(f"sha256 {label}", True, "известная сборка"))
        else:
            checks.append(Check(f"sha256 {label}", False,
                                f"неизвестная сборка {h[:12]}… (после OTA нужна перепроверка)",
                                sf.allow_unknown_firmware))

    n = kv.get("listener", "0")
    has = n.isdigit() and int(n) > 0
    checks.append(Check("listener", has,
                        "API слушает" if has else "API сейчас выключен (watchdog мог сработать)",
                        warn_only=True))

    for label, host in (("IPv4", cfg.station.ip), ("IPv6", cfg.station.ipv6)):
        if not host:
            checks.append(Check(f"LAN-проба {label}", False,
                                "адрес Станции не задан — внешняя доступность не проверена",
                                warn_only=(label == "IPv6" or not cfg.safety.require_guard)))
            continue
        try:
            state = probe(host, port)
        except Exception as exc:
            state = f"error:{type(exc).__name__}"
        if state == "open":
            checks.append(Check(f"LAN-проба {label}", False,
                                f"ПОРТ {port} ОТКРЫТ ИЗ LAN — API без аутентификации доступен с этого хоста"))
        elif state in ("closed", "filtered"):
            checks.append(Check(f"LAN-проба {label}", True, f"недоступен с этого хоста ({state})"))
        else:
            checks.append(Check(f"LAN-проба {label}", False,
                                f"проверка не удалась ({state!r}); безопасность не подтверждена"))
    return checks


def passed(checks: list[Check]) -> bool:
    return all(c.ok or c.warn_only for c in checks)


def format_checks(checks: list[Check]) -> str:
    lines = []
    for c in checks:
        mark = "OK  " if c.ok else ("WARN" if c.warn_only else "FAIL")
        lines.append(f"[{mark}] {c.name}: {c.detail}")
    return "\n".join(lines)
