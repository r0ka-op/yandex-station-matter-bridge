#!/bin/sh
# One-request HTTP responder used only to validate SSH local forwarding.

request=''
while IFS= read -r line; do
    [ -z "$request" ] && request=$line
    [ "$line" = "$(printf '\r')" ] && break
done

path=$(printf '%s' "$request" | cut -d' ' -f2)
case "$path" in
    /selftest)
        body='ssh-http-transport-ok'
        printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
        ;;
    /error)
        body='expected-error'
        printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
        ;;
    /empty)
        printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        ;;
    /truncated)
        printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort'
        ;;
    *)
        printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        ;;
esac
