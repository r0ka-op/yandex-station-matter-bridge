#!/usr/bin/env python3
"""Execute the production remote lifecycle under an isolated Git/BusyBox-like shell.

The production shell control-flow is preserved. Only station boundaries
(process signalling, firewall, mount, binary identity, listener and health
probes) are replaced with filesystem-backed fakes inside a temporary root.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import traceback
import uuid
from contextlib import contextmanager
from pathlib import Path


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "scripts" / "maind_http_runtime_test_remote.sh"
GIT_SH = Path(r"C:\Program Files\Git\bin\sh.exe")
TOKEN = "I_APPROVE_MAIND_HTTP_RUNTIME_TEST"
# Keep the Git/BusyBox fixture on the same Windows volume as the checkout.
# Git for Windows permission emulation and managed %TEMP% ACLs can otherwise
# leave Python unable to inspect or remove a directory created by the shell.
TEMP_ROOT = Path(tempfile.gettempdir()) / "maind-remote-lifecycle-tests"


@contextmanager
def fixture_directory(prefix: str):
    """Create a Windows-friendly fixture without tempfile's forced 0700 ACL."""
    TEMP_ROOT.mkdir(parents=True, exist_ok=True)
    path = TEMP_ROOT / f"{prefix}{uuid.uuid4().hex}"
    path.mkdir()
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def shell_path(path: Path) -> str:
    return path.resolve().as_posix()


def build_helper(root: Path, run_id: str) -> Path:
    text = SOURCE.read_text(encoding="utf-8")
    run_root = root / "maind-http-runs"
    lock = root / "maind-http-runtime.lock"
    patch = root / "patch-mount"
    replacements = {
        'RUN_ROOT="/tmp/maind-http-runs"': f'RUN_ROOT="{shell_path(run_root)}"',
        'LOCK_DIR="/tmp/maind-http-runtime.lock"': f'LOCK_DIR="{shell_path(lock)}"',
        'PATCH_MOUNT="/data/quasar/quasar_patches"': f'PATCH_MOUNT="{shell_path(patch)}"',
        "/tmp/maind-http-test": shell_path(root / "maind-http-test"),
        "/tmp/maind-http-read-verify": shell_path(root / "maind-http-read-verify"),
    }
    for old, new in replacements.items():
        if old not in text:
            raise AssertionError(f"production contract changed; missing: {old}")
        text = text.replace(old, new)
    injected = r'''
# Test boundary overrides. Production orchestration above is not copied.
missing_required_command() {
    [ -z "${MOCK_MISSING_UTILITY:-}" ] && return 1
    echo "$MOCK_MISSING_UTILITY"; return 0
}
experiment_workers() { [ -n "${MOCK_WORKER:-}" ] && echo "$MOCK_WORKER"; return 0; }
validate_station_preflight() {
    changed=${1:-no}
    if [ -n "${MOCK_STATION_FAILURE:-}" ]; then
        preflight_refusal 89 PF_MEMORY_LOW station memory "$changed" free_memory "$MOCK_STATION_FAILURE"; return $?
    fi
    return 0
}
verify_binary() { return 0; }
listener_lines() { [ -f "$MOCK_ROOT/listener" ] && echo 'mock tcp/8765'; return 0; }
has_listener() { [ -f "$MOCK_ROOT/listener" ]; }
guard4_present() { [ -f "$MOCK_ROOT/guard4" ]; }
guard6_present() { [ -f "$MOCK_ROOT/guard6" ]; }
iptables() {
    case "$1" in -I) touch "$MOCK_ROOT/guard4";; -D) rm -f "$MOCK_ROOT/guard4";; -C) guard4_present;; esac
}
ip6tables() {
    case "$1" in
        -I) [ "${MOCK_FAIL_STAGE:-}" = guard6 ] && return 1; touch "$MOCK_ROOT/guard6";;
        -D) rm -f "$MOCK_ROOT/guard6";; -C) guard6_present;;
    esac
}
iptables-save() { echo mock-ipv4; }
ip6tables-save() { echo mock-ipv6; }
mount() {
    [ "${MOCK_FAIL_STAGE:-}" = mount ] && return 1
    cp "$PATCH_SOURCE/$PATCH_NAME" "$PATCH_MOUNT/$PATCH_NAME" || return 1
    touch "$MOCK_ROOT/mounted"
}
umount() { rm -f "$MOCK_ROOT/mounted"; }
mount_present() { [ -f "$MOCK_ROOT/mounted" ]; }
mount_verified() { mount_present && [ -r "$PATCH_MOUNT/$PATCH_NAME" ]; }
canonical_path() { echo "$1"; }
launcher_pid() { echo 900; }
platformd_pid() { cat "$MOCK_ROOT/platformd.pid"; }
kill() {
    if [ "$1" = -0 ]; then return 0; fi
    if [ "$1" = -TERM ]; then
        old=$2; new=$((old + 1)); echo "$new" > "$MOCK_ROOT/platformd.pid"
        if [ -r "$PATCH_MOUNT/$PATCH_NAME" ]; then touch "$MOCK_ROOT/listener"; else rm -f "$MOCK_ROOT/listener"; fi
        echo "$old" >> "$MOCK_ROOT/signals.log"; return 0
    fi
    command kill "$@"
}
wait_for_new_platformd() { platformd_pid; }
wait_listener_state() {
    if [ "$1" = present ]; then touch "$MOCK_ROOT/listener"; else rm -f "$MOCK_ROOT/listener"; fi
    return 0
}
health_snapshot() {
    [ "${MOCK_FAIL_STAGE:-}" = "health-$1" ] && return 1
    printf 'mock-health=%s\n' "$1" > "$BASE/$1.snapshot"
}
save_mount_diagnostics() { printf 'mock-mount=%s\n' "$1" > "$BASE/mount.$1.txt" 2>/dev/null || true; }
watchdog_selftest() { [ "${MOCK_FAIL_STAGE:-}" != watchdog-selftest ]; }
flock() { return 0; }
setsid() {
    # The target-side watchdog implementation has its own BusyBox runtime
    # suite. Here a short-lived process exercises arm() PID/liveness handling
    # without allowing a background child to mutate the isolated fixture.
    if [ "$1" = nohup ]; then sleep 3; else command setsid "$@"; fi
}
'''
    needle = 'case "${1:-}" in\n'
    if needle not in text:
        raise AssertionError("production dispatch contract changed")
    text = text.replace(needle, injected + "\n" + needle, 1)
    helper = root / "remote-helper.sh"
    helper.write_text(text, encoding="utf-8", newline="\n")
    helper.chmod(0o755)
    return helper


