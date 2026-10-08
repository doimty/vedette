#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ] || [ "$(id -u)" -ne 0 ]; then
    echo 'SKIP: SpringBoard Foundation test needs an isolated root macOS host (not a pass).'
    exit 77
fi
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT HUP INT TERM
for name in VDTProcessIdentity VDTPolicyTransition VDTNicePolicy VDTNiceStore; do
    xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I. -c "$name.c" -o "$out/$name.o"
done
compile_test() {
    binary="$1"; shift
    xcrun clang++ -std=c++17 -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror \
        -Itests/native_stubs -I. -framework Foundation "$@" tests/test_springboard_native.mm \
        VDTNiceShared.mm VDTShared.mm "$out/VDTProcessIdentity.o" "$out/VDTPolicyTransition.o" \
        "$out/VDTNicePolicy.o" "$out/VDTNiceStore.o" -o "$binary"
}
compile_test "$out/springboard"
"$out/springboard"
# The same assertions must reject the actual old resolver, not just a made-up model.
git show a054671a0a3f6b0c476d95906fd924687b5b3386:VDTProcessManager.mm > "$out/old-resolver.mm"
compile_test "$out/old-test" "-DVDT_RESOLVER_IMPLEMENTATION=\"$out/old-resolver.mm\""
ulimit -c 0
if "$out/old-test" > "$out/old-result.log" 2>&1; then
    echo 'ERROR: old resolver unexpectedly passed SpringBoard integration' >&2
    exit 1
fi
grep -Fq 'targets.count==1' "$out/old-result.log"
echo 'SpringBoard integration negative control: actual old resolver rejected'
