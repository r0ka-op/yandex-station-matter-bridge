#!/bin/sh
# Controlled, time-bounded Matter HTTP API activation for Yandex Station Mini 2.
# This script is intentionally inert unless called with the exact approval token.

set -u

APPROVAL_TOKEN="I_APPROVE_MAIND_HTTP_RUNTIME_TEST"
RUN_ID="${MAIND_HTTP_RUN_ID:-}"
MATTER_NODE_ID="${MAIND_HTTP_NODE_ID:-}"
MATTER_ENDPOINT_ID="${MAIND_HTTP_ENDPOINT_ID:-}"
RUN_ROOT="/tmp/maind-http-runs"
LOCK_DIR="/tmp/maind-http-runtime.lock"
case "$RUN_ID" in ''|*[!A-Za-z0-9._-]*) echo "invalid or absent MAIND_HTTP_RUN_ID" >&2; exit 64;; esac
case "$MATTER_NODE_ID" in ''|*[!0-9]*) echo "invalid or absent MAIND_HTTP_NODE_ID" >&2; exit 64;; esac
case "$MATTER_ENDPOINT_ID" in ''|*[!0-9]*) echo "invalid or absent MAIND_HTTP_ENDPOINT_ID" >&2; exit 64;; esac
BASE="${MAIND_HTTP_BASE:-$RUN_ROOT/$RUN_ID}"
[ "$BASE" = "$RUN_ROOT/$RUN_ID" ] || { echo "MAIND_HTTP_BASE does not match run_id" >&2; exit 64; }
PATCH_SOURCE="$BASE/patches"
PATCH_MOUNT="/data/quasar/quasar_patches"
PATCH_NAME="quasar.cfg.platformd.patch"
EXPECTED_MAIND="7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1"
EXPECTED_LAUNCHER="e7af45d49ea9626c7bfc1d72c648663c82e024a8c9d538b0aa6f8317288f5054"
WATCHDOG_SECONDS_DEFAULT=360
PORT_HEX="223D"
GUARD4="INPUT ! -i lo -p tcp --dport 8765 -j REJECT --reject-with tcp-reset"
GUARD6="$GUARD4"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {
    line="$(now) $*"
    echo "$line"
    if [ -d "$BASE" ]; then echo "$line" >> "$BASE/experiment.log"; fi
}

fail() { log "ERROR $*"; return 1; }

preflight_refusal() {
    exit_code=$1 code=$2 stage=$3 condition=$4 changed=$5 action=$6 detail=$7
    log "MAIND_PREFLIGHT_REFUSAL|code=$code|stage=$stage|condition=$condition|system_changed=$changed|action=$action|detail=$detail"
    return "$exit_code"
}

missing_required_command() {
    for required in awk cat date flock grep head id ip iptables ip6tables iptables-save ip6tables-save kill mkdir mount nohup ps readlink rmdir sed setsid sha256sum sleep tr umount wc; do
        command -v "$required" >/dev/null 2>&1 || { echo "$required"; return 0; }
    done
    [ -x /usr/bin/wget ] || { echo /usr/bin/wget; return 0; }
    return 1
}

