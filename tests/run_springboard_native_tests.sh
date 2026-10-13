#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ] || [ "$(id -u)" -ne 0 ]; then
    echo 'SKIP: SpringBoard Foundation test needs an isolated root macOS host (not a pass).'
    exit 77
fi
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT HUP INT TERM
for name in VDTProcessIdentity VDTPolicyTransition VDTNicePolicy VDTNiceStore VDTBundleRules VDTMemoryPolicy VDTJetsamPolicy VDTResourceApply; do
    xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I. -c "$name.c" -o "$out/$name.o"
done
compile_test() {
    binary="$1"; fixture="$2"; shift 2
    xcrun clang++ -std=c++17 -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror \
        -Itests/native_stubs -I. -framework Foundation "$@" "$fixture" \
        VDTNiceShared.mm VDTShared.mm VDTBundleIdentity.mm "$out/VDTProcessIdentity.o" "$out/VDTPolicyTransition.o" \
        "$out/VDTNicePolicy.o" "$out/VDTNiceStore.o" "$out/VDTBundleRules.o" \
        "$out/VDTMemoryPolicy.o" "$out/VDTJetsamPolicy.o" "$out/VDTResourceApply.o" -o "$binary"
}
compile_test "$out/springboard" tests/test_springboard_native.mm -DVDT_RESOURCE_RESOLVER=1
"$out/springboard"
# Isolate old declarations and the unchanged nice coordinator together. The
# old source is literal git bytes, not a model or rewritten fallback function.
mkdir -p "$out/old/tests"
cp ./*.h "$out/old/"
cp VDTNiceRuntime.mm "$out/old/"
cp tests/test_springboard_native.mm "$out/old/tests/"
git show a054671a0a3f6b0c476d95906fd924687b5b3386:VDTProcessManager.mm > "$out/old/VDTProcessManager.mm"
git show a054671a0a3f6b0c476d95906fd924687b5b3386:VDTProcessManager.h > "$out/old/VDTProcessManager.h"
compile_test "$out/old-test" "$out/old/tests/test_springboard_native.mm"
ulimit -c 0
if "$out/old-test" > "$out/old-result.log" 2>&1; then
    echo 'ERROR: old resolver unexpectedly passed SpringBoard integration' >&2
    exit 1
fi
grep -Fq 'targets.count==1' "$out/old-result.log"
echo 'SpringBoard integration negative control: actual old resolver rejected'
