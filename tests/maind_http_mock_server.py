#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        devices_mode = self.headers.get("X-Mock-Devices-Mode", "valid")
        devices_routes = {
            "valid": (200, "application/json", json.dumps([
                {"nodeId": 258, "endpoints": [0, 1]}
            ]).encode()),
            "no-target": (200, "application/json", json.dumps([
                {"nodeId": 999, "endpoints": [1]}
            ]).encode()),
            "empty": (200, "application/json", b""),
            "404": (404, "text/plain", b"not found"),
            "503": (503, "text/plain", b"unavailable"),
            "invalid-json": (200, "application/json", b'{"devices":['),
        }
        routes = {
            "/devices-array": (200, "application/json", json.dumps([
                {"nodeId": 258, "endpoints": [1]}
            ]).encode()),
            "/devices-wrapper": (200, "application/json", json.dumps({
                "result": {"devices": [{"nodeId": "0x0102"}]},
                "metadata": {"schema": "wrapper"},
            }).encode()),
            "/devices-no-target": (200, "application/json", json.dumps({
                "devices": [{"nodeId": 999}]
            }).encode()),
            "/empty": (200, "application/json", b""),
            "/not-found": (404, "text/plain", b"not found"),
            "/unavailable": (503, "text/plain", b"unavailable"),
            "/invalid-json": (200, "application/json", b'{"devices":['),
        }
        if self.path == "/devices":
            status, content_type, body = devices_routes.get(
                devices_mode, (400, "text/plain", b"unknown mock mode")
            )
        else:
            status, content_type, body = routes.get(
                self.path, (404, "text/plain", b"unknown route")
            )
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            request = json.loads(raw.decode("utf-8"))
        except Exception:
            self._send(400, "application/json", b'{"error":"invalid json"}')
            return
        if not self.headers.get("Content-Type", "").lower().startswith("application/json"):
            self._send(415, "application/json", b'{"error":"content type"}')
            return
        if self.path == "/interaction/readAttribute":
            common_valid = (
                set(request) == {"nodeId", "endpointId", "clusterId", "attributeId"}
                and request["nodeId"] == 258
                and request["endpointId"] == 1
            )
            if not common_valid:
                self._send(422, "application/json", json.dumps({
                    "error": "unexpected request", "received": request,
                }).encode())
                return
            capability_mode = self.headers.get("X-Mock-Capability-Mode")
            if capability_mode:
                self._send_capability_attribute(request, capability_mode)
                return
            pair = (request["clusterId"], request["attributeId"])
            values = {
                (6, 0): self._tlv_bool(self.server.onoff_state),
                (8, 0): self._tlv_uint(self.server.current_level),
                (8, 15): self._tlv_uint(0),
                (8, 16): self._tlv_uint(0),
                (8, 17): self._tlv_uint(255),
                (768, 0): self._tlv_uint(self.server.current_hue),
                (768, 1): self._tlv_uint(self.server.current_saturation),
                (768, 3): self._tlv_uint(self.server.current_x),
                (768, 4): self._tlv_uint(self.server.current_y),
                (768, 7): self._tlv_uint(self.server.color_temperature),
                (768, 8): self._tlv_uint(self.server.color_mode),
            }
            if pair not in values:
                self._send(422, "application/json", json.dumps({
                    "error": "unexpected request", "received": request,
                }).encode())
                return
            self._send(200, "application/json", json.dumps({
                "errors": [],
                "values": [{
                    "endpointId": 1,
                    "clusterId": pair[0],
                    "attributeId": pair[1],
                    "rawValue": values[pair],
                }],
            }).encode())
            return
        if self.path == "/interaction/invokeCommand":
            expected_keys = {"nodeId", "endpointId", "clusterId", "commandId", "fields"}
            common_valid = (
                set(request) == expected_keys
                and request["nodeId"] == 258
                and request["endpointId"] == 1
            )
            if not common_valid:
                self._send(422, "application/json", json.dumps({
                    "error": "unexpected invoke", "received": request,
                }).encode())
                return
            if request["clusterId"] == 6 and request["commandId"] in (0, 1) and request["fields"] == {}:
                self.server.onoff_state = request["commandId"] == 1
            elif request["clusterId"] == 8 and request["commandId"] == 0:
                fields = request["fields"]
                if set(fields) != {"level", "transitionTime", "optionsMask", "optionsOverride"}:
                    self._send(422, "application/json", b'{"error":"level fields"}')
                    return
                self.server.current_level = fields["level"]
            elif request["clusterId"] == 768 and request["commandId"] == 6:
                fields = request["fields"]
                if set(fields) != {"hue", "saturation", "transitionTime", "optionsMask", "optionsOverride"}:
                    self._send(422, "application/json", b'{"error":"color fields"}')
                    return
                self.server.current_hue = fields["hue"]
                self.server.current_saturation = fields["saturation"]
                self.server.color_mode = 0
            else:
                self._send(422, "application/json", json.dumps({
                    "error": "unexpected invoke", "received": request,
                }).encode())
                return
            response = {
                "clusterId": request["clusterId"],
                "commandId": request["commandId"],
                "endpointId": request["endpointId"],
                "status": "smart_devices/libs/matter/support/interaction/callback/invoke_callback.cpp:66: Success",
            }
            self._send(200, "application/json", json.dumps({"responses": [response]}).encode())
            return
        self._send(404, "text/plain", b"unknown route")

    def _send_capability_attribute(self, request, mode):
        pair = (request["clusterId"], request["attributeId"])
        if mode == "http-404":
            self._send(404, "text/plain", b"not found")
            return
        if mode == "http-503":
            self._send(503, "text/plain", b"unavailable")
            return
        if mode == "empty":
            self._send(200, "application/json", b"")
            return
        if mode == "invalid-json":
            self._send(200, "application/json", b'{"values":[')
            return

        # Matter TLV fixtures are deliberately encoded bytes, not inferred
        # JSON values. ServerList contains [29, 6, 8, 768].
        fixtures = {
            (29, 1): "0x16041d0406040805000318",
            (8, 0): "0x0480",
            (8, 65532): "0x0601000000",
            (8, 65529): "0x1604000401040204040405040618",
            (768, 16394): "0x051900",
            (768, 8): "0x0401",
            (768, 65532): "0x0619000000",
            (768, 65529): "0x1604000401040304040407040a18",
            (768, 0): "0x047f",
            (768, 1): "0x04c8",
            (768, 3): "0x053412",
            (768, 4): "0x057856",
            (768, 7): "0x05fa00",
            (321911814, 65529): "0x160400040118",
            (321911814, 65531): "0x160400040105f9ff05fbff05fcff18",
            (321911814, 65532): "0x0600000000",
        }
        if mode == "no-level" and pair == (29, 1):
            fixtures[pair] = "0x16041d040605000318"
        if mode == "no-color" and pair == (29, 1):
            fixtures[pair] = "0x16041d0406040818"
        if mode == "malformed-tlv" and pair == (29, 1):
            fixtures[pair] = "0x16041d"
        if mode == "unsupported-optional" and pair != (29, 1):
            self._send(200, "application/json", json.dumps({
                "errors": [{"status": "UnsupportedAttribute"}], "values": []
            }).encode())
            return
        raw_value = fixtures.get(pair)
        if raw_value is None:
            self._send(422, "application/json", json.dumps({
                "error": "unexpected capability pair", "received": request,
            }).encode())
            return
        self._send(200, "application/json", json.dumps({
            "errors": [],
            "values": [{
                "endpointId": 1,
                "clusterId": pair[0],
                "attributeId": pair[1],
                "rawValue": raw_value,
            }],
        }).encode())

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    @staticmethod
    def _tlv_bool(value):
        return "0x09" if value else "0x08"

    @staticmethod
    def _tlv_uint(value):
        if value <= 0xFF:
            return "0x04" + value.to_bytes(1, "little").hex()
        if value <= 0xFFFF:
            return "0x05" + value.to_bytes(2, "little").hex()
        return "0x06" + value.to_bytes(4, "little").hex()

    def log_message(self, fmt, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.onoff_state = False
    server.current_level = 62
    server.current_hue = 159
    server.current_saturation = 244
    server.current_x = 24939
    server.current_y = 24701
    server.color_temperature = 154
    server.color_mode = 0
    print(f"READY {args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
