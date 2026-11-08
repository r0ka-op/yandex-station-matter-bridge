"""Транспорты до maind HTTP API (127.0.0.1:8765 НА Станции).

Принцип: API без аутентификации, поэтому мы никогда не ходим на него по LAN.
  * tunnel   — `ssh -L 127.0.0.1:<порт>:127.0.0.1:8765` (основной режим);
  * ssh-exec — запрос через `wget` на самой Станции (запасной, без кода HTTP);
  * direct   — только loopback-URL (запуск на Станции или тесты).
"""
from __future__ import annotations

import ipaddress
import json
import re
import shlex
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional, Protocol

from .config import Config, ConfigError


class MaindError(Exception):
    """Базовая ошибка работы с maind."""


class MaindUnavailable(MaindError):
    """API недоступен (выключен, таймаут, туннель упал)."""


MAX_BODY = 1_000_000


class Transport(Protocol):
    def request(self, method: str, path: str, body: Optional[bytes]) -> tuple[int, bytes]: ...


def _is_loopback_host(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


class HttpTransport:
    def __init__(self, base_url: str, timeout: float = 5.0):
        parsed = urllib.parse.urlsplit(base_url)
        if parsed.scheme != "http" or not parsed.hostname or not _is_loopback_host(parsed.hostname):
            raise ConfigError(
                f"отказ: API без аутентификации допускается только по loopback, получено {base_url!r}")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        # прокси не используем никогда
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, method: str, path: str, body: Optional[bytes]) -> tuple[int, bytes]:
        req = urllib.request.Request(
            self.base_url + path, data=body, method=method,
            headers={"Content-Type": "application/json"} if body is not None else {})
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                data = resp.read(MAX_BODY + 1)
                if len(data) > MAX_BODY:
                    raise MaindError("maind: HTTP-ответ превышает лимит")
                return resp.status, data
        except urllib.error.HTTPError as exc:
            data = exc.read(MAX_BODY + 1)
            if len(data) > MAX_BODY:
                raise MaindError("maind: HTTP-ответ ошибки превышает лимит")
            return exc.code, data
        except (urllib.error.URLError, ConnectionError, TimeoutError, socket.timeout, OSError) as exc:
            raise MaindUnavailable(f"maind недоступен: {exc}") from exc


def _ssh_base(alias: str, options: list[str]) -> list[str]:
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", *options, alias]


