#!/usr/bin/env python3
"""Offline ssh.exe substitute for executing the production PowerShell controller.

Only enabled when MAIND_MOCK_ROOT points at an isolated local test directory.
It models the station filesystem, helper lifecycle, wget HTTP evidence and
Matter state. It never opens a network connection.
"""
from __future__ import annotations

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


def parse_run_id(command: str) -> str:
    match = re.search(r"MAIND_HTTP_RUN_ID=([^ ]+)", command)
    return match.group(1).strip("'\"") if match else "mock-legacy-run"


def lifecycle_refusal(exit_code: int, code: str, condition: str, detail: str,
                      action: str = "inspect_and_recover", changed: str = "no") -> int:
    print(
        "MAIND_PREFLIGHT_REFUSAL|"
        f"code={code}|stage=lifecycle|condition={condition}|system_changed={changed}|"
        f"action={action}|detail={detail}"
    )
    return exit_code


def tlv_uint(value: int) -> str:
    if value <= 0xFF:
        return "0x04" + value.to_bytes(1, "little").hex()
    if value <= 0xFFFF:
        return "0x05" + value.to_bytes(2, "little").hex()
    return "0x06" + value.to_bytes(4, "little").hex()


def tlv_array(values):
    return "0x16" + "".join(tlv_uint(v)[2:] for v in values) + "18"


def inventory_fixture(state, endpoint, cluster, attribute):
    globals_ = [65528, 65529, 65530, 65531, 65532, 65533]
    servers = {
        0: [29, 40, 31, 49, 60, 62, 321911818],
        1: [29, 3, 6, 8, 768, 321911814, 321911820],
        2: [29, 0x22220001],
    }
    attrs = {
        29: [0, 1, 2, 3, 4] + globals_,
        40: [1, 2, 3, 4, 7, 8, 9, 10, 15, 18] + globals_,
        31: list(range(5)) + globals_, 49: list(range(8)) + globals_, 60: [0, 1, 2] + globals_,
        62: [0, 1, 2, 3, 4, 5] + globals_, 3: [0] + globals_,
        6: [0, 16384, 16385, 16386, 16387] + globals_,
        8: [0, 1, 2, 3, 15, 16, 17] + globals_,
        768: [0, 1, 3, 4, 7, 8, 16394] + globals_,
        321911814: [0, 1] + globals_, 321911818: [0, 1, 2] + globals_,
        321911820: [0] + globals_, 0x22220001: list(range(40)) + globals_,
    }
    if cluster == 29:
        if attribute == 0: return "0x161525000d012401011818"
        if attribute == 1: return tlv_array(servers.get(endpoint, [29]))
        if attribute == 2: return tlv_array([])
        if attribute == 3: return tlv_array([1, 2] if endpoint == 0 else [])
        if attribute == 4: return "0x14"  # nullable TagList fixture
    if attribute == 65531: return tlv_array(attrs.get(cluster, globals_))
    if attribute in (65528, 65529, 65530):
        accepted = {6: [0, 1, 2], 8: list(range(8)), 768: [0, 6, 7, 10], 321911814: [0, 1]}
        return tlv_array(accepted.get(cluster, []) if attribute == 65529 else [])
    if attribute == 65532: return tlv_uint(25 if cluster == 768 else 0)
    if attribute == 65533: return tlv_uint(1)
    if cluster == 40:
        strings = {1: "Yandex", 3: "YNDX-00560", 8: "HW-1", 10: "mock-fw", 15: "SERIAL-MOCK", 18: "UNIQUE-MOCK"}
        if attribute in strings:
            raw = strings[attribute].encode(); return "0x0c" + bytes([len(raw)]).hex() + raw.hex()
        return tlv_uint({2: 4660, 4: 560, 7: 1, 9: 100}.get(attribute, 0))
    if cluster == 49:
        if attribute == 1: return "0x161510030102031818"  # array -> structure -> anonymous bytes
        if attribute in (5,): return tlv_uint(0)
        if attribute in (6,): return "0x1004aabbccdd"
        return tlv_uint(1)
    if cluster == 60: return tlv_uint({0: 0, 1: 0, 2: 0}.get(attribute, 0))
    if cluster == 62:
        if attribute in (0, 1, 4): return tlv_array([])
        return tlv_uint({2: 5, 3: 1, 5: 1}.get(attribute, 0))
    if cluster == 6 and attribute == 0: return "0x09" if state["onoff"] else "0x08"
    if cluster == 8 and attribute == 0: return tlv_uint(state["level"])
    if cluster == 768 and attribute in (0, 1, 3, 4, 7, 8):
        values = {0: state["hue"], 1: state["saturation"], 3: state["x"], 4: state["y"], 7: state["temperature"], 8: state["color_mode"]}
        return tlv_uint(values[attribute])
    if cluster >= 65536 and attribute == 1: return "0x14"
    return tlv_uint(attribute & 0xFF)


