#!/bin/sh
set -u

out=""
post=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O) out=$2; shift 2; continue ;;
        --post-data=*) post=${1#--post-data=} ;;
        http://*) url=$1 ;;
    esac
    shift
done

[ -n "$out" ] && [ -n "$post" ] && [ -n "$url" ] || exit 64
case "$url" in
    http://127.0.0.1:8765/interaction/invokeCommand|http://127.0.0.1:8765/interaction/readAttribute) ;;
    *) printf '%s\n' "$url" > "$BASE/FORBIDDEN_NETWORK_TARGET"; exit 65 ;;
esac
printf '%s\t%s\n' "$url" "$post" >> "$BASE/mock.requests"

fault=$(cat "$BASE/mock.fault" 2>/dev/null || true)
case "$fault" in
    http_failure) exit 8 ;;
    timeout) exit 28 ;;
    invalid_json) printf '%s' '{invalid' > "$out"; exit 0 ;;
esac

number() {
    printf '%s' "$post" | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p"
}
cluster=$(number clusterId)

case "$url" in
    */interaction/invokeCommand)
        command=$(number commandId)
        if [ "$cluster:$command" = 8:0 ]; then
            level=$(number level)
            [ -n "$level" ] || exit 66
            printf '%s\n' "$level" > "$BASE/mock.level"
        elif [ "$cluster" = 6 ]; then
            case "$command" in 0|1) printf '%s\n' "$command" > "$BASE/mock.onoff" ;; *) exit 67 ;; esac
        elif [ "$cluster:$command" = 768:6 ]; then
            :
        else
            exit 68
        fi
        printf '%s' "{\"responses\":[{\"endpointId\":1,\"clusterId\":$cluster,\"commandId\":$command,\"status\":\"Success\"}]}" > "$out"
        ;;
    */interaction/readAttribute)
        attribute=$(number attributeId)
        raw=""
        if [ "$cluster:$attribute" = 8:0 ]; then
            if [ "$fault" = partial_readback ]; then raw=0x04ff; else raw=$(cat "$BASE/mock.level.raw"); fi
        elif [ "$cluster:$attribute" = 6:0 ]; then
            onoff=$(cat "$BASE/mock.onoff")
            if [ "$onoff" = 0 ]; then raw=0x08; else raw=0x09; fi
        elif [ "$cluster:$attribute" = 768:8 ]; then raw=0x0400
        elif [ "$cluster:$attribute" = 768:0 ]; then raw=0x049f
        elif [ "$cluster:$attribute" = 768:1 ]; then raw=0x04f4
        else exit 69
        fi
        printf '%s' "{\"errors\":[],\"values\":[{\"endpointId\":1,\"clusterId\":$cluster,\"attributeId\":$attribute,\"rawValue\":\"$raw\"}]}" > "$out"
        ;;
esac
exit 0
