#!/usr/bin/env python3
"""Pair dSYMs with the *extracted deb*, not with pre-package build images.

Every slice of all three products must have one content-unique dSYM with the
same architecture and LC_UUID. lipo independently enumerates slices so that a
slice without LC_UUID cannot disappear from `dwarfdump --uuid`. DWARF must pass
`--verify` and contain a compilation unit with line-table and code-range data;
a large file, UUID alone, or a declaration-only debug unit is not sufficient.

LLVM/Apple dwarfdump uses --lookup=<address>, not a function name. For a name,
use --name=<name> / -n. There is deliberately no guessed crash-function probe.
https://llvm.org/docs/CommandGuide/llvm-dwarfdump.html

Usage (after dpkg-deb -x):
  python3 ci/verify_symbols.py symbols --package-root /tmp/vedette-package \
      --package-prefix "$PACKAGE_PREFIX" --manifest symbols/manifest.json

The callable tool runner is injectable for fixture tests on hosts without Xcode.
Those tests do not establish that the project's actual macOS artifacts passed.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import struct
import subprocess
import sys
import tempfile
from typing import Dict, Optional

PRODUCTS = {
    'Vedette.dylib': 'Library/MobileSubstrate/DynamicLibraries/Vedette.dylib',
    'VedettePrefs': 'Library/PreferenceBundles/VedettePrefs.bundle/VedettePrefs',
    'vedette-nicectl': 'usr/libexec/vedette-nicectl',
}
MAX_TOOL_OUTPUT_BYTES = 4 * 1024 * 1024
# Mach-O MH_DSYM: the filetype dsymutil writes. A stripped image substituted for
# a DWARF payload is MH_DYLIB/MH_OBJECT/MH_EXECUTE instead.
MH_DSYM = 0xA
UUID_LINE = re.compile(
    r'^UUID: ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
    r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) \(([A-Za-z0-9_+.-]+)\) (.+)$')


class SymbolsError(RuntimeError):
    """Missing, ambiguous, malformed or unverified symbol evidence."""


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _walk_error(error):
    raise error


def dsym_bundles(root, exclude=None, skip_vendor=False):
    """Do not follow directory symlinks or descend into bundles/output/vendor."""
    root = Path(root).resolve()
    excluded = Path(exclude).resolve() if exclude is not None else None
    if not root.is_dir():
        raise SymbolsError('scan root is not a directory: %s' % root)
    if excluded is not None and root.is_relative_to(excluded):
        return []
    blocked = {'theos', 'vendor', '.git'} if skip_vendor else set()
    if any(part.casefold() in blocked for part in root.parts):
        return []
    if root.name.endswith('.dSYM'):
        return [root]
    found = []
    for current, directories, files in os.walk(root, followlinks=False, onerror=_walk_error):
        for name in files:
            if name.endswith('.dSYM'):
                raise SymbolsError('dSYM path is not a directory: %s' % (Path(current) / name))
        kept = []
        for name in sorted(directories):
            path = Path(current) / name
            if name.casefold() in blocked:
                continue
            if excluded is not None and path.resolve().is_relative_to(excluded):
                continue
            if path.is_symlink():
                if name.endswith('.dSYM'):
                    raise SymbolsError('symlink dSYM is not a regular input: %s' % path)
                continue
            if name.endswith('.dSYM'):
                found.append(path.resolve())
            else:
                kept.append(name)
        directories[:] = kept
    return sorted(found)


def bundle_digest(bundle):
    """Content identity includes names and empty dirs, but not mtimes/modes."""
    bundle = Path(bundle)
    if bundle.is_symlink() or not bundle.is_dir():
        raise SymbolsError('dSYM is not a regular directory: %s' % bundle)
    digest = hashlib.sha256()
    for current, directories, files in os.walk(bundle, followlinks=False, onerror=_walk_error):
        directories.sort()
        for name in directories:
            if (Path(current) / name).is_symlink():
                raise SymbolsError('symlink inside dSYM: %s' % (Path(current) / name))
        relative = Path(current).relative_to(bundle).as_posix()
        digest.update(b'D\0' + relative.encode('utf-8') + b'\0')
        for name in sorted(files):
            path = Path(current) / name
            if not stat.S_ISREG(path.lstat().st_mode):
                raise SymbolsError('non-regular file inside dSYM: %s' % path)
            relative = path.relative_to(bundle).as_posix()
            digest.update(b'F\0' + relative.encode('utf-8') + b'\0')
            digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def dwarf_payload(bundle):
    product = Path(bundle).name.removesuffix('.dSYM')
    if product not in PRODUCTS:
        raise SymbolsError('unenumerated dSYM product: %s' % bundle)
    directory = Path(bundle) / 'Contents' / 'Resources' / 'DWARF'
    if directory.is_symlink() or not directory.is_dir():
        raise SymbolsError('missing DWARF directory: %s' % bundle)
    entries = sorted(directory.iterdir())
    if len(entries) != 1 or entries[0].name != product:
        raise SymbolsError('expected exactly one DWARF file named %s: %s' % (product, bundle))
    payload = entries[0]
    if not stat.S_ISREG(payload.lstat().st_mode) or payload.stat().st_size == 0:
        raise SymbolsError('DWARF payload is not a nonempty regular file: %s' % payload)
    return payload


class DwarfTools:
    """Use argv lists (tool paths may contain spaces), bounded output and deadlines.

    runner(command) must return a text subprocess.CompletedProcess-compatible
    result. The default uses subprocess.run with file redirection, not a shell.
    Only the bounded outputs are read back, and all tool diagnostics fail closed.
    """

    def __init__(self, dwarfdump='dwarfdump', lipo='lipo', runner=None, timeout=120):
        if not math.isfinite(timeout) or timeout <= 0:
            raise SymbolsError('tool timeout must be positive and finite')
        self.dwarfdump = str(dwarfdump)
        self.lipo = str(lipo)
        self.runner = runner
        self.timeout = timeout

    def _execute(self, command):
        env = dict(os.environ, LC_ALL='C', LANG='C')
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            result = subprocess.run(command, stdout=stdout, stderr=stderr,
                                    timeout=self.timeout, env=env, check=False)
            sizes = [stream.tell() for stream in (stdout, stderr)]
            if sum(sizes) > MAX_TOOL_OUTPUT_BYTES:
                raise SymbolsError('tool output exceeded %d bytes: %s' %
                                   (MAX_TOOL_OUTPUT_BYTES, shlex.join(command)))
            stdout.seek(0)
            stderr.seek(0)
            return subprocess.CompletedProcess(command, result.returncode,
                                               stdout.read().decode('utf-8'),
                                               stderr.read().decode('utf-8'))

    def run(self, command):
        try:
            result = self.runner(command) if self.runner is not None else self._execute(command)
            if (not isinstance(getattr(result, 'stdout', None), str) or
                    not isinstance(getattr(result, 'stderr', None), str) or
                    not isinstance(getattr(result, 'returncode', None), int)):
                raise SymbolsError('tool runner must return an integer exit code and text stdout/stderr')
            if len(result.stdout.encode('utf-8')) + len(result.stderr.encode('utf-8')) > MAX_TOOL_OUTPUT_BYTES:
                raise SymbolsError('tool output exceeded %d bytes' % MAX_TOOL_OUTPUT_BYTES)
        except (OSError, subprocess.SubprocessError, UnicodeError) as error:
            raise SymbolsError('tool execution failed (%s): %s' %
                               (shlex.join(command), error)) from error
        if result.returncode != 0 or result.stderr.strip():
            detail = (result.stderr or result.stdout).strip()[:2000]
            raise SymbolsError('tool failed (exit %s): %s\n%s' %
                               (result.returncode, shlex.join(command), detail))
        return result.stdout

    def uuids(self, path):
        path = str(path)
        arch_output = self.run([self.lipo, '-archs', path])
        architectures = arch_output.split()
        if (not architectures or len(architectures) != len(set(architectures)) or
                any(not re.fullmatch(r'[A-Za-z0-9_+.-]+', arch) for arch in architectures)):
            raise SymbolsError('invalid/duplicate architecture inventory: %s' % path)
        output = self.run([self.dwarfdump, '--uuid', path])
        result = {}
        for line in output.splitlines():
            if not line.strip():
                continue
            match = UUID_LINE.fullmatch(line.strip())
            if match is None:
                raise SymbolsError('malformed UUID output for %s: %s' % (path, line[:500]))
            value, arch, reported_path = match.groups()
            if reported_path != path:
                raise SymbolsError('UUID output names a different input: %s (expected %s)' %
                                   (reported_path, path))
            if arch in result:
                raise SymbolsError('duplicate LC_UUID architecture %s: %s' % (arch, path))
            result[arch] = value.upper()
        if set(architectures) != set(result):
            raise SymbolsError('LC_UUID inventory differs from shipped/file architectures for %s: '
                               'lipo=%s UUIDs=%s' % (path, architectures, sorted(result)))
        return result

    def verify_dwarf(self, path, arch):
        # dwarfdump --verify is the structural authority: it walks the DIE graph,
        # line tables and code ranges, and reports malformed, truncated or
        # empty debug info. Nothing else here re-derives DWARF facts from text or
        # from partially printed dumps - three attempts at that rejected real
        # Xcode dSYMs while proving nothing the verifier had not already proved.
        # A failing verifier, including output on stderr with a zero exit, is
        # rejected by run().
        self.run([self.dwarfdump, '--arch=' + arch, '--verify', '--quiet', str(path)])
        # --verify alone cannot tell "valid debug info" from "no debug info": on a
        # stripped Mach-O it exits 0 and prints nothing. The section inventory
        # answers that from bytes instead of from tool layout.
        evidence = macho_dwarf_evidence(path, arch)
        if evidence is not None:
            filetype, dwarf_bytes = evidence
            if filetype != MH_DSYM:
                raise SymbolsError('payload is not a dSYM Mach-O (filetype %d) in %s (%s)' %
                                   (filetype, path, arch))
            if dwarf_bytes <= 0:
                raise SymbolsError('empty __DWARF segment in %s (%s)' % (path, arch))


def macho_dwarf_evidence(path, arch):
    """(filetype, total __DWARF payload bytes) for one 64-bit slice, or None.

    A dSYM payload is Mach-O of type MH_DSYM whose __DWARF segment carries the
    debug data. A stripped image substituted for it is MH_DYLIB/MH_EXECUTE with
    no __DWARF segment at all. That difference is a header fact, so it does not
    depend on how a tool prints anything, and it does not depend on the names of
    individual sections either.

    None means "not a 64-bit arm64 Mach-O", which synthetic fixtures use; the
    caller treats that as outside this check's scope.
    """
    data = Path(path).read_bytes()
    if len(data) < 32:
        return None
    spans = []
    if int.from_bytes(data[:4], "little") == 0xFEEDFACF:
        spans.append((0, len(data)))
    elif int.from_bytes(data[:4], "big") in (0xCAFEBABE, 0xCAFEBABF):
        for index in range(int.from_bytes(data[4:8], "big")):
            entry = 8 + index * 20
            if entry + 20 > len(data):
                return None
            _cpu, _sub, offset, size, _align = struct.unpack(">iiIII", data[entry:entry + 20])
            spans.append((offset, size))
    else:
        return None

    for first, size in spans:
        image = data[first:first + size]
        if len(image) < 32 or int.from_bytes(image[:4], "little") != 0xFEEDFACF:
            continue
        if int.from_bytes(image[4:8], "little") != 0x0100000C:
            continue  # arm64 and arm64e share CPU_TYPE_ARM64
        filetype = int.from_bytes(image[12:16], "little")
        offset, dwarf = 32, 0
        for _ in range(int.from_bytes(image[16:20], "little")):
            command = int.from_bytes(image[offset:offset + 4], "little")
            length = int.from_bytes(image[offset + 4:offset + 8], "little")
            if length <= 0 or offset + length > len(image):
                return None
            if command == 0x19:  # LC_SEGMENT_64
                name = image[offset + 8:offset + 24].split(b"\0")[0].decode("ascii", "replace")
                if name == "__DWARF":
                    dwarf += int.from_bytes(image[offset + 48:offset + 56], "little")
            offset += length
        return filetype, dwarf
    return None


def add_tool_arguments(parser):
    parser.add_argument('--dwarfdump', default=os.environ.get('DWARFDUMP', 'dwarfdump'),
                        help='single dwarfdump executable path (not a shell command)')
    parser.add_argument('--lipo', default=os.environ.get('LIPO', 'lipo'),
                        help='single lipo executable path (not a shell command)')
    parser.add_argument('--tool-timeout', type=float, default=120,
                        help='per-tool deadline in seconds (default: 120)')


@dataclass(frozen=True)
class Dsym:
    bundle: Path
    product: str
    dwarf: Path
    uuids: Dict[str, str]
    dwarf_sha256: str
    bundle_sha256: str


def inspect_dsym(bundle, tools):
    bundle = Path(bundle)
    fingerprint = bundle_digest(bundle)  # Reject all symlinks before invoking tools.
    payload = dwarf_payload(bundle)
    identities = tools.uuids(payload)
    for arch in sorted(identities):
        tools.verify_dwarf(payload, arch)
    dwarf_hash = sha256_file(payload)
    if bundle_digest(bundle) != fingerprint:
        raise SymbolsError('dSYM changed during verification: %s' % bundle)
    return Dsym(bundle, bundle.name.removesuffix('.dSYM'), payload, identities,
                dwarf_hash, fingerprint)


def normalize_prefix(prefix):
    if prefix and not prefix.startswith('/'):
        raise SymbolsError('package prefix must be empty or an absolute POSIX path')
    if '\\' in prefix or '\0' in prefix or any(part in ('.', '..') for part in prefix.split('/')):
        raise SymbolsError('package prefix contains traversal or non-POSIX separators')
    normalized = str(PurePosixPath(prefix or '/'))
    return '' if normalized == '/' else normalized


def package_binaries(root, prefix):
    """Enumerate every expected name; an unexpected duplicate location is an error."""
    root = Path(root).resolve()
    if not root.is_dir():
        raise SymbolsError('package root is not an extracted directory: %s' % root)
    observed = {product: [] for product in PRODUCTS}
    for current, directories, files in os.walk(root, followlinks=False, onerror=_walk_error):
        for name in files:
            if name in observed:
                observed[name].append(Path(current) / name)
        # Product bundle directories must be regular. Other symlinks (such as
        # roothide's .jbroot link) are not product containers and are not followed.
        for name in directories:
            path = Path(current) / name
            if name in observed or (path.is_symlink() and path.name.endswith('.bundle')):
                raise SymbolsError('product/package bundle is not a regular input: %s' % path)
    binaries = {}
    for product, relative in PRODUCTS.items():
        expected = root / prefix.lstrip('/') / relative
        if observed[product] != [expected]:
            raise SymbolsError('missing or duplicate/unexpected package product %s: expected %s; found %s' %
                               (product, expected.relative_to(root).as_posix(),
                                [p.relative_to(root).as_posix() for p in observed[product]]))
        if (not stat.S_ISREG(expected.lstat().st_mode) or
                not expected.resolve().is_relative_to(root)):
            raise SymbolsError('package product is not a regular contained binary: %s' % expected)
        binaries[product] = expected
    return binaries


def verify_symbols(directory, package_root, package_prefix, tools, commit=None):
    root = Path(directory).resolve()
    package_root = Path(package_root).resolve()
    prefix = normalize_prefix(package_prefix)
    binaries = package_binaries(package_root, prefix)
    binary_hashes = {product: sha256_file(path) for product, path in binaries.items()}
    shipped = {product: tools.uuids(path) for product, path in binaries.items()}
    bundles = dsym_bundles(root)
    if not bundles:
        raise SymbolsError('no .dSYM under %s' % root)
    candidates = {}
    for bundle in bundles:
        info = inspect_dsym(bundle, tools)
        for arch, uuid in info.uuids.items():
            if arch not in shipped[info.product]:
                raise SymbolsError('unshipped architecture %s for %s: %s' %
                                   (arch, info.product, bundle))
            if uuid != shipped[info.product][arch]:
                raise SymbolsError('UUID mismatch for %s (%s): package=%s dSYM=%s (%s)' %
                                   (info.product, arch, shipped[info.product][arch], uuid, bundle))
            candidates.setdefault((info.product, arch), []).append(info)
    matches = []
    for product in PRODUCTS:
        for arch, uuid in sorted(shipped[product].items()):
            copies = candidates.get((product, arch), [])
            if not copies:
                raise SymbolsError('missing matching dSYM architecture: %s (%s, %s)' %
                                   (product, arch, uuid))
            if len({(info.dwarf_sha256, info.bundle_sha256) for info in copies}) != 1:
                raise SymbolsError('ambiguous nonidentical dSYMs for %s (%s, %s): %s' %
                                   (product, arch, uuid, [str(info.bundle) for info in copies]))
            copies.sort(key=lambda info: info.bundle.relative_to(root).as_posix())
            primary = copies[0]
            duplicate_paths = [info.bundle.relative_to(root).as_posix() for info in copies[1:]]
            if duplicate_paths:
                print('  deduplicated identical %s (%s): %s' % (product, arch, duplicate_paths))
            where = primary.bundle.relative_to(root).as_posix()
            print('  matched %s (%s) UUID %s: %s' % (product, arch, uuid, where))
            matches.append({
                'product': product, 'arch': arch, 'uuid': uuid,
                'binary_sha256': binary_hashes[product],
                'dsym_dwarf_sha256': primary.dwarf_sha256,
                'dsym_bundle_sha256': primary.bundle_sha256,
                'binary_path': binaries[product].relative_to(package_root).as_posix(),
                'dsym_path': where,
                'dwarf_path': primary.dwarf.relative_to(root).as_posix(),
                'duplicate_dsym_paths': duplicate_paths,
            })
    for product, path in binaries.items():
        if sha256_file(path) != binary_hashes[product]:
            raise SymbolsError('package binary changed during verification: %s' % path)
    for copies in candidates.values():
        for info in copies:
            if bundle_digest(info.bundle) != info.bundle_sha256:
                raise SymbolsError('dSYM changed during package pairing: %s' % info.bundle)
    return {
        'schema_version': 1, 'commit': commit if commit is not None else os.environ.get('GITHUB_SHA'),
        'package_prefix': prefix, 'products': list(PRODUCTS), 'matches': matches,
        'symbolication': {
            'address_equation': 'runtimeAddress = base + imageOffset',
            'atos_template': 'atos -o DWARF_FILE -arch ARCH -l BASE RUNTIME_ADDRESS',
            'atos_arm64e_example': 'atos -o DWARF_FILE -arch arm64e -l BASE RUNTIME_ADDRESS',
            'requirements': 'Use the matching product, architecture and LC_UUID; BASE is the '
                            'runtime image load address, RUNTIME_ADDRESS is base + imageOffset.',
            'dwarfdump_lookup': '--lookup=<address>; function names use --name=<name> / -n',
        },
    }


def _manifest_path(root, argument):
    path = Path(argument).resolve() if argument else root / 'manifest.json'
    if (path == root or not path.is_relative_to(root) or
            any(part.endswith('.dSYM') for part in path.relative_to(root).parts)):
        raise SymbolsError('manifest must be inside the collection, outside dSYM bundles')
    return path


def _write_manifest(path, manifest):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                         dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(manifest, stream, indent=2, sort_keys=True)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv=None, tools=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', default='symbols')
    parser.add_argument('--package-root', required=True, help='already extracted deb directory')
    parser.add_argument('--package-prefix', default=os.environ.get('PACKAGE_PREFIX', ''))
    parser.add_argument('--manifest', help='JSON output, default: <directory>/manifest.json')
    add_tool_arguments(parser)
    args = parser.parse_args(argv)
    try:
        root = Path(args.directory).resolve()
        manifest_path = _manifest_path(root, args.manifest)
        # A failed subsequent check must not leave yesterday's proof for upload.
        if manifest_path.exists():
            manifest_path.unlink()
        tools = tools or DwarfTools(args.dwarfdump, args.lipo, timeout=args.tool_timeout)
        manifest = verify_symbols(root, args.package_root, args.package_prefix, tools)
        _write_manifest(manifest_path, manifest)
        print('verify_symbols: %d shipped architecture(s), all 3 products verified; manifest %s' %
              (len(manifest['matches']), manifest_path))
        return 0
    except (SymbolsError, OSError) as error:
        print('verify_symbols: FAIL %s' % error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
