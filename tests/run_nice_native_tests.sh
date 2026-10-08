#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'SKIP: Foundation runtime tests require macOS (not a pass).'
    exit 77
fi
if [ "$(id -u)" -ne 0 ]; then
    echo 'Run explicitly as root in the isolated macOS CI host; no automatic privilege escalation.' >&2
    exit 77
fi
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT HUP INT TERM
for name in VDTNicePolicy VDTNiceStore; do
    xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I. -c "$name.c" -o "$out/$name.o"
done
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror \
    -Itests/native_stubs -I. -framework Foundation tests/test_nice_native.mm \
    VDTNiceShared.mm VDTShared.mm "$out/VDTNicePolicy.o" "$out/VDTNiceStore.o" -o "$out/native"
"$out/native"
