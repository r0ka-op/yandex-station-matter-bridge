#!/usr/bin/env python3
"""Offline ssh.exe substitute for executing the production PowerShell controller.

Only enabled when MAIND_MOCK_ROOT points at an isolated local test directory.
It models the station filesystem, helper lifecycle, wget HTTP evidence and
Matter state. It never opens a network connection.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import re
import sys
import tarfile
from pathlib import Path


ROOT = Path(os.environ["MAIND_MOCK_ROOT"]).resolve()
REMOTE = ROOT / "remote"
STATE_PATH = ROOT / "state.json"
REMOTE.mkdir(parents=True, exist_ok=True)


def load_state():
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    state = {
        "onoff": os.environ.get("MAIND_MOCK_INITIAL_ON", "0") == "1", "level": 4, "hue": 159, "saturation": 244,
        "x": 24939, "y": 24701, "temperature": 154, "color_mode": 0,
        "initial_onoff": False, "initial_level": 4, "initial_hue": 159,
        "http_count": 0, "invoke_count": 0,
        "fault": os.environ.get("MAIND_MOCK_FAULT", "none"),
    }
    save_state(state)
    return state


def save_state(state):
    STATE_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")


def remote_path(path: str) -> Path:
    if not path.startswith("/") or ".." in Path(path).parts:
        raise ValueError(f"unsafe remote path: {path}")
    return REMOTE / path.lstrip("/")


def parse_base(command: str) -> str:
    match = re.search(r"MAIND_HTTP_BASE=([^ ]+)", command)
    return match.group(1).strip("'\"") if match else "/tmp/maind-http-test"


def tlv_uint(value: int) -> str:
    if value <= 0xFF:
        return "0x04" + value.to_bytes(1, "little").hex()
    if value <= 0xFFFF:
        return "0x05" + value.to_bytes(2, "little").hex()
    return "0x06" + value.to_bytes(4, "little").hex()


def read_fixture(state, cluster, attribute):
    server_list = "0x160403040404060408041D04500500030606FC2F13060AFC2F13060CFC2F1318"
    fixed = {
        (29, 1): server_list,
        (8, 15): tlv_uint(0), (8, 16): tlv_uint(0), (8, 17): "0x14",
        (8, 65532): "0x0601000000",
        (8, 65529): "0x160400040104020403040404050406040718",
        (768, 16394): "0x051900", (768, 65532): "0x0619000000",
        (768, 65529): "0x160400040104020403040404050406040704080409040a0447044b044c18",
        (321911814, 65529): "0x160400040118",
        (321911814, 65531): "0x160400040105f9ff05fbff05fcff18",
        (321911814, 65532): "0x0600000000",
    }
    dynamic = {
        (6, 0): "0x09" if state["onoff"] else "0x08",
        (8, 0): tlv_uint(state["level"]),
        (768, 0): tlv_uint(state["hue"]),
        (768, 1): tlv_uint(state["saturation"]),
        (768, 3): tlv_uint(state["x"]), (768, 4): tlv_uint(state["y"]),
        (768, 7): tlv_uint(state["temperature"]),
        (768, 8): tlv_uint(state["color_mode"]),
    }
    return dynamic.get((cluster, attribute), fixed.get((cluster, attribute)))


def http_response(command: str, raw_http: bytes | None = None):
    state = load_state()
    state["http_count"] += 1
    if raw_http is not None:
        head, raw_body = raw_http.split(b"\r\n\r\n", 1)
        first = head.split(b"\r\n", 1)[0].decode("ascii")
        method, path, version = first.split(" ")
        if method != "POST" or version != "HTTP/1.1":
            raise ValueError("mock raw HTTP request line mismatch")
        request = json.loads(raw_body.decode("utf-8"))
    else:
        url_match = re.findall(r"'http://127\.0\.0\.1:8765([^']*)'", command)
        path = url_match[-1] if url_match else ""
        body_match = re.search(r"--post-data='([^']*)'", command)
        request = json.loads(body_match.group(1)) if body_match else None
    fault = state.get("fault", "none")
    status, reason = 200, "Ok"
    response = None
    if fault in {"http404", "http500", "http503"}:
        status = int(fault[4:]); reason = "Injected"
        response = {"error": fault}
        state["fault"] = "consumed"
    elif fault == "empty":
        response = b""; state["fault"] = "consumed"
    elif fault == "invalid_json":
        response = b'{"values":['; state["fault"] = "consumed"
    elif fault == "missing_properties":
        response = {"values": []}; state["fault"] = "consumed"
    elif fault == "read_missing_properties" and path == "/interaction/readAttribute":
        response = {"values": []}; state["fault"] = "consumed"
    elif fault == "read_invalid_json" and path == "/interaction/readAttribute":
        response = b'{"errors":[],'; state["fault"] = "consumed"
    elif fault == "read_empty" and path == "/interaction/readAttribute":
        response = b""; state["fault"] = "consumed"
    elif fault == "read_matter_error" and path == "/interaction/readAttribute":
        response = {"errors": [{"status": "Timeout"}], "values": []}; state["fault"] = "consumed"
    elif fault == "ssh_loss":
        save_state(state); return None, None, 255
    elif fault == "matter_timeout":
        save_state(state)
        sys.stderr.write("wget: download timed out\n__MAIND_WGET_EXIT__=1\n")
        return b"", None, 0
    elif path == "/devices":
        response = [{"nodeId": 4660, "endpoints": [0, 1], "macAddress": "MOCK"}]
    elif path == "/interaction/readAttribute":
        cluster = int(request["clusterId"])
        attribute = int(request["attributeId"])
        fail_read = (
            (fault == "visual_color_fail_after_on" and cluster == 6 and attribute == 0 and state["onoff"])
            or (fault == "visual_color_fail_after_level" and cluster == 8 and attribute == 0 and state["level"] == 64)
            or (fault == "visual_color_fail_after_color" and cluster == 768 and attribute == 8 and state["hue"] != state["initial_hue"])
        )
        if fail_read:
            status, reason, response = 503, "Injected visual-color read failure", {"error": fault}
            state["fault"] = "consumed"
            save_state(state)
            data = json.dumps(response, separators=(",", ":")).encode()
            headers = f"  HTTP/1.1 {status} {reason}\n  Content-Type: application/json\n  Content-Length: {len(data)}\n  Connection: Close\n__MAIND_WGET_EXIT__=1\n"
            return data, headers, 0
        raw = read_fixture(state, cluster, attribute)
        if raw is None:
            response = {"errors": [{"status": "UnsupportedAttribute"}], "values": []}
        else:
            response = {"errors": [], "values": [{
                "endpointId": 1, "clusterId": int(request["clusterId"]),
                "attributeId": int(request["attributeId"]), "rawValue": raw,
            }]}
    elif path == "/interaction/invokeCommand":
        state["invoke_count"] += 1
        cluster, cmd, fields = int(request["clusterId"]), int(request["commandId"]), request["fields"]
        restoring = (
            (cluster == 6 and cmd == (1 if state["initial_onoff"] else 0) and state["invoke_count"] > 1)
            or (cluster == 8 and int(fields.get("level", -1)) == state["initial_level"] and state["invoke_count"] > 1)
            or (cluster == 768 and int(fields.get("hue", -1)) == state["initial_hue"] and state["invoke_count"] > 1)
        )
        if fault == "invoke_unconfirmed":
            response = {"errors": []}; state["fault"] = "consumed"
        elif fault == "invoke_matter_error":
            response = {"errors": [{"status": "Failure"}], "responses": []}; state["fault"] = "consumed"
        elif fault == "restore_failure" and restoring:
            status, reason, response = 503, "Injected restore failure", {"error": "restore failure"}
        elif fault == "visual_color_fail_color_restore" and cluster == 768 and int(fields.get("hue", -1)) == state["initial_hue"]:
            status, reason, response = 503, "Injected color restore failure", {"error": fault}; state["fault"] = "consumed"
        elif fault == "visual_color_fail_level_restore" and cluster == 8 and int(fields.get("level", -1)) == state["initial_level"] and state["invoke_count"] > 2:
            status, reason, response = 503, "Injected level restore failure", {"error": fault}; state["fault"] = "consumed"
        elif fault == "visual_color_fail_onoff_restore" and cluster == 6 and cmd == (1 if state["initial_onoff"] else 0) and state["invoke_count"] > 2:
            status, reason, response = 503, "Injected OnOff restore failure", {"error": fault}; state["fault"] = "consumed"
        else:
            if cluster == 6 and cmd in (0, 1): state["onoff"] = cmd == 1
            elif cluster == 8 and cmd == 0: state["level"] = int(fields["level"])
            elif cluster == 768 and cmd == 6:
                state["hue"] = int(fields["hue"]); state["saturation"] = int(fields["saturation"]); state["color_mode"] = 0
            response = {"responses": [{
                "endpointId": 1, "clusterId": cluster, "commandId": cmd,
                "status": "mock/invoke.cpp:1: Success",
            }]}
    else:
        status, reason, response = 404, "Not found", {"error": "route"}
    save_state(state)
    data = response if isinstance(response, bytes) else json.dumps(response, separators=(",", ":")).encode()
    headers = (
        f"  HTTP/1.1 {status} {reason}\n"
        "  Content-Type: application/json\n"
        f"  Content-Length: {len(data)}\n  Connection: Close\n"
        f"__MAIND_WGET_EXIT__={0 if 200 <= status < 300 else 1}\n"
    )
    return data, headers, 0


def write_tar(command: str):
    match = re.search(r"tar -C '([^']+)' -cf - '([^']+)'", command)
    if not match: return 2
    source = remote_path(match.group(1)) / match.group(2)
    if not source.exists(): return 1
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        archive.add(source, arcname=match.group(2), recursive=True)
    sys.stdout.buffer.write(buffer.getvalue())
    return 0


def main():
    command = sys.argv[-1] if len(sys.argv) > 1 else ""
    if "umask 077; cat >" in command:
        path = re.search(r"cat > '([^']+)'", command).group(1)
        target = remote_path(path); target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(sys.stdin.buffer.read()); return 0
    if command.startswith("chmod 700 "):
        path = re.search(r"chmod 700 '([^']+)'", command).group(1)
        data = remote_path(path).read_bytes()
        print(f"size={len(data)}\nsha256={hashlib.sha256(data).hexdigest()}\nshell_check=pass")
        return 0
    if command == "true" or "test -x /usr/bin/wget" in command: return 0
    if command.startswith("tar -C "): return write_tar(command)
    if command.startswith("test -d "):
        path = re.search(r"test -d '?([^']+)'?", command).group(1)
        return 0 if remote_path(path).is_dir() else 1
    if command.startswith("rm -f "):
        for path in re.findall(r"'(/[^']+)'", command):
            remote_path(path).unlink(missing_ok=True)
        return 0
    if "old=/tmp/maind-http-test" in command:
        for name in ("LIGHT_STATE_MAY_BE_CHANGED", "light.restore.armed", "light.restore.state"):
            file = remote_path("/tmp/maind-http-test/" + name)
            if file.is_file():
                data=file.read_bytes(); print(f"{name}|present|{len(data)}|{hashlib.sha256(data).hexdigest()}")
            else: print(f"{name}|absent|-|-")
        return 0
    if "/usr/bin/wget " in command:
        body, headers, exit_code = http_response(command)
        if exit_code: return exit_code
        if headers is not None: sys.stderr.write(headers)
        if body: sys.stdout.buffer.write(body)
        return 0
    if "/bin/busybox telnet 127.0.0.1 8765" in command:
        encoded = re.search(r"printf '%s' '([A-Za-z0-9+/=]+)'", command)
        if not encoded:
            return 2
        body, headers, exit_code = http_response(command, base64.b64decode(encoded.group(1)))
        if exit_code or headers is None:
            sys.stderr.write("__MAIND_TELNET_EXIT__=1\n")
            return 0
        status = re.search(r"HTTP/1\.1 ([1-5][0-9]{2}) ([^\n]+)", headers)
        raw = (
            f"HTTP/1.1 {status.group(1)} {status.group(2).strip()}\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii") + body
        sys.stdout.buffer.write(raw)
        sys.stderr.write("__MAIND_TELNET_EXIT__=0\n")
        return 0
    base = parse_base(command)
    base_path = remote_path(base)
    operation_match = re.search(r"(?:'[^']+'|/tmp/[^ ]+)\s+(arm|rollback|verify-clean|status|http-diagnostics|control-restore-arm|control-restore-clear|light-restore-arm|light-restore-clear)(?:\s|$)", command)
    if operation_match:
        op=operation_match.group(1)
        if op == "arm":
            base_path.mkdir(parents=True, exist_ok=False); (base_path/"patches").mkdir(); (base_path/"experiment.log").write_text("ACTIVATED mock\n",encoding="utf-8")
        elif op == "rollback":
            state=load_state()
            restore=base_path/"mock.restore.json"
            if restore.exists():
                original=json.loads(restore.read_text(encoding="utf-8"))
                state.update(original);save_state(state);restore.unlink()
            base_path.mkdir(parents=True,exist_ok=True); (base_path/"completed").touch();
            with (base_path/"experiment.log").open("a",encoding="utf-8") as f:f.write("rollback complete\n")
        elif op == "verify-clean":
            if not (base_path/"completed").exists(): return 1
        elif op == "status": print("completed=yes\nlisteners:\nguard4=no\nguard6=no\npatch_mount=no\npatch_mount_path=absent")
        elif op == "http-diagnostics": print(str(base_path/"http-diagnostics.mock"))
        elif op.endswith("restore-arm"):
            (base_path/("light.restore.armed" if op.startswith("light") else "control.restore.armed")).touch()
            state=load_state()
            if op.startswith("control"):
                match=re.search(r"control-restore-arm\s+\S+\s+([01])",command)
                original={"onoff":bool(int(match.group(1)))} if match else {}
            else:
                match=re.search(r"light-restore-arm\s+\S+\s+\S+\s+([01])\s+\S+\s+([0-9]+)",command)
                original={"onoff":bool(int(match.group(1))),"level":int(match.group(2))} if match else {}
                if match and " color " in command:
                    color_match=re.search(r"light-restore-arm\s+\S+\s+color\s+[01]\s+\S+\s+[0-9]+\s+\S+\s+[0-9]+\s+\S+\s+([0-9]+)\s+\S+\s+([0-9]+)\s+\S+",command)
                    if color_match:
                        original.update({"color_mode":0,"hue":int(color_match.group(1)),"saturation":int(color_match.group(2))})
            (base_path/"mock.restore.json").write_text(json.dumps(original),encoding="utf-8")
        elif op.endswith("restore-clear"):
            for name in ("light.restore.armed","control.restore.armed","LIGHT_STATE_MAY_BE_CHANGED","CONTROL_STATE_MAY_BE_CHANGED"):
                (base_path/name).unlink(missing_ok=True)
        return 0
    if command.startswith("test ! -f "):
        path=command[len("test ! -f "):].strip().strip("'\"")
        return 0 if not remote_path(path).exists() else 1
    sys.stderr.write(f"unhandled mock ssh command: {command}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
