#!/bin/sh
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
binary="$(mktemp)"
trap 'rm -f "$binary"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
    -I"$repo_root" "$repo_root/tests/test_list_order.c" -o "$binary"
"$binary"
