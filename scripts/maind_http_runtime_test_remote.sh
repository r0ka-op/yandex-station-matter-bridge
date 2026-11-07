#!/bin/sh
# Controlled, time-bounded Matter HTTP API activation for Yandex Station Mini 2.
# This script is intentionally inert unless called with the exact approval token.

set -u

# Community review snapshot: the bundled lifecycle predates the verified run_id fix.
# Fail closed for all actions that could mutate the station or a paired device.
# To restore hardware execution, replace this helper AND its calling controllers
# with a matching, re-audited version from the current research tree.
case "${1:-}" in
    arm|watchdog|rollback|control-restore-*|light-restore-*)
        printf '%s\n' 'REVIEW_BUNDLE_RUNTIME_DISABLED: legacy lifecycle code; use the current verified research version' >&2
        exit 78
        ;;
esac

APPROVAL_TOKEN="I_APPROVE_MAIND_HTTP_RUNTIME_TEST"
BASE="${MAIND_HTTP_BASE:-/tmp/maind-http-test}"
MATTER_NODE_ID="${MAIND_MATTER_NODE_ID:?MAIND_MATTER_NODE_ID is required}"
MATTER_ENDPOINT_ID="${MAIND_MATTER_ENDPOINT_ID:?MAIND_MATTER_ENDPOINT_ID is required}"
case "$MATTER_NODE_ID:$MATTER_ENDPOINT_ID" in
    *[!0-9:]*|:*|*:) echo "invalid Matter target" >&2; exit 64 ;;
esac
case "$BASE" in
    /tmp/maind-http-test|/tmp/maind-http-read-verify) ;;
    *) echo "unsupported MAIND_HTTP_BASE" >&2; exit 64 ;;
esac
PATCH_SOURCE="$BASE/patches"
PATCH_MOUNT="/data/quasar/quasar_patches"
PATCH_NAME="quasar.cfg.platformd.patch"
EXPECTED_MAIND="7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1"
EXPECTED_LAUNCHER="e7af45d49ea9626c7bfc1d72c648663c82e024a8c9d538b0aa6f8317288f5054"
WATCHDOG_SECONDS=360
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
    guard4_present || iptables -I $GUARD4 || return 1
    guard6_present || ip6tables -I $GUARD6 || return 1
    guard4_present && guard6_present || return 1
    : > "$BASE/guards.installed"
    log "firewall guards installed before listener"
}

remove_guards_if_safe() {
    if has_listener; then
        log "guard retained: listener still present"
        return 1
    fi
    guard4_present && iptables -D $GUARD4
    guard6_present && ip6tables -D $GUARD6
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
    [ "$token" = "I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE" ] || return 1
    case "$state" in 0|1) ;; *) return 1 ;; esac
    printf '%s\n' "$state" > "$BASE/control.restore.state"
    : > "$BASE/control.restore.armed"
    log "control restoration armed original_state=$state"
}

clear_control_restore() {
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
    grep -Eq "\"endpointId\"[[:space:]]*:[[:space:]]*$MATTER_ENDPOINT_ID" "$read_body" &&
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
    grep -Eq "\"endpointId\"[[:space:]]*:[[:space:]]*$MATTER_ENDPOINT_ID" "$BASE/watchdog.$name.body" &&
    grep -Eq "\"clusterId\"[[:space:]]*:[[:space:]]*$cluster" "$BASE/watchdog.$name.body" &&
    grep -Eq "\"attributeId\"[[:space:]]*:[[:space:]]*$attribute" "$BASE/watchdog.$name.body" &&
    grep -Eq "\"rawValue\"[[:space:]]*:[[:space:]]*\"$expected\"" "$BASE/watchdog.$name.body"
}

restore_light_if_armed() {
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

    if [ -f "$BASE/completed" ] && clean_state; then
        log "rollback already_clean reason=$reason"
        return 0
    fi
    rm -f "$BASE/completed"
    save_mount_diagnostics "rollback-$reason"

    # If a control command may have been sent, restoration must be attempted
    # while the HTTP API and Matter connector are still available.
    restore_control_if_armed || log "rollback continuing with possible changed lamp state"
    restore_light_if_armed || log "rollback continuing with possible changed light state"

    # Remove every state file from the tmpfs projection before restarting.
    rm -f "$PATCH_MOUNT/quasar.cfg.platformd.patch" \
          "$PATCH_MOUNT/quasar.cfg.platformd.dirty" \
          "$PATCH_MOUNT/quasar.cfg.platformd.tag" 2>/dev/null || true

    # Never restart platformd when arm() failed before crossing the activation
    # boundary. A listener is an independent reason to perform the lifecycle.
    if [ -f "$BASE/activation.started" ] || has_listener; then
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

    if mount_present; then
        canonical_target=$(canonical_path "$PATCH_MOUNT") || { log "cannot canonicalize mounted target; guards retained"; return 1; }
        umount "$canonical_target" || { log "umount failed target=$canonical_target; guards retained"; return 1; }
    fi
    if [ -f "$BASE/mountpoint.created" ] && [ -e "$PATCH_MOUNT" ]; then
        rmdir "$PATCH_MOUNT" || { log "temporary mountpoint removal failed; guards retained"; return 1; }
    fi

    health_snapshot after_rollback
    remove_guards_if_safe || return 1
    : > "$BASE/completed"
    log "rollback complete"
    return 0
}

do_rollback() {
    mkdir -p "$BASE"
    exec 9>"$BASE/rollback.lock"
    flock -x 9
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
    deadline=$(( $(date +%s) + WATCHDOG_SECONDS ))
    log "watchdog armed pid=$$ deadline_epoch=$deadline"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ -f "$BASE/completed" ] && { log "watchdog observed completed"; return 0; }
        if [ -f "$BASE/rollback.request" ]; then do_rollback requested; return $?; fi
        sleep 2
    done
    do_rollback timeout
}

