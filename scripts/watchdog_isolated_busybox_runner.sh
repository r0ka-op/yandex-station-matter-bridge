#!/bin/sh
set -u

ROOT=$1
SCRIPT="$ROOT/production-watchdog-isolated.sh"
MOCK="$ROOT/mock-wget"
PASS=0
FAIL=0

record() {
    name=$1 status=$2 message=$3
    printf '%s\t%s\t%s\n' "$name" "$status" "$message" >> "$ROOT/results.tsv"
    if [ "$status" = PASS ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

new_case() {
    name=$1
    RUN_ID="audit-$name"
    BASE="$ROOT/$RUN_ID"
    LOCK_DIR="$ROOT/.lock"
    rm -rf "$LOCK_DIR"
    export BASE RUN_ID MAIND_HTTP_RUN_ID="$RUN_ID" MAIND_HTTP_BASE="$BASE" MAIND_TEST_RUN_ROOT="$ROOT"
    mkdir -p "$BASE/mock-bin"
    printf '%s\n' "$RUN_ID" > "$BASE/run_id"
    mkdir "$LOCK_DIR"
    printf '%s\n' "$RUN_ID" > "$LOCK_DIR/run_id"
    printf '%s\n' "$BASE" > "$LOCK_DIR/base"
    printf '%s\n' "$$" > "$LOCK_DIR/owner.pid"
    printf '%s\n' isolated > "$LOCK_DIR/phase"
    printf '%s\n' 2 > "$BASE/watchdog.seconds"
    cp "$MOCK" "$BASE/mock-bin/wget"
    chmod 700 "$BASE/mock-bin/wget"
    : > "$BASE/mock.listener"
    printf '99\n' > "$BASE/mock.level"
    printf '1\n' > "$BASE/mock.onoff"
    rm -f "$BASE/mock.fault"
}

arm_brightness() {
    onoff=$1 level=$2 raw=$3
    printf '%s\n' "$raw" > "$BASE/mock.level.raw"
    "$SCRIPT" light-restore-arm I_APPROVE_LIGHT_STATE_RESTORE brightness "$onoff" "$([ "$onoff" = 0 ] && echo 0x08 || echo 0x09)" "$level" "$raw" - - - - - -
}

assert_safe() {
    [ ! -e "$BASE/FORBIDDEN_NETWORK_TARGET" ] &&
    [ ! -e "$BASE/FORBIDDEN_PLATFORMD_SIGNAL" ]
}

new_case off4_success
if arm_brightness 0 4 0x0404 && "$SCRIPT" light-restore-now &&
   [ "$(cat "$BASE/mock.level")" = 4 ] && [ "$(cat "$BASE/mock.onoff")" = 0 ] &&
   [ ! -e "$BASE/light.restore.armed" ] && [ ! -e "$BASE/LIGHT_STATE_MAY_BE_CHANGED" ] &&
   [ -e "$BASE/light.restore.verified" ] && assert_safe; then
    record off4_success PASS restored_and_verified
else record off4_success FAIL state_or_marker_mismatch; fi

new_case on62_success
if arm_brightness 1 62 0x043e && "$SCRIPT" light-restore-now &&
   [ "$(cat "$BASE/mock.level")" = 62 ] && [ "$(cat "$BASE/mock.onoff")" = 1 ] &&
   [ ! -e "$BASE/light.restore.armed" ] && [ -e "$BASE/light.restore.verified" ] && assert_safe; then
    record on62_success PASS restored_and_verified
else record on62_success FAIL state_or_marker_mismatch; fi

for kind in http_failure invalid_json timeout; do
    new_case "$kind"
    arm_brightness 0 4 0x0404
    printf '%s\n' "$kind" > "$BASE/mock.fault"
    if ! "$SCRIPT" light-restore-now && [ -e "$BASE/light.restore.armed" ] &&
       [ -e "$BASE/LIGHT_STATE_MAY_BE_CHANGED" ] && assert_safe; then
        record "$kind" PASS failed_closed_marker_preserved
    else record "$kind" FAIL unexpected_success_or_marker_loss; fi
done

new_case partial_restore
arm_brightness 0 4 0x0404
printf '%s\n' partial_readback > "$BASE/mock.fault"
if ! "$SCRIPT" light-restore-now && [ "$(cat "$BASE/mock.level")" = 4 ] &&
   [ "$(cat "$BASE/mock.onoff")" = 1 ] && [ -e "$BASE/light.restore.armed" ] &&
   [ -e "$BASE/LIGHT_STATE_MAY_BE_CHANGED" ] && assert_safe; then
    record partial_restore PASS level_changed_but_unverified_onoff_not_touched
else record partial_restore FAIL partial_state_contract_failed; fi

new_case controller_loss
arm_brightness 0 4 0x0404
rm -f "$BASE/mock.listener"
: > "$BASE/rollback.request"
"$SCRIPT" watchdog > "$BASE/watchdog.test.stdout" 2>&1 &
wpid=$!
end=$(( $(date +%s) + 12 ))
while kill -0 "$wpid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
wait "$wpid" || true
if [ -e "$BASE/completed" ] && [ ! -e "$BASE/light.restore.armed" ] &&
   [ "$(cat "$BASE/mock.level")" = 4 ] && [ "$(cat "$BASE/mock.onoff")" = 0 ] && assert_safe; then
    record controller_loss PASS watchdog_restored_without_controller
else record controller_loss FAIL watchdog_did_not_complete_restore; fi

new_case repeated_rollback
arm_brightness 1 62 0x043e
rm -f "$BASE/mock.listener"
if "$SCRIPT" rollback first && "$SCRIPT" rollback second &&
   grep -q 'rollback already_clean reason=second' "$BASE/experiment.log" &&
   [ ! -e "$BASE/light.restore.armed" ] && [ -e "$BASE/completed" ] && assert_safe; then
    record repeated_rollback PASS idempotent_already_clean
else record repeated_rollback FAIL rollback_not_idempotent; fi

printf 'PASS=%s\nFAIL=%s\n' "$PASS" "$FAIL" > "$ROOT/summary.txt"
[ "$FAIL" -eq 0 ]