class SshExecTransport:
    """Запрос выполняется wget'ом на Станции. Код HTTP недоступен: rc!=0 => недоступно."""

    def __init__(self, alias: str, port: int, options: list[str], timeout: float = 20.0):
        self.alias, self.port, self.options, self.timeout = alias, port, options, timeout

    def request(self, method: str, path: str, body: Optional[bytes]) -> tuple[int, bytes]:
        cmd = ["/usr/bin/wget", "-Y", "off", "-S", "-T", str(int(self.timeout)), "-O", "-"]
        if body is not None:
            cmd += ["--header=Content-Type: application/json", "--post-data=" + body.decode()]
        elif method != "GET":
            raise MaindError("ssh-exec: неподдерживаемый метод")
        cmd.append(f"http://127.0.0.1:{self.port}{path}")
        wget = " ".join(shlex.quote(c) for c in cmd)
        # BusyBox wget returns non-zero for a valid HTTP 404/500. Keep the SSH
        # transport exit code separate from the HTTP/wget result.
        remote = (f"{wget}; ymatter_wget_rc=$?; "
                  "printf '\\n__YMATTER_WGET_EXIT__=%s\\n' \"$ymatter_wget_rc\" >&2; exit 0")
        try:
            p = subprocess.run(_ssh_base(self.alias, self.options) + [remote],
                               capture_output=True, timeout=self.timeout + 10)
        except (subprocess.TimeoutExpired, OSError) as exc:
            raise MaindUnavailable(f"ssh-exec: {exc}") from exc
        if p.returncode != 0:
            raise MaindUnavailable(
                f"ssh-exec rc={p.returncode}: {p.stderr.decode(errors='replace')[:200]}")
        if len(p.stdout) > MAX_BODY:
            raise MaindError("ssh-exec: HTTP-ответ превышает лимит")
        stderr = p.stderr.decode(errors="replace")
        marker = re.findall(r"__YMATTER_WGET_EXIT__=([0-9]+)", stderr)
        statuses = re.findall(r"HTTP/[0-9.]+\s+([0-9]{3})(?:\s|$)", stderr)
        if not marker:
            raise MaindUnavailable("ssh-exec: wget exit marker is missing")
        wget_rc = int(marker[-1])
        if not statuses:
            safe = stderr.replace("\r", " ").replace("\n", " ")[:200]
            raise MaindUnavailable(f"ssh-exec: no HTTP status (wget rc={wget_rc}): {safe}")
        status = int(statuses[-1])
        if 200 <= status < 300 and wget_rc != 0:
            raise MaindUnavailable(f"ssh-exec: incomplete HTTP {status} response (wget rc={wget_rc})")
        return status, p.stdout


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class SshTunnel:
    def __init__(self, alias: str, remote_port: int, options: list[str]):
        self.alias, self.remote_port, self.options = alias, remote_port, options
        self.local_port: Optional[int] = None
        self._proc: Optional[subprocess.Popen] = None

    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self, wait: float = 10.0) -> None:
        self.stop()
        if self.local_port is None:
            self.local_port = _free_port()
        cmd = ["ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
               "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
               "-o", "ConnectTimeout=8", *self.options,
               "-L", f"127.0.0.1:{self.local_port}:127.0.0.1:{self.remote_port}", self.alias]
        self._proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            if self._proc.poll() is not None:
                err = (self._proc.stderr.read() or b"").decode(errors="replace")[:300]
                raise MaindUnavailable(f"ssh-туннель не поднялся: {err.strip()}")
            try:
                with socket.create_connection(("127.0.0.1", self.local_port), timeout=0.5):
                    return
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise MaindUnavailable("ssh-туннель не поднялся за отведённое время")

    def ensure(self) -> None:
        if not self.alive():
            self.start()

    def stop(self) -> None:
        if self._proc is not None:
            if self._proc.poll() is None:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
            self._proc = None


class SshRunner:
    """Выполняет shell-скрипт на Станции: (rc, stdout, stderr)."""

    def __init__(self, alias: str, options: list[str], timeout: float = 25.0):
        self.alias, self.options, self.timeout = alias, options, timeout

    def run(self, script: str) -> tuple[int, str, str]:
        remote = "sh -c " + shlex.quote(script)
        try:
            p = subprocess.run(_ssh_base(self.alias, self.options) + [remote],
                               capture_output=True, timeout=self.timeout)
        except (subprocess.TimeoutExpired, OSError) as exc:
            return 255, "", str(exc)
        return p.returncode, p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")


class StationSession:
    """Жизненный цикл транспорта: with StationSession(cfg) as s: s.transport."""

    def __init__(self, cfg: Config, timeout: float = 5.0):
        self.cfg, self.timeout = cfg, timeout
        self.tunnel: Optional[SshTunnel] = None
        self.transport: Optional[Transport] = None

    def __enter__(self) -> "StationSession":
        st = self.cfg.station
        if st.transport == "tunnel":
            self.tunnel = SshTunnel(st.ssh_alias, st.api_port, st.ssh_options)
            self.tunnel.start()
            self.transport = HttpTransport(f"http://127.0.0.1:{self.tunnel.local_port}", self.timeout)
        elif st.transport == "ssh-exec":
            self.transport = SshExecTransport(st.ssh_alias, st.api_port, st.ssh_options)
        else:
            self.transport = HttpTransport(st.direct_url, self.timeout)
        return self

    def ensure(self) -> None:
        if self.tunnel is not None:
            self.tunnel.ensure()

    def __exit__(self, *exc) -> None:
        if self.tunnel is not None:
            self.tunnel.stop()


def dumps(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode()