write_marker() { printf '%s\n' "$RUN_ID" > "$BASE/$1"; }
marker_is_ours() { [ -f "$BASE/$1" ] && [ "$(head -n 1 "$BASE/$1" 2>/dev/null)" = "$RUN_ID" ]; }
run_identity_valid() { [ -f "$BASE/run_id" ] && [ "$(cat "$BASE/run_id" 2>/dev/null)" = "$RUN_ID" ]; }
lock_is_ours() {
    [ -d "$LOCK_DIR" ] &&
    [ "$(cat "$LOCK_DIR/run_id" 2>/dev/null)" = "$RUN_ID" ] &&
    [ "$(cat "$LOCK_DIR/base" 2>/dev/null)" = "$BASE" ]
}
lock_description() {
    if [ ! -d "$LOCK_DIR" ]; then echo absent; return; fi
    printf 'run_id=%s base=%s owner_pid=%s phase=%s' \
        "$(cat "$LOCK_DIR/run_id" 2>/dev/null || echo unknown)" \
        "$(cat "$LOCK_DIR/base" 2>/dev/null || echo unknown)" \
        "$(cat "$LOCK_DIR/owner.pid" 2>/dev/null || echo unknown)" \
        "$(cat "$LOCK_DIR/phase" 2>/dev/null || echo unknown)"
}
acquire_global_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        if [ -d "$LOCK_DIR" ]; then
            preflight_refusal 76 PF_LOCK_RACE lifecycle global_lock no inspect_lock "$(lock_description)"
        else
            preflight_refusal 78 PF_LOCK_CREATE lifecycle global_lock no inspect_tmp_permissions mkdir_failed
        fi
        return $?
    fi
    umask 077
    if ! printf '%s\n' "$RUN_ID" > "$LOCK_DIR/run_id" ||
       ! printf '%s\n' "$BASE" > "$LOCK_DIR/base" ||
       ! printf '%s\n' "$$" > "$LOCK_DIR/owner.pid" ||
       ! printf '%s\n' arming > "$LOCK_DIR/phase"; then
        rm -f "$LOCK_DIR/run_id" "$LOCK_DIR/base" "$LOCK_DIR/owner.pid" "$LOCK_DIR/phase" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        preflight_refusal 79 PF_LOCK_WRITE lifecycle global_lock lock_directory_only inspect_tmp_storage write_failed
        return $?
    fi
    return 0
}
release_global_lock_if_owned() {
    lock_is_ours || return 0
    rm -f "$LOCK_DIR/run_id" "$LOCK_DIR/base" "$LOCK_DIR/owner.pid" "$LOCK_DIR/phase" || {
        log "MAIND_RUNTIME_FAILURE|code=RT_LOCK_RELEASE_FILES|stage=rollback|condition=global_lock_files|system_changed=yes|action=inspect_lock|detail=rm_failed"
        return 1
    }
    rmdir "$LOCK_DIR" 2>/dev/null || { log "global lock directory could not be removed"; return 1; }
}
legacy_state_present() { [ -e /tmp/maind-http-test ] || [ -e /tmp/maind-http-read-verify ]; }
experiment_workers() {
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        worker_cmd=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null || true)
        case "$worker_cmd" in
            *maind_http_runtime_test_remote*.sh\ watchdog*|*maind_http_runtime_test_remote*.sh\ rollback*)
                printf '%s:%s\n' "${p##*/}" "$worker_cmd"
                ;;
        esac
    done
}
lock_owner_state() {
    [ -d "$LOCK_DIR" ] || { echo absent; return; }
    owner=$(cat "$LOCK_DIR/owner.pid" 2>/dev/null || true)
    case "$owner" in ''|*[!0-9]*) echo stale_invalid_pid; return;; esac
    [ -d "/proc/$owner" ] || { echo stale_dead_pid; return; }
    owner_cmd=$(tr '\000' ' ' < "/proc/$owner/cmdline" 2>/dev/null || true)
    case "$owner_cmd" in
        *maind_http_runtime_test_remote*.sh\ watchdog*) echo active_watchdog ;;
        *) echo ambiguous_live_pid ;;
    esac
}
require_active_run() {
    run_identity_valid || { fail "active operation refused: run identity mismatch"; return 1; }
    lock_is_ours || { fail "active operation refused: lock ownership mismatch: $(lock_description)"; return 1; }
}
unresolved_run_state() {
    [ -d "$RUN_ROOT" ] || return 1
    for candidate in "$RUN_ROOT"/*; do
        [ -d "$candidate" ] || continue
        candidate_id=$(cat "$candidate/run_id" 2>/dev/null || true)
        [ -n "$candidate_id" ] || { echo "$candidate:missing_run_id"; return 0; }
        [ "$(cat "$candidate/completed" 2>/dev/null || true)" = "$candidate_id" ] || {
            echo "$candidate:incomplete"; return 0;
        }
    done
    return 1
}

listener_lines() {
    awk -v p=":$PORT_HEX" 'NR>1 && substr($2,length($2)-4)==p && $4=="0A" {print FILENAME,$2,$4,$10}' /proc/net/tcp /proc/net/tcp6
}

has_listener() { [ -n "$(listener_lines)" ]; }

canonical_path() { readlink -f "$1" 2>/dev/null; }

target_mount_signature() {
    target=$(canonical_path "$PATCH_MOUNT") || return 1
    awk -v target="$target" '
        $5 == target { signature=$3 "|" $4; count++ }
        END { if (count != 1) exit 1; print signature }
    ' /proc/self/mountinfo
}

source_mount_signature() {
    source=$(canonical_path "$PATCH_SOURCE") || return 1
    awk -v path="$source" '
        function contains(path, mountpoint) {
            return path == mountpoint || mountpoint == "/" || index(path, mountpoint "/") == 1
        }
        contains(path, $5) && length($5) > best {
            best=length($5); device=$3; root=$4; mountpoint=$5
        }
        END {
            if (!best) exit 1
            if (mountpoint == "/") relative=path
            else relative=substr(path, length(mountpoint) + 1)
            if (relative == "") expected=root
            else if (root == "/") expected=relative
            else expected=root relative
            print device "|" expected
        }
    ' /proc/self/mountinfo
}

mount_present() {
    target=$(canonical_path "$PATCH_MOUNT") || return 1
    awk -v target="$target" '$5 == target { found=1 } END { exit !found }' /proc/self/mountinfo
}

mount_verified() {
    source_signature=$(source_mount_signature) || return 1
    target_signature=$(target_mount_signature) || return 1
    {
        echo "source=$(canonical_path "$PATCH_SOURCE")"
        echo "target=$(canonical_path "$PATCH_MOUNT")"
        echo "source_signature=$source_signature"
        echo "target_signature=$target_signature"
    } > "$BASE/mount.verification"
    [ "$source_signature" = "$target_signature" ]
}

save_mount_diagnostics() {
    label=$1
    output="$BASE/mount-diagnostics.$(date +%s).$$.$label"
    {
        echo "timestamp=$(now)"
        echo "source_requested=$PATCH_SOURCE"
        echo "source_canonical=$(canonical_path "$PATCH_SOURCE" || true)"
        echo "target_requested=$PATCH_MOUNT"
        echo "target_canonical=$(canonical_path "$PATCH_MOUNT" || true)"
        echo "source_signature=$(source_mount_signature 2>/dev/null || true)"
        echo "target_signature=$(target_mount_signature 2>/dev/null || true)"
        echo "mountinfo:"
        cat /proc/self/mountinfo
        echo "mounts:"
        cat /proc/self/mounts
        echo "source_listing:"
        ls -la "$PATCH_SOURCE" 2>&1 || true
        echo "target_listing:"
        ls -la "$PATCH_MOUNT" 2>&1 || true
    } > "$output"
    log "mount diagnostics saved path=$output"
}

launcher_pid() {
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null || true)
        case "$c" in
            "/system/vendor/quasar/quasar_launcher2 /system/vendor/quasar/launch.json "*) echo "${p##*/}"; return 0 ;;
        esac
    done
    return 1
}

platformd_pid() {
    lp=$(launcher_pid) || return 1
    found=""
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null || true)
        [ "$c" = "/system/vendor/quasar/maind --platformd " ] || continue
        pp=$(awk '/^PPid:/{print $2}' "$p/status")
        [ "$pp" = "$lp" ] || continue
        [ -z "$found" ] || return 2
        found="${p##*/}"
    done
    [ -n "$found" ] || return 1
    echo "$found"
}

verify_binary() {
    path=$1 expected=$2
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ] || fail "SHA mismatch: $path expected=$expected actual=$actual"
}