def invoke(helper: Path, root: Path, run_id: str, operation: str, extra_env=None):
    env = os.environ.copy()
    env.update({
        "MAIND_HTTP_RUN_ID": run_id,
        "MAIND_HTTP_BASE": shell_path(root / "maind-http-runs" / run_id),
        "MAIND_HTTP_NODE_ID": "4660",
        "MAIND_HTTP_ENDPOINT_ID": "1",
        "MOCK_ROOT": shell_path(root),
    })
    if extra_env:
        env.update(extra_env)
    shell_args=[str(GIT_SH)]
    if extra_env and extra_env.get("MOCK_TRACE") == "1": shell_args.append("-x")
    return subprocess.run(
        [*shell_args, shell_path(helper), *operation.split()],
        text=True, capture_output=True, env=env, timeout=30,
    )


def refusal_case(name, setup, expected_code, expected_exit):
    with fixture_directory("maind-shell-") as root:
        run_id = "run-shell-" + name
        (root / "platformd.pid").write_text("1000\n", encoding="ascii")
        helper = build_helper(root, run_id)
        env = setup(root) or {}
        result = invoke(helper, root, run_id, f"preflight {TOKEN}", env)
        passed = result.returncode == expected_exit and f"code={expected_code}|" in result.stdout
        return {"name": name, "pass": passed, "exit": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr}


