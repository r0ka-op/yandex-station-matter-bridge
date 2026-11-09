import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import multi_admin_readiness as readiness


class Handler(BaseHTTPRequestHandler):
    paths = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.paths.append(("GET", self.path))
        self._send([{"nodeId": 4660, "endpoints": [0, 1]}])

    def do_POST(self):
        self.paths.append(("POST", self.path))
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        self._send({"errors": [], "values": [{**request, "rawValue": "0x0400"}]})

    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        Handler.paths = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_maind_mode_is_read_only(self):
        args = type("Args", (), {"base_url": f"http://127.0.0.1:{self.server.server_port}", "node_id": 4660})
        result = readiness.run_maind(args)
        self.assertEqual(len(result["reads"]), 16)
        self.assertEqual(Handler.paths[0], ("GET", "/devices"))
        self.assertTrue(all(path == "/interaction/readAttribute" for _, path in Handler.paths[1:]))
        self.assertFalse(any("invoke" in path.lower() or "write" in path.lower() for _, path in Handler.paths))

    def test_non_loopback_is_rejected(self):
        with self.assertRaises(Exception):
            readiness._loopback_url("http://192.0.2.10:8765")


if __name__ == "__main__":
    unittest.main()