guard4_present() { iptables -C $GUARD4 >/dev/null 2>&1; }
guard6_present() { ip6tables -C $GUARD6 >/dev/null 2>&1; }

install_guards() {
    if ! guard4_present; then
        # Record ownership intent before inserting the rule. If marker I/O is
        # unavailable, no firewall mutation is attempted. If insertion fails,
        # remove the intent marker immediately.
        write_marker guard4.owned || return 1
        iptables -I $GUARD4 || { rm -f "$BASE/guard4.owned"; return 1; }
    fi
    if ! guard6_present; then
        write_marker guard6.owned || return 1
        ip6tables -I $GUARD6 || { rm -f "$BASE/guard6.owned"; return 1; }
    fi
    guard4_present && guard6_present || return 1
    write_marker guards.installed || return 1
    log "firewall guards installed before listener"
}

remove_guards_if_safe() {
    if has_listener; then
        log "guard retained: listener still present"
        return 1
    fi
    if marker_is_ours guard4.owned && guard4_present; then
        iptables -D $GUARD4 || { log "MAIND_RUNTIME_FAILURE|code=RT_IPV4_GUARD_REMOVE|stage=rollback|condition=firewall_ipv4|system_changed=yes|action=retain_markers_and_inspect|detail=iptables_delete_failed"; return 1; }
    fi
    if marker_is_ours guard6.owned && guard6_present; then
        ip6tables -D $GUARD6 || { log "MAIND_RUNTIME_FAILURE|code=RT_IPV6_GUARD_REMOVE|stage=rollback|condition=firewall_ipv6|system_changed=yes|action=retain_markers_and_inspect|detail=ip6tables_delete_failed"; return 1; }
    fi
    rm -f "$BASE/guard4.owned" "$BASE/guard6.owned" "$BASE/guards.installed" || return 1
    log "firewall guards removed after listener absence"
}

wait_for_new_platformd() {
    old=$1 limit=$2
    end=$(( $(date +%s) + limit ))
    while [ "$(date +%s)" -lt "$end" ]; do
        p=$(platformd_pid 2>/dev/null || true)
        if [ -n "$p" ] && [ "$p" != "$old" ]; then echo "$p"; return 0; fi
        sleep 1
    done
    return 1
}

wait_listener_state() {
    wanted=$1 limit=$2
    end=$(( $(date +%s) + limit ))
    while [ "$(date +%s)" -lt "$end" ]; do
        if [ "$wanted" = present ] && has_listener; then return 0; fi
        if [ "$wanted" = absent ] && ! has_listener; then return 0; fi
        sleep 1
    done
    return 1
}

health_snapshot() {
    label=$1
    {
        echo "timestamp=$(now)"
        echo "label=$label"
        echo "launcher_pid=$(launcher_pid 2>/dev/null || true)"
        echo "platformd_pid=$(platformd_pid 2>/dev/null || true)"
        echo "listeners:"
        listener_lines
        echo "memory:"
        awk '/MemTotal:|MemAvailable:|SwapTotal:|SwapFree:/{print}' /proc/meminfo
        echo "lamp_neighbor:"
        echo "lamp_neighbor=not_collected"
        echo "maind_roles:"
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue
            c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null || true)
            case "$c" in /system/vendor/quasar/maind*) echo "${p##*/} $c";; esac
        done
    } > "$BASE/$label.snapshot"
}

watchdog_selftest() {
    probe="$BASE/watchdog.selftest.ok"
    rm -f "$probe"
    setsid nohup sh -c 'sleep 2; printf "%s\n" detached-ok > "$1"' sh "$probe" \
        > "$BASE/watchdog.selftest.stdout" 2>&1 < /dev/null &
    probe_pid=$!
    sleep 1
    kill -0 "$probe_pid" 2>/dev/null || { log "watchdog self-test process did not detach"; return 1; }
    end=$(( $(date +%s) + 8 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        [ "$(cat "$probe" 2>/dev/null || true)" = detached-ok ] && { log "watchdog detached self-test passed"; return 0; }
        sleep 1
    done
    log "watchdog detached self-test timed out"
    return 1
}

arm_control_restore() {
    token=$1 state=$2
    require_active_run || return 1
    [ "$token" = "I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE" ] || return 1
    case "$state" in 0|1) ;; *) return 1 ;; esac
    printf '%s\n' "$state" > "$BASE/control.restore.state"
    : > "$BASE/control.restore.armed"
    log "control restoration armed original_state=$state"
}

clear_control_restore() {
    require_active_run || return 1
    rm -f "$BASE/control.restore.armed"
    : > "$BASE/control.restore.verified"
    log "control restoration verified and disarmed"
}

