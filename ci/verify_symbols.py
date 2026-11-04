#!/usr/bin/env python3
"""Prove the collected .dSYM bundles really describe the shipped code.

A dSYM that exists is not a dSYM that works: a bundle with an empty DWARF
directory, or a stale one, names functions the image does not have. So every
bundle must (a) carry a UUID and (b) resolve the function this project actually
crashed inside, `_VDTReadExtensionBundleInfo`.

Bundles are laid out per arch, because Theos generates one dSYM per architecture
before it merges the fat image:

    symbols/arm64e/Vedette.dylib.dSYM
    symbols/arm64e/vedette-nicectl.dSYM

usage: python3 -B ci/verify_symbols.py symbols
"""
from pathlib import Path
import argparse
import os
import re
import subprocess
import sys

# Function names that must resolve, per bundle. `_VDTReadExtensionBundleInfo` is
# the 2026-11-04 crash frame, so it is the regression probe.
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
    bundles = sorted(p for p in root.rglob('*.dSYM') if p.is_dir())
    if not bundles:
        print('verify_symbols: no .dSYM under %s' % root)
        return 1

    failures = []
    for bundle in bundles:
        where = bundle.relative_to(root).as_posix()
        uuid = run(dwarfdump + ['--uuid', str(bundle)])
        uuids = re.findall(r'^UUID: ([0-9A-Fa-f-]{36})', uuid.stdout, re.M)
        if uuid.returncode != 0 or not uuids:
            detail = (uuid.stderr or uuid.stdout).strip().splitlines()[:1]
            failures.append('%s: no UUID (%s)' % (where, detail))
            continue
        print('  %s: %d arch, first %s' % (where, len(uuids), uuids[0]))

        for symbol in EXPECTED.get(bundle.name, ()):
            lookup = run(dwarfdump + ['--lookup', symbol, str(bundle)])
            if lookup.returncode != 0 or not re.search(r'DW_TAG_subprogram', lookup.stdout):
                failures.append('%s: %s does not resolve to a function' % (where, symbol))
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
