#!/usr/bin/env python3
"""Run the real watchdog restoration branches on Station BusyBox with mocked boundaries."""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import time


def run_ssh(alias: str, command: str, data: bytes | None = None, timeout: int = 60):
    return subprocess.run(
        ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, command],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
    )


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one replacement, found {count}")
    return text.replace(old, new)


def build_isolated(production: pathlib.Path) -> str:
    text = production.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'RUN_ROOT="/tmp/maind-http-runs"',
        'RUN_ROOT="${MAIND_TEST_RUN_ROOT:?}"',
        "isolated run root",
    )
    text = replace_once(text, 'LOCK_DIR="/tmp/maind-http-runtime.lock"', 'LOCK_DIR="$RUN_ROOT/.lock"', "isolated lock")
    text = replace_once(text, 'PATCH_MOUNT="/data/quasar/quasar_patches"', 'PATCH_MOUNT="$BASE/mock-patch-mount"', "patch mount")
    if text.count("/usr/bin/wget") != 3:
        raise RuntimeError("expected exactly three production wget calls")
    text = text.replace("/usr/bin/wget", '"$BASE/mock-bin/wget"')
    if text.count('kill -TERM "$old"') != 2:
        raise RuntimeError("platformd signal: expected exactly two replacements")
    text = text.replace('kill -TERM "$old"', 'mock_platformd_signal "$old"')
    marker = 'case "${1:-}" in\n'
    overrides = r'''# Isolated-runtime boundary overrides. Restoration functions above are unchanged.
listener_lines() { :; }
has_listener() { [ -f "$BASE/light.restore.armed" ] || [ -f "$BASE/control.restore.armed" ]; }
guard4_present() { return 1; }
guard6_present() { return 1; }
mount_present() { return 1; }
platformd_pid() { echo 424242; }
wait_listener_state() { [ "$1" = absent ]; }
save_mount_diagnostics() { log "isolated mount diagnostics $1"; }
health_snapshot() { printf 'isolated=yes\n' > "$BASE/$1.snapshot"; }
remove_guards_if_safe() { log "isolated guards unchanged"; }
mock_platformd_signal() { : > "$BASE/FORBIDDEN_PLATFORMD_SIGNAL"; return 1; }
legacy_state_present() { return 1; }
'''
    text = replace_once(text, marker, overrides + marker, "override injection")
    forbidden = ["/usr/bin/wget", 'PATCH_MOUNT="/data/quasar/quasar_patches"', 'kill -TERM "$old"', 'LOCK_DIR="/tmp/maind-http-runtime.lock"']
    for token in forbidden:
        if token in text:
            raise RuntimeError(f"unsafe token remains: {token}")
    return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssh-alias", default="mock-station")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    out = pathlib.Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    remote = f"/tmp/maind-http-watchdog-audit-{int(time.time())}"
    production = root / "scripts" / "maind_http_runtime_test_remote.sh"
    transformed = build_isolated(production)
    files = {
        "production-watchdog-isolated.sh": transformed.encode(),
        "mock-wget": (root / "scripts" / "watchdog_isolated_mock_wget.sh").read_bytes(),
        "runner.sh": (root / "scripts" / "watchdog_isolated_busybox_runner.sh").read_bytes(),
    }
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
    result: dict[str, object] = {"remote": remote, "staged_sha256": manifest}
    try:
        made = run_ssh(args.ssh_alias, f"umask 077; mkdir {remote}")
        if made.returncode:
            raise RuntimeError(made.stderr.decode(errors="replace"))
        for name, data in files.items():
            cp = run_ssh(args.ssh_alias, f"umask 077; cat > {remote}/{name}", data)
            if cp.returncode:
                raise RuntimeError(f"upload {name}: {cp.stderr.decode(errors='replace')}")
        verify = run_ssh(args.ssh_alias, f"chmod 700 {remote}/*; sha256sum {remote}/*; sh -n {remote}/production-watchdog-isolated.sh {remote}/mock-wget {remote}/runner.sh")
        result["remote_verification"] = verify.stdout.decode(errors="replace").splitlines()
        if verify.returncode:
            raise RuntimeError(verify.stderr.decode(errors="replace"))
        execute = run_ssh(args.ssh_alias, f"/bin/sh {remote}/runner.sh {remote}", timeout=150)
        result["runner_exit_code"] = execute.returncode
        result["runner_stdout"] = execute.stdout.decode(errors="replace")
        result["runner_stderr"] = execute.stderr.decode(errors="replace")
        archive = run_ssh(args.ssh_alias, f"tar -C /tmp -cf - {remote.rsplit('/',1)[1]}", timeout=90)
        if archive.returncode:
            raise RuntimeError(f"tar: {archive.stderr.decode(errors='replace')}")
        tar_path = out / "busybox-watchdog-isolated.tar"
        tar_path.write_bytes(archive.stdout)
        result["archive_sha256"] = hashlib.sha256(archive.stdout).hexdigest()
        with tarfile.open(tar_path) as tf:
            names = tf.getnames()
            result["archive_entries"] = len(names)
            if not any(n.endswith("/summary.txt") for n in names):
                raise RuntimeError("summary missing from archive")
            tf.extractall(out / "extracted", filter="data")
        results_file = next((out / "extracted").rglob("results.tsv"))
        cases = []
        for line in results_file.read_text().splitlines():
            name, status, message = line.split("\t", 2)
            cases.append({"name": name, "status": status, "message": message})
        result["cases"] = cases
        result["all_pass"] = execute.returncode == 0 and all(c["status"] == "PASS" for c in cases)
    finally:
        cleanup = run_ssh(args.ssh_alias, f"case {remote} in /tmp/maind-http-watchdog-audit-*) rm -rf {remote};; *) exit 64;; esac")
        result["cleanup_exit_code"] = cleanup.returncode
        result["final_success"] = bool(result.get("all_pass")) and cleanup.returncode == 0
        (out / "busybox_watchdog_runtime_test.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    if result["final_success"]:
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