restore_control_if_armed() {
    [ -f "$BASE/control.restore.armed" ] || return 0
    state=$(cat "$BASE/control.restore.state" 2>/dev/null || true)
    case "$state" in 0) raw='0x08' ;; 1) raw='0x09' ;; *)
        log "control restoration invalid saved state"
        : > "$BASE/CONTROL_STATE_MAY_BE_CHANGED"
        return 1
    esac
    if ! has_listener; then
        log "control restoration unavailable: HTTP listener absent"
        : > "$BASE/CONTROL_STATE_MAY_BE_CHANGED"
        return 1
    fi
    invoke_body="$BASE/watchdog.restore.invoke.body"
    read_body="$BASE/watchdog.restore.read.body"
    invoke_json=$(printf '{"nodeId":%s,"endpointId":%s,"clusterId":6,"commandId":%s,"fields":{}}' "$MATTER_NODE_ID" "$MATTER_ENDPOINT_ID" "$state")
    read_json=$(printf '{"nodeId":%s,"endpointId":%s,"clusterId":6,"attributeId":0}' "$MATTER_NODE_ID" "$MATTER_ENDPOINT_ID")
    /usr/bin/wget -Y off -S -T 20 -O "$invoke_body" \
        --header='Content-Type: application/json' --post-data="$invoke_json" \
        'http://127.0.0.1:8765/interaction/invokeCommand' \
        > "$BASE/watchdog.restore.invoke.stdout" 2> "$BASE/watchdog.restore.invoke.stderr" || {
            log "control restoration invoke failed"
            : > "$BASE/CONTROL_STATE_MAY_BE_CHANGED"
            return 1
        }
    /usr/bin/wget -Y off -S -T 20 -O "$read_body" \
        --header='Content-Type: application/json' --post-data="$read_json" \
        'http://127.0.0.1:8765/interaction/readAttribute' \
        > "$BASE/watchdog.restore.read.stdout" 2> "$BASE/watchdog.restore.read.stderr" || {
            log "control restoration readback failed"
            : > "$BASE/CONTROL_STATE_MAY_BE_CHANGED"
            return 1
        }
    grep -Eq '"errors"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$read_body" &&
    grep -Eq '"endpointId"[[:space:]]*:[[:space:]]*1' "$read_body" &&
    grep -Eq '"clusterId"[[:space:]]*:[[:space:]]*6' "$read_body" &&
    grep -Eq '"attributeId"[[:space:]]*:[[:space:]]*0' "$read_body" &&
    grep -Eq "\"rawValue\"[[:space:]]*:[[:space:]]*\"$raw\"" "$read_body" || {
        log "control restoration readback mismatch expected=$raw"
        : > "$BASE/CONTROL_STATE_MAY_BE_CHANGED"
        return 1
    }
    rm -f "$BASE/control.restore.armed" "$BASE/CONTROL_STATE_MAY_BE_CHANGED"
    : > "$BASE/control.restore.verified"
    log "control restoration completed and verified original_state=$state"
    return 0
}

arm_light_restore() {
    token=$1 mode=$2 onoff=$3 onoff_raw=$4 level=$5 level_raw=$6
    color_mode=$7 color_mode_raw=$8 hue=$9
    shift 9
    hue_raw=$1 saturation=$2 saturation_raw=$3
    require_active_run || return 1
    [ "$token" = "I_APPROVE_LIGHT_STATE_RESTORE" ] || return 1
    case "$mode" in brightness|color) ;; *) return 1 ;; esac
    case "$onoff" in 0|1) ;; *) return 1 ;; esac
    case "$level:$color_mode:$hue:$saturation" in *[!0-9:-]*) return 1 ;; esac
    for raw in "$onoff_raw" "$level_raw" "$color_mode_raw" "$hue_raw" "$saturation_raw"; do
        case "$raw" in -|0x[0-9a-fA-F][0-9a-fA-F]*) ;; *) return 1 ;; esac
    done
    {
        echo "mode=$mode"; echo "onoff=$onoff"; echo "onoff_raw=$onoff_raw"
        echo "level=$level"; echo "level_raw=$level_raw"
        echo "color_mode=$color_mode"; echo "color_mode_raw=$color_mode_raw"
        echo "hue=$hue"; echo "hue_raw=$hue_raw"
        echo "saturation=$saturation"; echo "saturation_raw=$saturation_raw"
    } > "$BASE/light.restore.state"
    : > "$BASE/light.restore.armed"
    log "light restoration armed mode=$mode"
}

clear_light_restore() {
    token=$1 expected_onoff_raw=$2 expected_level_raw=$3
    require_active_run || return 1
    [ "$token" = "I_CONFIRM_LIGHT_RESTORE_READBACK" ] || return 1
    [ -f "$BASE/light.restore.armed" ] || return 1
    watchdog_read_raw light.clear.verify.level 8 0 "$expected_level_raw" || {
        : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1;
    }
    watchdog_read_raw light.clear.verify.onoff 6 0 "$expected_onoff_raw" || {
        : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1;
    }
    rm -f "$BASE/light.restore.armed"
    rm -f "$BASE/LIGHT_STATE_MAY_BE_CHANGED"
    : > "$BASE/light.restore.verified"
    log "light restoration verified and disarmed"
}

state_value() { sed -n "s/^$1=//p" "$BASE/light.restore.state" | head -n 1; }

watchdog_http_post() {
    name=$1 path=$2 json=$3
    /usr/bin/wget -Y off -S -T 20 -O "$BASE/watchdog.$name.body" \
        --header='Content-Type: application/json' --post-data="$json" \
        "http://127.0.0.1:8765$path" \
        > "$BASE/watchdog.$name.stdout" 2> "$BASE/watchdog.$name.stderr"
}

watchdog_invoke() {
    name=$1 json=$2
    watchdog_http_post "$name" /interaction/invokeCommand "$json" || return 1
    body="$BASE/watchdog.$name.body"
    if grep -Eq '"errors"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^]]' "$body"; then
        return 1
    fi
    grep -Eq '"responses"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' "$body" &&
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"[^"]*Success"' "$body"
}

watchdog_read_raw() {
    name=$1 cluster=$2 attribute=$3 expected=$4
    json=$(printf '{"nodeId":%s,"endpointId":%s,"clusterId":%s,"attributeId":%s}' "$MATTER_NODE_ID" "$MATTER_ENDPOINT_ID" "$cluster" "$attribute")
    watchdog_http_post "$name" /interaction/readAttribute "$json" || return 1
    grep -Eq '"errors"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$BASE/watchdog.$name.body" &&
    grep -Eq '"endpointId"[[:space:]]*:[[:space:]]*1' "$BASE/watchdog.$name.body" &&
    grep -Eq "\"clusterId\"[[:space:]]*:[[:space:]]*$cluster" "$BASE/watchdog.$name.body" &&
    grep -Eq "\"attributeId\"[[:space:]]*:[[:space:]]*$attribute" "$BASE/watchdog.$name.body" &&
    grep -Eq "\"rawValue\"[[:space:]]*:[[:space:]]*\"$expected\"" "$BASE/watchdog.$name.body"
}

