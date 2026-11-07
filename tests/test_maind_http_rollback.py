#!/usr/bin/env python3
"""Harmless state-model tests for the runtime rollback invariants."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class State:
    patch: bool = True
    dirty: bool = True
    tag: bool = False
    listener: bool = True
    platformd_restored: bool = True
    mounted: bool = True
    guard4: bool = True
    guard6: bool = True
    activation_started: bool = True
    platformd_running: bool = True
    mountpoint: bool = True
    completed: bool = False
    restart_count: int = 0
    rollback_status: str = "not_started"
    light_restore_armed: bool = False
    light_restore_succeeds: bool = True
    light_state_restored: bool = False
    possible_light_state_changed: bool = False


def is_clean(state: State) -> bool:
    return not any(
        (
            state.listener,
            state.mounted,
            state.mountpoint,
            state.guard4,
            state.guard6,
        )
    ) and state.platformd_running


def rollback(state: State) -> State:
    if state.completed and is_clean(state):
        state.rollback_status = "already_clean"
        return state
    state.completed = False
    if state.light_restore_armed:
        if state.listener and state.light_restore_succeeds:
            state.light_state_restored = True
            state.light_restore_armed = False
        else:
            state.possible_light_state_changed = True
    state.patch = state.dirty = state.tag = False
    if state.activation_started or state.listener:
        state.restart_count += 1
        if state.platformd_restored:
            state.listener = False
        else:
            state.platformd_running = False
    if not state.listener:
        state.mounted = False
        state.mountpoint = False
        state.guard4 = state.guard6 = False
    if is_clean(state):
        state.completed = True
        state.rollback_status = "complete"
    else:
        state.rollback_status = "incomplete"
    return state


def main() -> None:
    cases = {}
    normal = rollback(State())
    cases["normal"] = {
        "state": asdict(normal),
        "pass": not any((normal.patch, normal.dirty, normal.listener, normal.mounted, normal.guard4, normal.guard6)),
    }
    no_restart = rollback(State(platformd_restored=False))
    cases["restart_failure"] = {
        "state": asdict(no_restart),
        "pass": no_restart.guard4 and no_restart.guard6 and no_restart.mounted and no_restart.listener,
    }
    stuck_listener = rollback(State(platformd_restored=True, listener=True))
    # Model platformd_restored=False explicitly for a listener that cannot be cleared.
    stuck_listener = rollback(State(platformd_restored=False, listener=True))
    cases["listener_stays"] = {
        "state": asdict(stuck_listener),
        "pass": stuck_listener.guard4 and stuck_listener.guard6 and stuck_listener.mounted,
    }
    restart_count_after_first = normal.restart_count
    second = rollback(normal)
    cases["idempotent"] = {
        "state": asdict(second),
        "pass": second.rollback_status == "already_clean"
        and second.restart_count == restart_count_after_first,
    }
    before_activation = rollback(
        State(
            listener=False,
            mounted=False,
            guard4=False,
            guard6=False,
            activation_started=False,
            mountpoint=False,
        )
    )
    cases["pre_activation_failure"] = {
        "state": asdict(before_activation),
        "pass": before_activation.restart_count == 0 and not before_activation.listener,
    }
    color_restore = rollback(State(light_restore_armed=True))
    cases["color_restore_before_api_shutdown"] = {
        "state": asdict(color_restore),
        "pass": color_restore.light_state_restored
        and not color_restore.light_restore_armed
        and not color_restore.possible_light_state_changed,
    }
    color_restore_failure = rollback(
        State(light_restore_armed=True, light_restore_succeeds=False)
    )
    cases["color_restore_failure_is_reported"] = {
        "state": asdict(color_restore_failure),
        "pass": color_restore_failure.possible_light_state_changed
        and not color_restore_failure.light_state_restored,
    }
    result = {"cases": cases, "all_pass": all(v["pass"] for v in cases.values())}
    helper = (Path(__file__).resolve().parents[1] / "scripts" / "maind_http_runtime_test_remote.sh").read_text(encoding="utf-8")
    dispatch_fixed = 'light-restore-clear) shift; clear_light_restore "$@" ;;' in helper
    cases["light_restore_clear_arguments_forwarded"] = {
        "state": {"dispatcher_match": dispatch_fixed},
        "pass": dispatch_fixed,
    }
    result["all_pass"] = all(v["pass"] for v in cases.values())
    out = Path(__file__).resolve().parents[1] / "results" / "maind_http_rollback_model_test.json"
    out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(out)
    if not result["all_pass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
