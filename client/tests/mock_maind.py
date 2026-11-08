"""Мок maind HTTP API с состоянием лампы (для тестов, без Станции).

Моделирует поведение Matter:
  * Level/Color-команды игнорируются, пока лампа выключена (ExecuteIfOff=0);
  * `stale_reads` — первые N чтений после команды возвращают старое состояние
    (как «поздний GET подтвердил переключение» в issue AlexxIT/YandexStation#851).
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ymatter import tlv


def _array_uint(values):
    return b"\x16" + b"".join(tlv.encode_uint(v) for v in values) + b"\x18"


def _device_type_list():
    # array(struct(context 0: device type 0x010d, context 1: revision 2))
    return bytes.fromhex("161525000d012401021818")


class MockLamp:
    def __init__(self):
        self.node, self.ep = 4660, 1
        self.on, self.level, self.hue, self.sat = False, 100, 50, 200
        self.color_mode, self.mireds = 0, 300
        self.stale_reads = 0
        self.mode = "ok"          # ok | http503 | badjson | errors | wrongid | nostatus | failstatus
        self.invokes: list[tuple] = []
        self.reads = 0
        self._snapshot = None

    def snapshot(self):
        return (self.on, self.level, self.hue, self.sat, self.color_mode, self.mireds)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    @property
    def lamp(self) -> MockLamp:
        return self.server.lamp

    def do_GET(self):
        l = self.lamp
        if self.path != "/devices":
            return self._send(404, b"not found", "text/plain")
        if l.mode == "http503":
            return self._send(503, b"unavailable", "text/plain")
        self._send(200, json.dumps([{"nodeId": l.node, "endpoints": [0, l.ep]}]).encode())

    def do_POST(self):
        l = self.lamp
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if l.mode == "http503":
            return self._send(503, b"unavailable", "text/plain")
        if l.mode == "badjson":
            return self._send(200, b'{"values":[')
        if self.path == "/interaction/readAttribute":
            return self._read(l, req)
        if self.path == "/interaction/invokeCommand":
            return self._invoke(l, req)
        self._send(404, b"not found", "text/plain")

    def _read(self, l: MockLamp, r):
        if l.mode == "errors":
            return self._send(200, json.dumps({"errors": [{"status": "UnsupportedAttribute"}], "values": []}).encode())
        l.reads += 1
        st = l._snapshot if (l.stale_reads > 0 and l._snapshot is not None) else l.snapshot()
        if l.stale_reads > 0:
            l.stale_reads -= 1
        on, level, hue, sat, mode, mireds = st
        table = {
            (6, 0): tlv.encode_bool(on),
            (8, 0): tlv.encode_uint(level),
            (768, 0): tlv.encode_uint(hue),
            (768, 1): tlv.encode_uint(sat),
            (768, 7): tlv.encode_uint(mireds),
            (768, 8): tlv.encode_uint(mode),
            (29, 0): _device_type_list(),
            (29, 1): _array_uint([29, 6, 8, 768]),
            (6, 0xFFFB): _array_uint([0, 0xFFFC, 0xFFFD]),
            (6, 0xFFF9): _array_uint([0, 1]),
            (6, 0xFFFC): tlv.encode_uint(0),
            (8, 0xFFFB): _array_uint([0, 0xFFF9, 0xFFFB, 0xFFFC, 0xFFFD]),
            (8, 0xFFF9): _array_uint([0, 1, 2, 3, 4, 5, 6, 7]),
            (8, 0xFFFC): tlv.encode_uint(0),
            (768, 0xFFFB): _array_uint([0, 1, 7, 8, 0x400A, 0x400B, 0x400C,
                                        0xFFF9, 0xFFFB, 0xFFFC, 0xFFFD]),
            (768, 0xFFF9): _array_uint([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 71, 75, 76]),
            (768, 0xFFFC): tlv.encode_uint(25),
            (768, 0x400B): tlv.encode_uint(154),
            (768, 0x400C): tlv.encode_uint(370),
        }
        key = (r["clusterId"], r["attributeId"])
        if key not in table:
            return self._send(200, json.dumps({"errors": [{"status": "UnsupportedAttribute"}], "values": []}).encode())
        ident = r["clusterId"] + (1 if l.mode == "wrongid" else 0)
        self._send(200, json.dumps({"errors": [], "values": [{
            "endpointId": r["endpointId"], "clusterId": ident,
            "attributeId": r["attributeId"], "rawValue": "0x" + table[key].hex()}]}).encode())

    def _invoke(self, l: MockLamp, r):
        if (r["nodeId"], r["endpointId"]) != (l.node, l.ep):
            return self._send(422, b'{"error":"bad target"}')
        l.invokes.append((r["clusterId"], r["commandId"], r["fields"]))
        l._snapshot = l.snapshot()
        c, cmd, f = r["clusterId"], r["commandId"], r["fields"]
        if c == 6 and cmd in (0, 1):
            l.on = cmd == 1
        elif c == 8 and cmd == 0 and l.on:
            l.level = f["level"]
        elif c == 768 and cmd == 6 and l.on:
            l.hue, l.sat, l.color_mode = f["hue"], f["saturation"], 0
        elif c == 768 and cmd == 10 and l.on:
            l.mireds, l.color_mode = f["colorTemperatureMireds"], 2
        if l.mode == "errors":
            return self._send(200, json.dumps({"errors": [{"status": "Failure"}]}).encode())
        resp = {"clusterId": c, "commandId": cmd, "endpointId": r["endpointId"],
                "status": "invoke_callback.cpp:66: Success"}
        if l.mode == "failstatus":
            resp["status"] = "invoke_callback.cpp:66: Failure"
        if l.mode == "wrongid":
            resp["commandId"] = cmd + 1
        if l.mode == "nostatus":
            return self._send(200, json.dumps({}).encode())
        self._send(200, json.dumps({"responses": [resp]}).encode())


class MockServer:
    def __enter__(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.srv.lamp = MockLamp()
        self.lamp = self.srv.lamp
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.srv.shutdown()
        self.srv.server_close()
