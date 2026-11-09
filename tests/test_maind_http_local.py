#!/usr/bin/env python3
"""Real-TCP regression tests for maind-http-local.

The harness binds only 127.0.0.1:8765 and never emulates Matter semantics.
It validates HTTP transport behavior without persisting response bodies.
"""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import threading
import time
from dataclasses import dataclass


HOST = "127.0.0.1"
PORT = 8765


@dataclass
class ServerCase:
    response_parts: list[bytes]
    read_chunk: int = 65536
    read_delay: float = 0.0
    response_delay: float = 0.0
    close_without_response: bool = False
    accept_and_close: bool = False


class OneShotServer:
    def __init__(self, case: ServerCase):
        self.case = case
        self.request = b""
        self.error: BaseException | None = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> "OneShotServer":
        self.thread.start()
        if not self.ready.wait(3):
            raise RuntimeError("server did not bind")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.thread.join(5)
        if self.thread.is_alive():
            raise RuntimeError("server thread did not terminate")
        if self.error is not None:
            raise self.error

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind((HOST, PORT))
                listener.listen(1)
                self.ready.set()
                connection, _ = listener.accept()
                with connection:
                    if self.case.accept_and_close:
                        return
                    connection.settimeout(5)
                    header_end = -1
                    content_length = 0
                    while True:
                        chunk = connection.recv(self.case.read_chunk)
                        if not chunk:
                            break
                        self.request += chunk
                        if self.case.read_delay:
                            time.sleep(self.case.read_delay)
                        if header_end < 0:
                            header_end = self.request.find(b"\r\n\r\n")
                            if header_end >= 0:
                                headers = self.request[:header_end].decode("ascii")
                                for line in headers.split("\r\n")[1:]:
                                    name, value = line.split(":", 1)
                                    if name.lower() == "content-length":
                                        content_length = int(value.strip())
                        if header_end >= 0 and len(self.request) >= header_end + 4 + content_length:
                            break
                    if self.case.close_without_response:
                        return
                    if self.case.response_delay:
                        time.sleep(self.case.response_delay)
                    for part in self.case.response_parts:
                        connection.sendall(part)
                        if len(self.case.response_parts) > 1:
                            time.sleep(0.01)
        except BaseException as exc:  # propagated by __exit__
            self.error = exc
            self.ready.set()


def response(status: int, body: bytes, *, content_length: int | None = None) -> bytes:
    length = len(body) if content_length is None else content_length
    reason = {200: "OK", 400: "Bad Request", 500: "Internal Server Error"}[status]
    return (
        f"HTTP/1.1 {status} {reason}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {length}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii") + body


def run_client(binary: str, method: str, path: str, body: bytes = b"",
               timeout_ms: int = 2000, max_response: int = 1048576) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [binary, "--method", method, "--path", path,
         "--timeout-ms", str(timeout_ms), "--max-response", str(max_response)],
        input=body,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=max(5, timeout_ms / 1000 + 3),
        check=False,
    )


def expect_success(binary: str, method: str, path: str, body: bytes, reply: bytes,
                   case: ServerCase | None = None,
                   timeout_ms: int = 2000) -> tuple[subprocess.CompletedProcess[bytes], bytes]:
    with OneShotServer(case or ServerCase([reply])) as server:
        result = run_client(binary, method, path, body, timeout_ms=timeout_ms)
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert result.stdout == reply
    assert b"127.0.0.1:8765" in server.request
    assert server.request.endswith(body)
    return result, server.request


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    args = parser.parse_args()
    binary = args.binary

    ok = response(200, b'{"ok":true}')
    _, get_request = expect_success(binary, "GET", "/devices", b"", ok)
    assert get_request.startswith(b"GET /devices HTTP/1.1\r\n")

    # Synthetic transport test value; never embed a lab device identifier.
    post_body = b'{"nodeId":4660}'
    pieces = [ok[:7], ok[7:31], ok[31:]]
    _, post_request = expect_success(
        binary, "POST", "/interaction/readAttribute", post_body, ok,
        ServerCase(pieces),
    )
    assert post_request.startswith(b"POST /interaction/readAttribute HTTP/1.1\r\n")
    assert f"Content-Length: {len(post_body)}\r\n".encode() in post_request

    for status in (400, 500):
        reply = response(status, b'{"error":true}')
        expect_success(binary, "POST", "/interaction/readAttribute", post_body, reply)

    with OneShotServer(ServerCase([], close_without_response=True)):
        empty = run_client(binary, "POST", "/interaction/readAttribute", post_body)
    assert empty.returncode == 69 and empty.stdout == b""

    incomplete = response(200, b"{}", content_length=10)
    with OneShotServer(ServerCase([incomplete])):
        eof = run_client(binary, "GET", "/devices")
    assert eof.returncode == 69 and eof.stdout == b""

    malformed_reply = b"NOTHTTP\r\nContent-Length: 2\r\n\r\n{}"
    with OneShotServer(ServerCase([malformed_reply])):
        malformed = run_client(binary, "GET", "/devices")
    assert malformed.returncode == 69 and malformed.stdout == b""

    large_request_body = json.dumps({"blob": "x" * 700000}).encode()
    partial_reply = response(200, b'{"received":true}')
    expect_success(
        binary, "POST", "/interaction/readAttribute", large_request_body,
        partial_reply, ServerCase([partial_reply], read_chunk=127, read_delay=0.0001),
        timeout_ms=12000,
    )

    with OneShotServer(ServerCase([ok], response_delay=0.5)):
        timed_out = run_client(binary, "GET", "/devices", timeout_ms=150)
    assert timed_out.returncode == 71 and timed_out.stdout == b""

    large_reply = response(200, b"x" * 4096)
    with OneShotServer(ServerCase([large_reply])):
        oversized = run_client(binary, "GET", "/devices", max_response=1024)
    assert oversized.returncode == 70 and oversized.stdout == b""

    with OneShotServer(ServerCase([], accept_and_close=True)):
        closed = run_client(
            binary, "POST", "/interaction/readAttribute", large_request_body,
            timeout_ms=2000,
        )
    assert closed.returncode in (67, 68, 69) and closed.stdout == b""

    forbidden = run_client(binary, "POST", "/interaction/invokeCommand", b"{}")
    assert forbidden.returncode == 64 and forbidden.stdout == b""

    print("MAIND_HTTP_LOCAL_TCP_TESTS=PASS cases=11")


if __name__ == "__main__":
    main()