restore_light_if_armed() {
    require_active_run || return 1
    [ -f "$BASE/light.restore.armed" ] || return 0
    mode=$(state_value mode); onoff=$(state_value onoff); onoff_raw=$(state_value onoff_raw)
    level=$(state_value level); level_raw=$(state_value level_raw)
    color_mode=$(state_value color_mode); color_mode_raw=$(state_value color_mode_raw)
    hue=$(state_value hue); hue_raw=$(state_value hue_raw)
    saturation=$(state_value saturation); saturation_raw=$(state_value saturation_raw)
    if ! has_listener; then
        log "light restoration unavailable: HTTP listener absent"
        : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1
    fi
    level_json=$(printf '{"nodeId":%s,"endpointId":%s,"clusterId":8,"commandId":0,"fields":{"level":%s,"transitionTime":5,"optionsMask":0,"optionsOverride":0}}' "$MATTER_NODE_ID" "$MATTER_ENDPOINT_ID" "$level")
    watchdog_invoke light.restore.level "$level_json" || { : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1; }
    sleep 2
    watchdog_read_raw light.verify.level 8 0 "$level_raw" || { : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1; }
    if [ "$mode" = color ]; then
        [ "$color_mode" = 0 ] || { : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1; }
        color_json=$(printf '{"nodeId":%s,"endpointId":%s,"clusterId":768,"commandId":6,"fields":{"hue":%s,"saturation":%s,"transitionTime":5,"optionsMask":0,"optionsOverride":0}}' "$MATTER_NODE_ID" "$MATTER_ENDPOINT_ID" "$hue" "$saturation")
        watchdog_invoke light.restore.color "$color_json" || { : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1; }
        sleep 2
        watchdog_read_raw light.verify.mode 768 8 "$color_mode_raw" &&
        watchdog_read_raw light.verify.hue 768 0 "$hue_raw" &&
        watchdog_read_raw light.verify.saturation 768 1 "$saturation_raw" || {
            : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1;
        }
    fi
    onoff_json=$(printf '{"nodeId":%s,"endpointId":%s,"clusterId":6,"commandId":%s,"fields":{}}' "$MATTER_NODE_ID" "$MATTER_ENDPOINT_ID" "$onoff")
    watchdog_invoke light.restore.onoff "$onoff_json" || { : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1; }
    sleep 1
    watchdog_read_raw light.verify.onoff 6 0 "$onoff_raw" || { : > "$BASE/LIGHT_STATE_MAY_BE_CHANGED"; return 1; }
    rm -f "$BASE/light.restore.armed" "$BASE/LIGHT_STATE_MAY_BE_CHANGED"
    : > "$BASE/light.restore.verified"
    log "light restoration completed and verified mode=$mode"
}

do_rollback_locked() {
    reason=$1
    log "rollback begin reason=$reason"

    if marker_is_ours completed && clean_state; then
        log "rollback already_clean reason=$reason"
        release_global_lock_if_owned || true
        return 0
    fi
    lock_is_ours || { fail "rollback refused: global lock is not owned by run $RUN_ID: $(lock_description)"; return 1; }
    rm -f "$BASE/completed" || return 1
    printf '%s\n' rollback > "$LOCK_DIR/phase" || {
        log "MAIND_RUNTIME_FAILURE|code=RT_ROLLBACK_PHASE|stage=rollback|condition=global_lock_phase|system_changed=yes|action=inspect_lock|detail=write_failed"
        return 1
    }
    save_mount_diagnostics "rollback-$reason"

    # If a control command may have been sent, restoration must be attempted
    # while the HTTP API and Matter connector are still available.
    restore_control_if_armed || log "rollback continuing with possible changed lamp state"
    restore_light_if_armed || log "rollback continuing with possible changed light state"

    # Remove every state file from the tmpfs projection before restarting.
    rm -f "$PATCH_MOUNT/quasar.cfg.platformd.patch" \
          "$PATCH_MOUNT/quasar.cfg.platformd.dirty" \
          "$PATCH_MOUNT/quasar.cfg.platformd.tag" 2>/dev/null || true

    # Never restart platformd when arm() failed before crossing this run's
    # activation boundary. An unrelated/stale listener is not proof that this
    # run changed platformd and must not broaden rollback ownership.
    if marker_is_ours activation.started; then
        old=$(platformd_pid 2>/dev/null || true)
        if [ -n "$old" ]; then
            log "rollback SIGTERM platformd pid=$old"
            kill -TERM "$old" || log "rollback SIGTERM failed pid=$old"
            new=$(wait_for_new_platformd "$old" 180 2>/dev/null || true)
            [ -n "$new" ] && log "rollback platformd restored pid=$new" || log "rollback platformd restore timeout"
        else
            log "rollback found no platformd; launcher must recover it"
        fi
    else
        log "rollback before activation boundary: platformd lifecycle skipped"
    fi

    if ! wait_listener_state absent 120; then
        log "rollback incomplete: listener remains; firewall guards intentionally retained"
        return 1
    fi

    if marker_is_ours mountpoint.created && mount_present; then
        canonical_target=$(canonical_path "$PATCH_MOUNT") || { log "cannot canonicalize mounted target; guards retained"; return 1; }
        umount "$canonical_target" || { log "umount failed target=$canonical_target; guards retained"; return 1; }
    fi
    if marker_is_ours mountpoint.created && [ -e "$PATCH_MOUNT" ]; then
        rmdir "$PATCH_MOUNT" || { log "temporary mountpoint removal failed; guards retained"; return 1; }
    fi

    health_snapshot after_rollback || {
        log "MAIND_RUNTIME_FAILURE|code=RT_POSTFLIGHT_SNAPSHOT|stage=rollback|condition=health_snapshot|system_changed=yes|action=preserve_run_and_inspect|detail=after_rollback_snapshot_failed"
        return 1
    }
    remove_guards_if_safe || return 1
    if ! clean_state; then
        log "MAIND_RUNTIME_FAILURE|code=RT_FINAL_CLEAN_STATE|stage=rollback|condition=verify_clean|system_changed=yes|action=preserve_run_lock_and_inspect|detail=listener_guard_mount_patch_or_platformd_not_clean"
        return 1
    fi
    write_marker completed || {
        log "MAIND_RUNTIME_FAILURE|code=RT_COMPLETED_MARKER|stage=rollback|condition=completion_marker|system_changed=yes|action=preserve_run_lock_and_inspect|detail=write_failed"
        return 1
    }
    log "rollback complete"
    release_global_lock_if_owned || return 1
    return 0
}

