#!/bin/sh
# Сетевой guard для неаутентифицированного Matter HTTP API.
# shellcheck disable=SC2086
# ВАЖНО: установка правила сама по себе не делает постоянный API безопасным:
# порядок правил, ранняя загрузка и изменения firewall требуют отдельного аудита.
# install/status/remove не запускают maind и не изменяют конфигурацию Quasar.

PORT="${GUARD_PORT:-8765}"
case "$PORT" in
    ''|*[!0-9]*|0*) echo 'guard: недопустимый GUARD_PORT' >&2; exit 64 ;;
esac
if [ "$PORT" -gt 65535 ] 2>/dev/null; then
    echo 'guard: порт вне диапазона' >&2
    exit 64
fi
PORT_HEX=$(printf '%04X' "$PORT") || exit 1
RULE="INPUT ! -i lo -p tcp --dport $PORT -j REJECT --reject-with tcp-reset"

# Возвраты: 0 — есть listener; 1 — listener нет; 2 — состояние неизвестно.
listening() {
    if [ ! -r /proc/net/tcp ] || [ ! -r /proc/net/tcp6 ]; then
        echo 'guard: /proc/net/tcp{,6} недоступны — отказ' >&2
        return 2
    fi
    grep -qiE ":$PORT_HEX [0-9A-F:]+ 0A" /proc/net/tcp /proc/net/tcp6
}

# Возвраты: 0 — правило есть; 1 — правила нет; 2 — ошибка проверки.
inspect() {
    bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1 || ! "$bin" -S INPUT >/dev/null 2>&1; then
        echo "guard: не могу проверить правила $bin" >&2
        return 2
    fi
    "$bin" -C $RULE >/dev/null 2>&1
    rc=$?
    case "$rc" in 0|1) return "$rc" ;; *) echo "guard: ошибка $bin -C (rc=$rc)" >&2; return 2 ;; esac
}
present4() { inspect iptables; }
present6() { inspect ip6tables; }

# Получить оба статуса, не скрывая ошибку проверки.
read_guards() {
    present4; r4=$?
    present6; r6=$?
    if [ "$r4" -gt 1 ] || [ "$r6" -gt 1 ]; then
        echo 'guard: невозможно определить состояние firewall' >&2
        return 2
    fi
    return 0
}

show_status() {
    read_guards || return 2
    listening; ls_rc=$?
    case "$ls_rc" in 0) listener=yes ;; 1) listener=no ;; *) listener=unknown ;; esac
    if [ "$r4" -eq 0 ]; then s4=present; else s4=absent; fi
    if [ "$r6" -eq 0 ]; then s6=present; else s6=absent; fi
    echo "guard4=$s4 guard6=$s6 listener=$listener port=$PORT"
    if [ "$ls_rc" -gt 1 ]; then return 2; fi
    if [ "$r4" -eq 0 ] && [ "$r6" -eq 0 ]; then return 0; fi
    return 1
}

case "${1:-}" in
    install)
        read_guards || exit 1
        if [ "$r4" -eq 1 ]; then
            iptables -I $RULE || { echo 'guard: iptables -I failed' >&2; exit 1; }
        fi
        if [ "$r6" -eq 1 ]; then
            ip6tables -I $RULE || { echo 'guard: ip6tables -I failed, IPv4 guard remains' >&2; exit 1; }
        fi
        show_status || exit 1
        ;;
    remove)
        listening; ls_rc=$?
        case "$ls_rc" in
            0) echo "guard: отказ — порт $PORT слушается" >&2; exit 2 ;;
            1) : ;;
            *) echo 'guard: невозможно проверить listener; снятие запрещено' >&2; exit 2 ;;
        esac
        read_guards || exit 1
        if [ "$r4" -eq 0 ]; then
            iptables -D $RULE || { echo 'guard: iptables -D failed' >&2; exit 1; }
        fi
        if [ "$r6" -eq 0 ]; then
            ip6tables -D $RULE || { echo 'guard: ip6tables -D failed' >&2; exit 1; }
        fi
        read_guards || exit 1
        if [ "$r4" -ne 1 ] || [ "$r6" -ne 1 ]; then
            echo 'guard: после remove остались правила; отказ' >&2
            exit 1
        fi
        listening; ls_rc=$?
        if [ "$ls_rc" -ne 1 ]; then
            echo 'guard: после remove listener активен или проверка не удалась' >&2
            exit 2
        fi
        echo "guard4=absent guard6=absent listener=no port=$PORT"
        ;;
    status)
        show_status
        ;;
    *) echo "usage: $0 install|remove|status" >&2; exit 64 ;;
esac
