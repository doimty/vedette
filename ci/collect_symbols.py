#!/usr/bin/env python3
"""Collect the .dSYM bundles Theos already generated, so they can be archived.

Theos generates debug symbols itself: `makefiles/instance/rules.mk` runs
`$(TARGET_DSYMUTIL) "$@"` right after linking and *before* `strip`, so with
`dsymutil` on PATH (CI installs the Xcode toolchain) every image gets
`<obj dir>/<arch>/<image>.dSYM`. Nothing here needs to run dsymutil again: by
before-package the images are already stripped, and re-running dsymutil on them
fails with "no debug map".

So this copies what exists into `symbols/`, preserving the arch directory, and
reports anything that looks like a bundle but carries no DWARF. It never touches
the built images and never fails the build on its own; `--require` turns "no
bundle at all" into a failure for the CI step that must prove symbols exist.

Note the layout this expects: Theos produces one dSYM per architecture, and the
fat image made by "Merging tweak" has none of its own. So `symbols/arm64e/...`
and `symbols/arm64/...` are the deliverable, and `atos` needs `-arch`.
"""
from pathlib import Path
import argparse
import shutil
import sys

# A DWARF-bearing image is never tiny; treating any non-empty file as success is
# how an empty bundle gets reported as fine.
MINIMUM_DWARF_BYTES = 1024


def bundles(roots):
    found = []
    for root in roots:
        base = Path(root)
        if not base.is_dir():
            continue
        for path in sorted(base.rglob('*.dSYM')):
            if path.is_dir() and path not in found:
                found.append(path)
    return found


def dwarf_payload(dsym):
    dwarf = dsym / 'Contents/Resources/DWARF'
    if not dwarf.is_dir():
        return None
    for entry in dwarf.iterdir():
        if entry.is_file() and entry.stat().st_size >= MINIMUM_DWARF_BYTES:
            return entry
    return None


def destination(bundle, root, out_dir):
    """Keep the arch directory; a bundle directly under the root gets `flat`."""
    relative = bundle.relative_to(root)
    if len(relative.parts) < 2:
        relative = Path('flat') / relative.name
    return out_dir / relative


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--objects', action='append', default=[],
                        help='object/output root to scan; repeatable')
    parser.add_argument('--out', default='symbols', help='collection directory')
    parser.add_argument('--require', action='store_true',
                        help='fail when no usable bundle was collected')
    args = parser.parse_args()

    out_dir = Path(args.out)
    found = bundles(args.objects)
    if not found:
        print('collect_symbols: no .dSYM under %s' % (args.objects or '<none>',))
        return 1 if args.require else 0

    collected = 0
    for bundle in found:
        payload = dwarf_payload(bundle)
        if payload is None:
            print('  empty:   %s (no DWARF payload)' % bundle)
            continue
        root = next(r for r in map(Path, args.objects) if bundle.is_relative_to(r))
        target = destination(bundle, root, out_dir)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(bundle, target)
        print('  kept:    %s -> %s (%s, %d bytes)' %
              (bundle, target, payload.name, payload.stat().st_size))
        collected += 1

    print('collect_symbols: %d/%d bundle(s) collected into %s' % (collected, len(found), out_dir))
    if args.require and collected == 0:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