do_rollback() {
    run_identity_valid || { fail "rollback refused: run identity is absent or mismatched"; return 1; }
    exec 9>"$BASE/rollback.lock" || { fail "rollback lock file could not be opened"; return 1; }
    flock -x 9 || { fail "rollback lock could not be acquired"; return 1; }
    printf '%s\n' "$RUN_ID" >&9 || { fail "rollback lock identity could not be written"; return 1; }
    do_rollback_locked "$1"
}

clean_state() {
    ! has_listener &&
    ! guard4_present &&
    ! guard6_present &&
    ! mount_present &&
    [ ! -e "$PATCH_MOUNT" ] &&
    platformd_pid >/dev/null 2>&1
}

watchdog() {
    run_identity_valid || { fail "watchdog run identity mismatch"; return 1; }
    lock_is_ours || { fail "watchdog global lock ownership mismatch: $(lock_description)"; return 1; }
    watchdog_seconds=$(cat "$BASE/watchdog.seconds" 2>/dev/null || echo "$WATCHDOG_SECONDS_DEFAULT")
    deadline=$(( $(date +%s) + watchdog_seconds ))
    log "watchdog armed pid=$$ deadline_epoch=$deadline"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        run_identity_valid || { fail "watchdog run identity changed"; return 1; }
        marker_is_ours completed && { log "watchdog observed completed for run_id=$RUN_ID"; return 0; }
        lock_is_ours || { fail "watchdog lost global lock ownership: $(lock_description)"; return 1; }
        if marker_is_ours rollback.request; then do_rollback requested; return $?; fi
        sleep 2
    done
    do_rollback timeout
}

validate_station_preflight() {
    changed=${1:-no}
    [ "$(id -u)" = 0 ] || { preflight_refusal 81 PF_NOT_ROOT station identity "$changed" run_as_root uid_not_zero; return $?; }
    verify_binary /system/vendor/quasar/maind "$EXPECTED_MAIND" || {
        preflight_refusal 82 PF_MAIND_HASH station binary_identity "$changed" refresh_offline_analysis maind_sha256_mismatch; return $?;
    }
    verify_binary /system/vendor/quasar/quasar_launcher2 "$EXPECTED_LAUNCHER" || {
        preflight_refusal 83 PF_LAUNCHER_HASH station binary_identity "$changed" refresh_offline_analysis launcher_sha256_mismatch; return $?;
    }
    [ -z "$(listener_lines)" ] || { preflight_refusal 84 PF_LISTENER_PRESENT station tcp_8765 "$changed" inspect_listener listener_already_active; return $?; }
    ! guard4_present || { preflight_refusal 85 PF_IPV4_GUARD_PRESENT station firewall_ipv4 "$changed" inspect_firewall matching_rule_exists; return $?; }
    ! guard6_present || { preflight_refusal 86 PF_IPV6_GUARD_PRESENT station firewall_ipv6 "$changed" inspect_firewall matching_rule_exists; return $?; }
    platformd_pid >/dev/null || { preflight_refusal 87 PF_PLATFORMD_IDENTITY station supervised_platformd "$changed" inspect_supervisor not_exactly_one_child; return $?; }
    available=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
    case "$available" in ''|*[!0-9]*) preflight_refusal 88 PF_MEMORY_UNKNOWN station memory "$changed" inspect_proc_meminfo missing_memavailable; return $?;; esac
    [ "$available" -ge 70000 ] || { preflight_refusal 89 PF_MEMORY_LOW station memory "$changed" free_memory "memavailable_kb=$available"; return $?; }
    [ ! -e "$PATCH_MOUNT" ] || { preflight_refusal 90 PF_PATCH_PATH_PRESENT station patch_mount_path "$changed" inspect_patch_path "$PATCH_MOUNT"; return $?; }
    return 0
}

validate_start_state() {
    changed=${1:-no}
    [ ! -e /tmp/maind-http-test ] || { preflight_refusal 71 PF_LEGACY_HTTP_TEST lifecycle legacy_http_test "$changed" archive_then_point_cleanup /tmp/maind-http-test; return $?; }
    [ ! -e /tmp/maind-http-read-verify ] || { preflight_refusal 72 PF_LEGACY_READ_VERIFY lifecycle legacy_read_verify "$changed" archive_then_point_cleanup /tmp/maind-http-read-verify; return $?; }
    workers=$(experiment_workers)
    [ -z "$workers" ] || { preflight_refusal 73 PF_EXPERIMENT_WORKER lifecycle experiment_worker "$changed" inspect_worker "$workers"; return $?; }
    unresolved=$(unresolved_run_state || true)
    [ -z "$unresolved" ] || { preflight_refusal 74 PF_UNRESOLVED_RUN lifecycle per_run_state "$changed" inspect_and_recover "$unresolved"; return $?; }
    [ ! -e "$BASE" ] || { preflight_refusal 75 PF_RUN_BASE_EXISTS lifecycle requested_run_base "$changed" inspect_run_base "$BASE"; return $?; }
    if [ -d "$LOCK_DIR" ]; then
        owner_state=$(lock_owner_state)
        case "$owner_state" in
            active_watchdog) refusal_code=PF_LOCK_ACTIVE ;;
            *) refusal_code=PF_LOCK_STALE_OR_AMBIGUOUS ;;
        esac
        preflight_refusal 76 "$refusal_code" lifecycle global_lock "$changed" inspect_lock "state=$owner_state $(lock_description)"; return $?
    fi
    return 0
}

