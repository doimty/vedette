#!/usr/bin/env python3
"""Generate one .dSYM per packaged image, before the package strip removes them.

Theos links with a debug map and strips when it stages FINALPACKAGE output, so
`dsymutil` has to run on the freshly linked image inside `before-package`. That
is the same pair Xcode runs as Ld + GenerateDSYMFile; Theos only ever does the
first half, which is why every crash so far had to be read as a naked offset.

Nothing here changes what is packaged: it reads the built images and writes
`symbols/<image>.dSYM` in the project directory. Missing `dsymutil`, an image
without a debug map, or a non-Darwin host are reported and skipped so a symbols
problem can never take the shippable deb with it. `--require` turns those skips
into a failure, for the CI step that is supposed to prove symbols exist.

A `skipped: ... no debug map` line means the image was already stripped when
this ran. Theos strips while staging FINALPACKAGE output, so the hook belongs in
`before-package` (see the Makefile); if it ever moves later, this line is the
symptom and `symbols/verify.log` in the CI artifact carries it verbatim.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys

# Names the package ships. Scanning for them keeps the tool independent of each
# scheme's object layout (rootless nests by scheme, subprojects have their own).
PRODUCTS = ('Vedette.dylib', 'VedettePrefs', 'vedette-nicectl')

# A DWARF-bearing image is never tiny, and a stub/placeholder file is: treating
# any non-empty file as success is how a stripped input gets reported as "ok".
MINIMUM_DWARF_BYTES = 1024


def find_images(roots):
    found = []
    for root in roots:
        base = Path(root)
        if not base.is_dir():
            continue
        for name in PRODUCTS:
            for path in sorted(base.rglob(name)):
                if path.is_file() and path not in found:
                    found.append(path)
    return found


def dwarf_payload(dsym):
    """The DWARF file inside a .dSYM, or None when the bundle is useless."""
    dwarf = dsym / 'Contents/Resources/DWARF'
    if not dwarf.is_dir():
        return None
    for entry in dwarf.iterdir():
        if entry.is_file() and entry.stat().st_size >= MINIMUM_DWARF_BYTES:
            return entry
    return None


def stage(image, out_dir, dsymutil):
    target = out_dir / (image.name + '.dSYM')
    if target.exists():
        shutil.rmtree(target)
    command = dsymutil + [str(image), '-o', str(target)]
    result = subprocess.run(command, capture_output=True, text=True)
    payload = dwarf_payload(target) if result.returncode == 0 else None
    if payload is None:
        reason = (result.stderr or result.stdout or 'no debug map').strip().splitlines()
        shutil.rmtree(target, ignore_errors=True)
        return False, str(image), (reason[-1] if reason else 'no debug map')
    return True, str(image), '%s (%d bytes)' % (payload.name, payload.stat().st_size)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--objects', action='append', default=[],
                        help='object/output root to scan; repeatable')
    parser.add_argument('--out', default='symbols', help='dSYM output directory')
    parser.add_argument('--dsymutil', default=None,
                        help='dsymutil command line (default: dsymutil on PATH)')
    parser.add_argument('--require', action='store_true',
                        help='fail when no dSYM could be produced')
    args = parser.parse_args()

    out_dir = Path(args.out)
    images = find_images(args.objects)
    if not images:
        print('stage_symbols: no packaged image under %s' % (args.objects or '<none>',))
        return 1 if args.require else 0

    command = args.dsymutil.split() if args.dsymutil else ['dsymutil']
    if not args.dsymutil and shutil.which('dsymutil') is None:
        print('stage_symbols: dsymutil not available; %d image(s) left without symbols' % len(images))
        return 1 if args.require else 0

    out_dir.mkdir(parents=True, exist_ok=True)
    produced = 0
    for image in images:
        ok, name, detail = stage(image, out_dir, command)
        print(('  symbols: %s -> %s' if ok else '  skipped: %s -> %s') % (name, detail))
        produced += 1 if ok else 0

    print('stage_symbols: %d/%d image(s) have symbols in %s' % (produced, len(images), out_dir))
    if args.require and produced != len(images):
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