def read_fixture(state, endpoint, cluster, attribute):
    if os.environ.get("MAIND_MOCK_INVENTORY") == "1":
        return inventory_fixture(state, endpoint, cluster, attribute)
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


def http_response(command: str):
    state = load_state()
    state["http_count"] += 1
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
        endpoints = [0, 1, 2] if os.environ.get("MAIND_MOCK_INVENTORY") == "1" else [0, 1]
        response = [{"nodeId": 4660, "endpoints": endpoints, "macAddress": "MOCK-SENSITIVE"}]
    elif path == "/interaction/readAttribute":
        cluster = int(request["clusterId"])
        attribute = int(request["attributeId"])
        endpoint = int(request["endpointId"])
        if fault == "inventory_fault_matrix" and endpoint == 1 and cluster == 8 and attribute == 0:
            sys.stderr.write("wget: download timed out\n__MAIND_WGET_EXIT__=1\n")
            save_state(state)
            return b"", None, 0
        if fault == "inventory_fault_matrix" and endpoint == 1 and cluster == 768 and attribute == 0:
            response = b'{"errors":[],'
        elif fault == "inventory_fault_matrix" and endpoint == 1 and cluster == 321911814 and attribute == 0:
            response = {"errors": []}
        elif fault == "inventory_fault_matrix" and endpoint == 2 and cluster == 0x22220001 and attribute == 0:
            response = {"errors": [], "values": [{
                "endpointId": endpoint, "clusterId": cluster, "attributeId": attribute,
                "rawValue": "0x16", "dataVersion": 7,
            }]}
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
        if response is not None:
            raw = None
        elif os.environ.get("MAIND_MOCK_INVENTORY") == "1" and cluster == 62 and attribute == 0:
            response = {"errors": [{"status": "ACCESS_DENIED"}], "values": []}
            raw = None
        else:
            raw = read_fixture(state, int(request["endpointId"]), cluster, attribute)
        if response is not None:
            pass
        elif raw is None:
            response = {"errors": [{"status": "UnsupportedAttribute"}], "values": []}
        else:
            response = {"errors": [], "values": [{
                "endpointId": int(request["endpointId"]), "clusterId": int(request["clusterId"]),
                "attributeId": int(request["attributeId"]), "rawValue": raw, "dataVersion": 7,
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
    with (ROOT / "ssh_commands.log").open("a", encoding="utf-8") as command_log:
        command_log.write(command.replace("\n", "\\n") + "\n")
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
    base = parse_base(command)
    base_path = remote_path(base)
    run_id = parse_run_id(command)
    operation_match = re.search(r"(?:'[^']+'|/tmp/[^ ]+)\s+(preflight|arm|rollback|verify-clean|status|http-diagnostics|control-restore-arm|control-restore-clear|light-restore-arm|light-restore-clear)(?:\s|$)", command)
    if operation_match:
        op=operation_match.group(1)
        lock_path=remote_path("/tmp/maind-http-runtime.lock")
        run_root=remote_path("/tmp/maind-http-runs")
        legacy_present=remote_path("/tmp/maind-http-test").exists() or remote_path("/tmp/maind-http-read-verify").exists()
        unresolved=[]
        if run_root.exists():
            for candidate in run_root.iterdir():
                if not candidate.is_dir() or candidate == base_path: continue
                candidate_id=(candidate/"run_id").read_text(encoding="utf-8").strip() if (candidate/"run_id").exists() else ""
                completed=(candidate/"completed").read_text(encoding="utf-8").strip() if (candidate/"completed").exists() else ""
                if not candidate_id or completed != candidate_id: unresolved.append(str(candidate))
        if op == "preflight":
            if os.environ.get("MAIND_MOCK_MISSING_UTILITY"):
                print("MAIND_PREFLIGHT_REFUSAL|code=PF_MISSING_UTILITY|stage=environment|condition=dependency|system_changed=no|action=install_or_restore_utility|detail="+os.environ["MAIND_MOCK_MISSING_UTILITY"])
                return 70
            if remote_path("/tmp/maind-http-test").exists():
                return lifecycle_refusal(71, "PF_LEGACY_HTTP_TEST", "legacy_http_test", "/tmp/maind-http-test", "archive_then_point_cleanup")
            if remote_path("/tmp/maind-http-read-verify").exists():
                return lifecycle_refusal(72, "PF_LEGACY_READ_VERIFY", "legacy_read_verify", "/tmp/maind-http-read-verify", "archive_then_point_cleanup")
            if os.environ.get("MAIND_MOCK_WORKER") == "1":
                return lifecycle_refusal(73, "PF_EXPERIMENT_WORKER", "experiment_worker", "4243:mock-watchdog", "inspect_worker")
            if unresolved:
                return lifecycle_refusal(74, "PF_UNRESOLVED_RUN", "per_run_state", unresolved[0], "inspect_and_recover")
            if base_path.exists():
                return lifecycle_refusal(75, "PF_RUN_BASE_EXISTS", "requested_run_base", base, "inspect_run_base")
            if lock_path.exists():
                owner=(lock_path/"owner.pid").read_text(encoding="utf-8").strip() if (lock_path/"owner.pid").exists() else "unknown"
                code="PF_LOCK_ACTIVE" if os.environ.get("MAIND_MOCK_LOCK_ACTIVE") == "1" else "PF_LOCK_STALE_OR_AMBIGUOUS"
                return lifecycle_refusal(76, code, "global_lock", f"owner_pid={owner}", "inspect_lock")
            print(f"preflight=clean run_id={run_id} base={base}")
        elif op == "arm":
            if legacy_present or lock_path.exists() or base_path.exists() or unresolved: return 1
            lock_path.mkdir(parents=True)
            (lock_path/"run_id").write_text(run_id+"\n",encoding="utf-8")
            (lock_path/"base").write_text(base+"\n",encoding="utf-8")
            (lock_path/"owner.pid").write_text("4242\n",encoding="utf-8")
            (lock_path/"phase").write_text("active\n",encoding="utf-8")
            base_path.mkdir(parents=True, exist_ok=False)
            (base_path/"run_id").write_text(run_id+"\n",encoding="utf-8")
            (base_path/"patches").mkdir()
            (base_path/"watchdog.pid").write_text(run_id+"\n4242\n",encoding="utf-8")
            (base_path/"activation.started").write_text(run_id+"\n",encoding="utf-8")
            (base_path/"listener.active").write_text("run_id="+run_id+"\nmock-listener\n",encoding="utf-8")
            (base_path/"experiment.log").write_text("ACTIVATED mock\n",encoding="utf-8")
        elif op == "rollback":
            if not base_path.exists() or (base_path/"run_id").read_text(encoding="utf-8").strip() != run_id: return 1
            (base_path/"rollback.lock").write_text(run_id+"\n",encoding="utf-8")
            state=load_state()
            restore=base_path/"mock.restore.json"
            if restore.exists():
                original=json.loads(restore.read_text(encoding="utf-8"))
                state.update(original);save_state(state);restore.unlink()
            (base_path/"completed").write_text(run_id+"\n",encoding="utf-8")
            if lock_path.exists():
                for child in lock_path.iterdir(): child.unlink()
                lock_path.rmdir()
            with (base_path/"experiment.log").open("a",encoding="utf-8") as f:f.write("rollback complete\n")
        elif op == "verify-clean":
            if not (base_path/"completed").exists() or (base_path/"completed").read_text(encoding="utf-8").strip() != run_id or lock_path.exists(): return 1
        elif op == "status": print(f"run_id={run_id}\ncompleted={'yes' if (base_path/'completed').exists() else 'no'}\nlisteners:\nguard4=no\nguard6=no\npatch_mount=no\npatch_mount_path=absent")
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