preflight() {
    token=$1
    [ "$token" = "$APPROVAL_TOKEN" ] || { preflight_refusal 65 PF_APPROVAL_TOKEN authorization token no provide_exact_token mismatch; return $?; }
    missing=$(missing_required_command || true)
    [ -z "$missing" ] || { preflight_refusal 70 PF_MISSING_UTILITY environment dependency no install_or_restore_utility "$missing"; return $?; }
    validate_start_state no || return $?
    validate_station_preflight no || return $?
    echo "preflight=clean run_id=$RUN_ID base=$BASE"
    return 0
}

arm() {
    token=$1
    watchdog_seconds=${2:-$WATCHDOG_SECONDS_DEFAULT}
    [ "$token" = "$APPROVAL_TOKEN" ] || { preflight_refusal 65 PF_APPROVAL_TOKEN authorization token no provide_exact_token mismatch; return $?; }
    case "$watchdog_seconds" in ''|*[!0-9]*) preflight_refusal 66 PF_WATCHDOG_SECONDS input watchdog_seconds no use_range_120_3600 invalid; return $?;; esac
    [ "$watchdog_seconds" -ge 120 ] && [ "$watchdog_seconds" -le 3600 ] || { preflight_refusal 66 PF_WATCHDOG_SECONDS input watchdog_seconds no use_range_120_3600 "$watchdog_seconds"; return $?; }
    missing=$(missing_required_command || true)
    [ -z "$missing" ] || { preflight_refusal 70 PF_MISSING_UTILITY environment dependency no install_or_restore_utility "$missing"; return $?; }
    validate_start_state no || return $?
    acquire_global_lock || return 1
    unresolved=$(unresolved_run_state || true)
    workers=$(experiment_workers)
    if legacy_state_present || [ -e "$BASE" ] || [ -n "$unresolved" ] || [ -n "$workers" ]; then
        preflight_refusal 77 PF_STATE_RACE lifecycle state_changed_after_lock lock_only inspect_concurrent_state "unresolved=${unresolved:-none} workers=${workers:-none}"
        refusal_status=$?
        release_global_lock_if_owned || true
        return "$refusal_status"
    fi
    umask 077
    mkdir -p "$RUN_ROOT" || {
        preflight_refusal 91 PF_RUN_ROOT_CREATE arming run_root lock_only inspect_tmp_storage "$RUN_ROOT"
        status=$?; release_global_lock_if_owned || true; return "$status";
    }
    mkdir "$BASE" || {
        preflight_refusal 92 PF_RUN_BASE_CREATE arming run_base lock_only inspect_run_root "$BASE"
        status=$?; release_global_lock_if_owned || true; return "$status";
    }
    if ! printf '%s\n' "$RUN_ID" > "$BASE/run_id"; then
        preflight_refusal 93 PF_RUN_ID_WRITE arming run_identity run_directory_only inspect_tmp_storage "$BASE/run_id"
        status=$?; rmdir "$BASE" 2>/dev/null || true; release_global_lock_if_owned || true; return "$status"
    fi
    if ! mkdir "$BASE/patches"; then
        preflight_refusal 94 PF_PATCH_SOURCE_CREATE arming patch_source run_directory_only inspect_tmp_storage "$BASE/patches"
        status=$?; rm -f "$BASE/run_id"; rmdir "$BASE" 2>/dev/null || true; release_global_lock_if_owned || true; return "$status"
    fi
    validate_station_preflight run_state_only
    validation_status=$?
    if [ "$validation_status" -ne 0 ]; then
        write_marker preflight.failed
        release_global_lock_if_owned || true
        return "$validation_status"
    fi
    printf '%s\n' "$watchdog_seconds" > "$BASE/watchdog.seconds" || { do_rollback watchdog_deadline_write_failure; return 1; }
    printf '%s\n' '{"matter":{"httpControl":{"enabled":true}}}' > "$PATCH_SOURCE/$PATCH_NAME" || { do_rollback patch_write_failure; return 1; }
    sha256sum "$PATCH_SOURCE/$PATCH_NAME" > "$BASE/patch.sha256" || { do_rollback patch_hash_failure; return 1; }
    iptables-save > "$BASE/iptables.before" || { do_rollback ipv4_snapshot_failure; return 1; }
    ip6tables-save > "$BASE/ip6tables.before" || { do_rollback ipv6_snapshot_failure; return 1; }
    health_snapshot before || { do_rollback health_snapshot_failure; return 1; }

    # Harmless target-side proof: tmpfs marker only, before firewall/mount/patch visibility/SIGTERM.
    if ! watchdog_selftest; then
        write_marker preflight.failed || true
        do_rollback watchdog_selftest_failure
        return 1
    fi

    install_guards || { log "cannot establish both guards"; do_rollback guard_install_failure; return 1; }
    # As with firewall ownership, persist intent before filesystem mutation so
    # rollback can safely remove a directory even if later I/O fails.
    write_marker mountpoint.created || { do_rollback mountpoint_marker_failure; return 1; }
    mkdir "$PATCH_MOUNT" || {
        rm -f "$BASE/mountpoint.created" || true
        log "cannot create empty mountpoint"; do_rollback mountpoint_create_failure; return 1
    }
    mount -o bind "$PATCH_SOURCE" "$PATCH_MOUNT" || { log "bind mount failed"; save_mount_diagnostics mount_failure; do_rollback mount_failure; return 1; }
    mount_verified || { save_mount_diagnostics mount_verification_failure; do_rollback mount_verification_failure; return 1; }
    [ -r "$PATCH_MOUNT/$PATCH_NAME" ] || { do_rollback patch_projection_failure; return 1; }

    setsid nohup "$0" watchdog > "$BASE/watchdog.stdout" 2>&1 < /dev/null &
    wpid=$!
    { echo "$RUN_ID"; echo "$wpid"; } > "$BASE/watchdog.pid" || { do_rollback watchdog_pid_write_failure; return 1; }
    printf '%s\n' "$wpid" > "$LOCK_DIR/owner.pid" || { do_rollback lock_owner_update_failure; return 1; }
    printf '%s\n' watchdog > "$LOCK_DIR/phase" || { do_rollback lock_phase_update_failure; return 1; }
    sleep 1
    kill -0 "$wpid" 2>/dev/null || { do_rollback watchdog_start_failure; return 1; }
    log "watchdog verified pid=$wpid"

    # Re-resolve immediately before signaling to avoid PID reuse.
    old=$(platformd_pid) || { do_rollback platformd_resolution_failure; return 1; }
    echo "$old" > "$BASE/platformd.before.pid" || { do_rollback platformd_pid_snapshot_failure; return 1; }
    write_marker activation.started || { do_rollback activation_marker_failure; return 1; }
    printf '%s\n' activating > "$LOCK_DIR/phase" || { do_rollback lock_phase_activation_failure; return 1; }
    log "activation SIGTERM platformd pid=$old"
    kill -TERM "$old" || { do_rollback activation_signal_failure; return 1; }
    new=$(wait_for_new_platformd "$old" 180 2>/dev/null || true)
    [ -n "$new" ] || { do_rollback activation_restart_timeout; return 1; }
    echo "$new" > "$BASE/platformd.active.pid" || { do_rollback platformd_active_pid_write_failure; return 1; }
    log "activation platformd restored pid=$new"
    wait_listener_state present 120 || { do_rollback listener_start_timeout; return 1; }
    { echo "run_id=$RUN_ID"; listener_lines; } > "$BASE/listener.active" || { do_rollback listener_marker_failure; return 1; }
    printf '%s\n' active > "$LOCK_DIR/phase" || { do_rollback lock_phase_active_failure; return 1; }
    health_snapshot active || { do_rollback active_health_snapshot_failure; return 1; }
    log "ACTIVATED platformd_pid=$new watchdog_pid=$wpid"
}