arm() {
    token=$1
    [ "$token" = "$APPROVAL_TOKEN" ] || fail "approval token mismatch"
    [ "$(id -u)" = 0 ] || fail "root required"
    [ ! -e "$BASE" ] || { fail "$BASE already exists; inspect before retry"; return 1; }
    verify_binary /system/vendor/quasar/maind "$EXPECTED_MAIND" || return 1
    verify_binary /system/vendor/quasar/quasar_launcher2 "$EXPECTED_LAUNCHER" || return 1
    [ -z "$(listener_lines)" ] || fail "port 8765 already listening"
    ! guard4_present || fail "matching IPv4 guard already exists; ownership is ambiguous"
    ! guard6_present || fail "matching IPv6 guard already exists; ownership is ambiguous"
    old=$(platformd_pid) || fail "exactly one supervised platformd required"
    available=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
    [ "$available" -ge 70000 ] || fail "MemAvailable below 70000 kB"
    [ ! -e "$PATCH_MOUNT" ] || fail "$PATCH_MOUNT unexpectedly exists"

    umask 077
    mkdir -p "$BASE/patches" || return 1
    printf '%s\n' '{"matter":{"httpControl":{"enabled":true}}}' > "$PATCH_SOURCE/$PATCH_NAME"
    sha256sum "$PATCH_SOURCE/$PATCH_NAME" > "$BASE/patch.sha256"
    iptables-save > "$BASE/iptables.before"
    ip6tables-save > "$BASE/ip6tables.before"
    health_snapshot before

    # Harmless target-side proof: tmpfs marker only, before firewall/mount/patch visibility/SIGTERM.
    watchdog_selftest || return 1

    install_guards || { log "cannot establish both guards"; return 1; }
    mkdir "$PATCH_MOUNT" || { log "cannot create empty mountpoint"; return 1; }
    : > "$BASE/mountpoint.created"
    mount -o bind "$PATCH_SOURCE" "$PATCH_MOUNT" || { log "bind mount failed"; save_mount_diagnostics mount_failure; do_rollback mount_failure; return 1; }
    mount_verified || { save_mount_diagnostics mount_verification_failure; do_rollback mount_verification_failure; return 1; }
    [ -r "$PATCH_MOUNT/$PATCH_NAME" ] || { do_rollback patch_projection_failure; return 1; }

    setsid nohup "$0" watchdog > "$BASE/watchdog.stdout" 2>&1 < /dev/null &
    wpid=$!
    echo "$wpid" > "$BASE/watchdog.pid"
    sleep 1
    kill -0 "$wpid" 2>/dev/null || { do_rollback watchdog_start_failure; return 1; }
    log "watchdog verified pid=$wpid"

    # Re-resolve immediately before signaling to avoid PID reuse.
    old=$(platformd_pid) || { do_rollback platformd_resolution_failure; return 1; }
    echo "$old" > "$BASE/platformd.before.pid"
    : > "$BASE/activation.started"
    log "activation SIGTERM platformd pid=$old"
    kill -TERM "$old" || { do_rollback activation_signal_failure; return 1; }
    new=$(wait_for_new_platformd "$old" 180 2>/dev/null || true)
    [ -n "$new" ] || { do_rollback activation_restart_timeout; return 1; }
    echo "$new" > "$BASE/platformd.active.pid"
    log "activation platformd restored pid=$new"
    wait_listener_state present 120 || { do_rollback listener_start_timeout; return 1; }
    listener_lines > "$BASE/listener.active"
    health_snapshot active
    log "ACTIVATED platformd_pid=$new watchdog_pid=$wpid"
}

status() {
    echo "timestamp=$(now)"
    echo "platformd_pid=$(platformd_pid 2>/dev/null || true)"
    echo "watchdog_pid=$(cat "$BASE/watchdog.pid" 2>/dev/null || true)"
    echo "completed=$([ -f "$BASE/completed" ] && echo yes || echo no)"
    echo "listeners:"
    listener_lines
    echo "guard4=$(guard4_present && echo yes || echo no)"
    echo "guard6=$(guard6_present && echo yes || echo no)"
    echo "patch_mount=$(mount_present && echo yes || echo no)"
    echo "patch_mount_path=$([ -e "$PATCH_MOUNT" ] && echo present || echo absent)"
}

verify_clean() {
    [ -f "$BASE/completed" ] || fail "rollback completion marker absent"
    ! has_listener || fail "port 8765 listener remains"
    ! guard4_present || fail "IPv4 guard remains"
    ! guard6_present || fail "IPv6 guard remains"
    ! mount_present || fail "patch bind mount remains"
    [ ! -e "$PATCH_MOUNT" ] || fail "temporary patch mountpoint remains"
    platformd_pid >/dev/null || fail "supervised platformd not healthy"
    log "rollback clean-state verification passed"
}

http_diagnostics() {
    label=${1:-manual}
    mkdir -p "$BASE"
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
        echo "guards:"
        echo "guard4=$(guard4_present && echo yes || echo no)"
        echo "guard6=$(guard6_present && echo yes || echo no)"
    } > "$output"
    echo "$output"
}

case "${1:-}" in
    arm) arm "${2:-}" ;;
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
    *) echo "usage: $0 {arm TOKEN|watchdog|rollback [reason]|status|verify-clean|http-diagnostics [label]|control-restore-arm TOKEN STATE|control-restore-clear|light-restore-arm ...|light-restore-clear}" >&2; exit 64 ;;
esac
