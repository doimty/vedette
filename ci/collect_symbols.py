#!/usr/bin/env python3
"""Archive only the three products' existing, verified Theos dSYMs.

Pinned Theos links -> dsymutil -> strip per architecture, then lipo merges the
images. Its existing DEBUGFLAG=-ggdb is sufficient: do not regenerate dSYMs from
stripped binaries or add another build here. Pass each project's .theos/obj
explicitly; the default is only .theos/obj, never the entire checkout.

Layout: symbols/{product}/root-{index}/{original-relative-bundle-path}.
The log maps root indices to the supplied object roots. All nested scheme,
architecture and subproject paths survive; no architecture is guessed from a
folder name. Unknown products and theos/vendor trees are excluded. Output is
pruned before walking, and all identities/collisions are checked before copying.
An identical rerun is idempotent; different content at an existing destination
is an error (choose a fresh output directory for a different build).

This only proves DWARF is present/valid. verify_symbols.py must subsequently
pair it with every architecture of every product in the *extracted deb*.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

if __package__:
    from .verify_symbols import (DwarfTools, PRODUCTS, SymbolsError, add_tool_arguments,
                                 bundle_digest, dsym_bundles, inspect_dsym)
else:
    from verify_symbols import (DwarfTools, PRODUCTS, SymbolsError, add_tool_arguments,
                                bundle_digest, dsym_bundles, inspect_dsym)


def bundles(roots, exclude=None):
    found = set()
    for root in roots:
        found.update(dsym_bundles(root, exclude=exclude, skip_vendor=True))
    return sorted(found)


def destination(bundle, root, out_dir, root_index=0):
    """Canonicalize both operands before relative_to, retaining original paths."""
    bundle, root, out_dir = (Path(path).resolve() for path in (bundle, root, out_dir))
    relative = bundle.relative_to(root)
    if relative == Path('.'):
        relative = Path(bundle.name)
    product = bundle.name.removesuffix('.dSYM')
    return out_dir / product / ('root-%03d' % root_index) / relative


def collect_symbols(roots, out_dir, tools, require=False):
    out_dir = Path(out_dir).resolve()
    normalized = []
    for root in roots:
        root = Path(root).resolve()
        if root not in normalized:
            normalized.append(root)
    for index, root in enumerate(normalized):
        print('  root-%03d: %s' % (index, root))
    found = bundles(normalized, out_dir)
    selected = []
    for bundle in found:
        if bundle.name.removesuffix('.dSYM') not in PRODUCTS:
            print('  ignored non-product dSYM: %s' % bundle)
            continue
        if out_dir.is_relative_to(bundle):
            raise SymbolsError('output is inside an input dSYM; self-copy prohibited: %s' % bundle)
        selected.append(bundle)
    if not selected:
        print('collect_symbols: no project-product .dSYM under %s' % normalized)
        if require:
            raise SymbolsError('no required project-product dSYMs collected')
        return []

    # Preflight the complete set. No partial copy if a later input/tool/target
    # fails. Most-specific root owns inputs when explicit scan roots overlap.
    plan = []
    for bundle in selected:
        info = inspect_dsym(bundle, tools)
        owner = max((root for root in normalized if bundle.is_relative_to(root)),
                    key=lambda root: len(root.parts))
        target = destination(bundle, owner, out_dir, normalized.index(owner))
        if not target.resolve().is_relative_to(out_dir):
            raise SymbolsError('destination escapes collection through a symlink: %s' % target)
        exists = target.exists() or target.is_symlink()
        if exists and bundle_digest(target) != info.bundle_sha256:
            raise SymbolsError('destination has different content; not overwriting: %s' % target)
        plan.append((info, target, exists))

    copied = []
    for info, target, exists in plan:
        # Recheck content to detect inputs changing during collection. Theos must
        # have finished linking/dsymutil before this step begins.
        if bundle_digest(info.bundle) != info.bundle_sha256:
            raise SymbolsError('dSYM changed after preflight: %s' % info.bundle)
        if exists:
            print('  unchanged identical: %s -> %s' % (info.bundle, target))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(info.bundle, target)  # Never removes/replaces a target.
            if bundle_digest(target) != info.bundle_sha256:
                raise SymbolsError('copied dSYM content differs from source: %s' % target)
            print('  kept: %s -> %s (%s)' %
                  (info.bundle, target, ', '.join(sorted(info.uuids))))
        copied.append(target)
    print('collect_symbols: %d/%d bundle(s) collected into %s' %
          (len(copied), len(selected), out_dir))
    return copied


def main(argv=None, tools=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--objects', action='append', default=[],
                        help='project .theos/obj root to scan; repeatable; default: .theos/obj')
    parser.add_argument('--out', default='symbols', help='collection directory')
    parser.add_argument('--require', action='store_true',
                        help='also fail when no selected dSYM exists (invalid inputs always fail)')
    add_tool_arguments(parser)
    args = parser.parse_args(argv)
    try:
        tools = tools or DwarfTools(args.dwarfdump, args.lipo, timeout=args.tool_timeout)
        collect_symbols(args.objects or ['.theos/obj'], args.out, tools, args.require)
        return 0
    except (SymbolsError, OSError) as error:
        print('collect_symbols: FAIL %s' % error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