status() {
    echo "timestamp=$(now)"
    echo "run_id=$RUN_ID"
    echo "base=$BASE"
    echo "global_lock=$(lock_description)"
    echo "platformd_pid=$(platformd_pid 2>/dev/null || true)"
    echo "watchdog_pid=$(sed -n '2p' "$BASE/watchdog.pid" 2>/dev/null || true)"
    echo "completed=$(marker_is_ours completed && echo yes || echo no)"
    echo "listeners:"
    listener_lines
    echo "guard4=$(guard4_present && echo yes || echo no)"
    echo "guard6=$(guard6_present && echo yes || echo no)"
    echo "patch_mount=$(mount_present && echo yes || echo no)"
    echo "patch_mount_path=$([ -e "$PATCH_MOUNT" ] && echo present || echo absent)"
}

verify_clean() {
    run_identity_valid || { fail "run identity is absent or mismatched"; return 1; }
    marker_is_ours completed || { fail "rollback completion marker absent or belongs to another run"; return 1; }
    ! has_listener || { fail "port 8765 listener remains"; return 1; }
    ! guard4_present || { fail "IPv4 guard remains"; return 1; }
    ! guard6_present || { fail "IPv6 guard remains"; return 1; }
    ! mount_present || { fail "patch bind mount remains"; return 1; }
    [ ! -e "$PATCH_MOUNT" ] || { fail "temporary patch mountpoint remains"; return 1; }
    platformd_pid >/dev/null || { fail "supervised platformd not healthy"; return 1; }
    [ ! -d "$LOCK_DIR" ] || { fail "global experiment lock remains: $(lock_description)"; return 1; }
    log "rollback clean-state verification passed"
}

http_diagnostics() {
    label=${1:-manual}
    run_identity_valid || { fail "http diagnostics refused: run identity mismatch"; return 1; }
    output="$BASE/http-diagnostics.$(date +%s).$$.$label"
    pid=$(platformd_pid 2>/dev/null || true)
    {
        echo "timestamp=$(now)"
        echo "label=$label"
        echo "platformd_pid=$pid"
        echo "listeners:"
        listener_lines
        echo "listener_proc_rows:"
        awk -v p=":$PORT_HEX" 'NR == 1 || (substr($2,length($2)-4)==p)' /proc/net/tcp /proc/net/tcp6
        echo "platformd_status:"
        [ -n "$pid" ] && cat "/proc/$pid/status" 2>/dev/null || true
        echo "lamp_neighbor:"
        echo "lamp_neighbor=not_collected"
        echo "guards:"
        echo "guard4=$(guard4_present && echo yes || echo no)"
        echo "guard6=$(guard6_present && echo yes || echo no)"
    } > "$output"
    echo "$output"
}

case "${1:-}" in
    preflight) preflight "${2:-}" ;;
    arm) arm "${2:-}" "${3:-}" ;;
    watchdog) watchdog ;;
    rollback) do_rollback "${2:-manual}" ;;
    status) status ;;
    verify-clean) verify_clean ;;
    http-diagnostics) http_diagnostics "${2:-manual}" ;;
    control-restore-arm) arm_control_restore "${2:-}" "${3:-}" ;;
    control-restore-clear) clear_control_restore ;;
    light-restore-arm) shift; arm_light_restore "$@" ;;
    light-restore-clear) shift; clear_light_restore "$@" ;;
    light-restore-now) restore_light_if_armed ;;
    *) echo "usage: $0 {preflight TOKEN|arm TOKEN [watchdog-seconds]|watchdog|rollback [reason]|status|verify-clean|http-diagnostics [label]|control-restore-arm TOKEN STATE|control-restore-clear|light-restore-arm ...|light-restore-clear}" >&2; exit 64 ;;
esac
