#!/usr/bin/env python3
"""Prove the uploaded .dSYM bundles really describe the shipped code.

A dSYM that exists is not a dSYM that works: a stripped input produces a bundle
with an empty DWARF directory, and a stale one names functions that are not in
the image. So each bundle must (a) carry a UUID and (b) resolve the function
names this project actually crashes in.

Usage: python3 -B ci/verify_symbols.py symbols
"""
from pathlib import Path
import argparse
import os
import re
import subprocess
import sys

# Function names that must resolve, per bundle. `_VDTReadExtensionBundleInfo`
# is the one the 2026-11-04 crash landed inside, so it is the regression probe.
EXPECTED = {
    'Vedette.dylib.dSYM': ('_VDTNearestBundlePath', '_VDTReadExtensionBundleInfo'),
    'vedette-nicectl.dSYM': ('_main',),
}


def run(command):
    return subprocess.run(command, capture_output=True, text=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', nargs='?', default='symbols')
    parser.add_argument('--dwarfdump', default=os.environ.get('DWARFDUMP', 'dwarfdump'),
                        help='dwarfdump command line; defaults to $DWARFDUMP or dwarfdump on PATH')
    args = parser.parse_args()
    dwarfdump = args.dwarfdump.split()

    root = Path(args.directory)
    bundles = sorted(p for p in root.glob('*.dSYM') if p.is_dir())
    if not bundles:
        print('verify_symbols: no .dSYM under %s' % root)
        return 1

    failures = []
    for bundle in bundles:
        uuid = run(dwarfdump + ['--uuid', str(bundle)])
        uuids = re.findall(r'^UUID: ([0-9A-Fa-f-]{36})', uuid.stdout, re.M)
        if uuid.returncode != 0 or not uuids:
            failures.append('%s: no UUID (%s)' %
                            (bundle.name, (uuid.stderr or uuid.stdout).strip().splitlines()[:1]))
            continue
        print('  %s: %d arch UUID, first %s' % (bundle.name, len(uuids), uuids[0]))

        for symbol in EXPECTED.get(bundle.name, ()):
            lookup = run(dwarfdump + ['--lookup', symbol, str(bundle)])
            if lookup.returncode != 0 or not re.search(r'DW_TAG_subprogram', lookup.stdout):
                failures.append('%s: %s does not resolve to a function' % (bundle.name, symbol))
            else:
                print('    resolved %s' % symbol)

    if failures:
        for line in failures:
            print('verify_symbols: FAIL %s' % line)
        return 1
    print('verify_symbols: %d bundle(s) verified' % len(bundles))
    return 0


if __name__ == '__main__':
    sys.exit(main())