def main():
    if not GIT_SH.exists():
        raise SystemExit("Git sh is required")
    cases = []
    cases.append(refusal_case("legacy-http", lambda r: ((r/"maind-http-test").mkdir(), {})[1], "PF_LEGACY_HTTP_TEST", 71))
    cases.append(refusal_case("legacy-read", lambda r: ((r/"maind-http-read-verify").mkdir(), {})[1], "PF_LEGACY_READ_VERIFY", 72))
    def unresolved(r):
        d=r/"maind-http-runs"/"old";d.mkdir(parents=True);(d/"run_id").write_text("old\n");return {}
    cases.append(refusal_case("unresolved", unresolved, "PF_UNRESOLVED_RUN", 74))
    def lock(r):
        d=r/"maind-http-runtime.lock";d.mkdir();(d/"owner.pid").write_text("999999\n");return {}
    cases.append(refusal_case("stale-lock", lock, "PF_LOCK_STALE_OR_AMBIGUOUS", 76))
    cases.append(refusal_case("worker", lambda r: {"MOCK_WORKER":"4243:watchdog"}, "PF_EXPERIMENT_WORKER", 73))
    cases.append(refusal_case("missing-utility", lambda r: {"MOCK_MISSING_UTILITY":"flock"}, "PF_MISSING_UTILITY", 70))
    cases.append(refusal_case("station-failure", lambda r: {"MOCK_STATION_FAILURE":"memavailable_kb=1"}, "PF_MEMORY_LOW", 89))

    for fault in ("none", "guard6", "mount", "watchdog-selftest", "health-active"):
        with fixture_directory("maind-shell-") as root:
            run_id="run-shell-"+fault
            (root/"platformd.pid").write_text("1000\n",encoding="ascii")
            helper=build_helper(root,run_id)
            env={} if fault=="none" else {"MOCK_FAIL_STAGE":fault}
            if fault=="watchdog-selftest": env["MOCK_TRACE"]="1"
            pre=invoke(helper,root,run_id,f"preflight {TOKEN}",env)
            arm=invoke(helper,root,run_id,f"arm {TOKEN} 120",env)
            base=root/"maind-http-runs"/run_id
            if fault=="none":
                rollback=invoke(helper,root,run_id,"rollback shell_harness",env)
                verify=invoke(helper,root,run_id,"verify-clean",env)
                passed=(pre.returncode==0 and arm.returncode==0 and rollback.returncode==0 and verify.returncode==0
                        and (base/"completed").read_text().strip()==run_id
                        and not (root/"maind-http-runtime.lock").exists())
            else:
                # Most operational failures roll back in helper code. A
                # harmless pre-change self-test failure is completed by the
                # production controller's catch-path rollback request.
                verify=invoke(helper,root,run_id,"verify-clean",env)
                rollback=None
                if verify.returncode != 0:
                    rollback=invoke(helper,root,run_id,"rollback controller_error",env)
                    verify=invoke(helper,root,run_id,"verify-clean",env)
                signals=(root/"signals.log").read_text().splitlines() if (root/"signals.log").exists() else []
                if fault in {"guard6","mount","watchdog-selftest"}:
                    no_activation = len(signals)==0
                else:
                    no_activation = len(signals)>=2  # activation plus rollback restore
                passed=(pre.returncode==0 and arm.returncode!=0 and verify.returncode==0 and no_activation)
            cases.append({"name":"arm-"+fault,"pass":passed,"preflight_exit":pre.returncode,
                          "arm_exit":arm.returncode,"verify_exit":verify.returncode,
                          "arm_stdout":arm.stdout,"arm_stderr":arm.stderr,
                          "rollback_exit":None if rollback is None else rollback.returncode})
            time.sleep(2.2)

    # Execute the production watchdog() body independently of the controller.
    # arm() stages the normal 120-second value; shortening only the isolated
    # fixture file makes the test finish promptly without changing production.
    with fixture_directory("maind-shell-watchdog-") as root:
        run_id="run-shell-watchdog-expiry"
        (root/"platformd.pid").write_text("1000\n",encoding="ascii")
        helper=build_helper(root,run_id)
        pre=invoke(helper,root,run_id,f"preflight {TOKEN}")
        arm=invoke(helper,root,run_id,f"arm {TOKEN} 120")
        base=root/"maind-http-runs"/run_id
        (base/"watchdog.seconds").write_text("1\n",encoding="ascii")
        expired=invoke(helper,root,run_id,"watchdog")
        verify=invoke(helper,root,run_id,"verify-clean")
        completed=(base/"completed").read_text().strip() if (base/"completed").exists() else ""
        passed=(pre.returncode==0 and arm.returncode==0 and expired.returncode==0 and
                verify.returncode==0 and completed==run_id and
                not (root/"maind-http-runtime.lock").exists())
        cases.append({"name":"watchdog-independent-expiry","pass":passed,
                      "preflight_exit":pre.returncode,"arm_exit":arm.returncode,
                      "watchdog_exit":expired.returncode,"verify_exit":verify.returncode,
                      "watchdog_stdout":expired.stdout,"watchdog_stderr":expired.stderr})

    result={
        "generated_utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),
        "production_shell_sha256":hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "boundary":"filesystem-backed substitutes only for station-dangerous operations",
        "case_count":len(cases),"passed":sum(1 for c in cases if c["pass"]),
        "all_pass":all(c["pass"] for c in cases),"cases":cases,
    }
    output=HERE.parent/"results"/"tests"/"remote_lifecycle_shell.json"
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,indent=2),encoding="utf-8")
    print(json.dumps(result,indent=2))
    return 0 if result["all_pass"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        crash=HERE.parent/"results"/"tests"/"remote_lifecycle_shell_crash.txt"
        crash.parent.mkdir(parents=True,exist_ok=True)
        crash.write_text(traceback.format_exc(),encoding="utf-8")
        raise
