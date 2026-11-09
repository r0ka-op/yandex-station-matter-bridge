#!/bin/sh
set -eu

: "${ZIG:=zig}"
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$root/../../deploy/maind-http-local/maind-http-local.aarch64"}
mkdir -p "$(dirname -- "$output")"
"$ZIG" cc -target aarch64-linux-musl -static -std=c11 -Os -s \
    -Wall -Wextra -Werror -pedantic \
    "$root/maind-http-local.c" -o "$output"
sha256sum "$output"
wc -c "$output"
