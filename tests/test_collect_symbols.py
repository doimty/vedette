#!/usr/bin/env python3
"""Fail-closed symbol CI contracts, with explicit LLVM/Apple CLI fixtures.

FixtureRunner accepts only the real argv forms used by these scripts and returns
UUID/architecture and root-DIE output in dwarfdump/lipo's documented format. It
is not a Mach-O/DWARF parser and never pretends --lookup takes function names.
Portable fixture passes are distinct from the separately labelled macOS test,
which compiles tiny temporary images and exercises the actual Xcode tools. Even
that test is not a substitute for checking the project's extracted release deb.
"""
from pathlib import Path
import ast
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import copy
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ci import collect_symbols as collect
from ci import verify_symbols as verify

VALID_DEBUG_INFO = '''{path}:\tfile format Mach-O {arch}

.debug_info contents:
0x00000000: Compile Unit: length = 0x00000050, format = DWARF32, version = 0x0004, abbr_offset = 0x0000, addr_size = 0x08 (next unit at 0x00000054)

0x0000000b: DW_TAG_compile_unit
              DW_AT_producer ("Apple clang version 16.0.0")
              DW_AT_language (DW_LANG_C99)
              DW_AT_name ("fixture.c")
              DW_AT_stmt_list (0x00000000)
              DW_AT_comp_dir ("/tmp/fixture with spaces")
              DW_AT_low_pc (0x0000000100003f80)
              DW_AT_high_pc (0x0000000100003fa0)
'''
NO_DEBUG_INFO = '{path}:\tfile format Mach-O {arch}\n\n.debug_info contents:\n'
DECLARATION_ONLY = '''{path}:\tfile format Mach-O {arch}
.debug_info contents:
0x0000000b: DW_TAG_compile_unit
              DW_AT_name ("types.h")
              DW_AT_language (DW_LANG_C99)
'''


class FixtureRunner:
    """An exhaustive argv contract: unknown file/flag/order is a test failure."""
    dwarfdump = 'fixture tool directory/dwarfdump'
    lipo = 'fixture tool directory/lipo'

    def __init__(self):
        self.files = {}
        self.calls = []

    def register(self, path, identities, data, debug=VALID_DEBUG_INFO):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.files[hashlib.sha256(data).hexdigest()] = {
            'archs': list(identities), 'uuids': dict(identities), 'debug': debug,
            'errors': {},
        }
        return path

    def record(self, path):
        digest = verify.sha256_file(path)
        if digest not in self.files:
            raise AssertionError('unregistered fixture file: %s' % path)
        return self.files[digest]

    def __call__(self, command):
        self.calls.append(list(command))
        path = Path(command[-1])
        record = self.record(path)
        if command == [self.lipo, '-archs', str(path)]:
            mode, arch = 'archs', None
            output = record.get('arch_output', ' '.join(record['archs']) + '\n')
        elif command == [self.dwarfdump, '--uuid', str(path)]:
            mode, arch = 'uuid', None
            output = record.get('uuid_output', ''.join(
                'UUID: %s (%s) %s\n' % (value, arch, path)
                for arch, value in record['uuids'].items()))
        elif (len(command) == 5 and command[0] == self.dwarfdump and
              command[1].startswith('--arch=') and command[2:-1] == ['--verify', '--quiet']):
            mode, arch = 'verify', command[1].split('=', 1)[1]
            output = ''  # --quiet suppresses successful verifier output.
        elif (len(command) == 5 and command[0] == self.dwarfdump and
              command[1].startswith('--arch=') and
              command[2:-1] == ['--debug-info', '--recurse-depth=0']):
            mode, arch = 'debug-info', command[1].split('=', 1)[1]
            text = record['debug']
            if isinstance(text, dict):
                text = text[arch]
            output = text.format(path=path, arch=arch)
        else:
            raise AssertionError('not a real supported dwarfdump/lipo argv: %r' % command)
        if arch is not None and arch not in record['archs']:
            raise AssertionError('arch filter not in the fixture: %s' % arch)
        failure = record['errors'].get((mode, arch), record['errors'].get(mode))
        if failure:
            status, stdout, stderr = failure
            return subprocess.CompletedProcess(command, status, stdout, stderr)
        return subprocess.CompletedProcess(command, 0, output, '')


@contextmanager
def in_directory(path):
    previous = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


def invoke(main, args, tools):
    stdout, stderr = io.StringIO(), io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        status = main(args, tools=tools)
    return status, stdout.getvalue(), stderr.getvalue()


class SymbolsFixtureCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Vedette symbols with spaces ')
        self.tmp = Path(self.temp.name)
        self.obj = self.tmp / '.theos/obj'
        self.prefs = self.tmp / 'subprojects/prefs with spaces/deep/.theos/obj'
        self.ctl = self.tmp / 'nicectl/.theos/obj'
        self.roots = [self.obj, self.prefs, self.ctl]
        for root in self.roots:
            root.mkdir(parents=True)
        self.out = self.tmp / 'symbols with spaces'
        self.package = self.tmp / 'extracted deb with spaces'
        self.package.mkdir()
        self.runner = FixtureRunner()
        self.tools = verify.DwarfTools(self.runner.dwarfdump, self.runner.lipo, runner=self.runner)

    def tearDown(self):
        self.temp.cleanup()

    def identities(self, product, arches=('arm64', 'arm64e')):
        return {arch: str(uuid.uuid5(uuid.NAMESPACE_URL, product + '/' + arch)).upper()
                for arch in arches}

    def image(self, root, relative, product, arches=('arm64e',), debug=VALID_DEBUG_INFO, seed=''):
        identities = self.identities(product, arches)
        image = root / relative / product
        self.runner.register(image, identities, b'BUILD-MACHO\0' +
                             (product + ','.join(arches) + seed).encode())
        bundle = image.parent / (product + '.dSYM')
        payload = bundle / 'Contents/Resources/DWARF' / product
        self.runner.register(payload, identities, b'DWARF-MACHO\0' +
                             (product + ','.join(arches) + seed).encode(), debug)
        (bundle / 'Contents/Info.plist').write_bytes(b'fixture plist contents\n')
        return image, bundle

    def shipped(self, prefix='', arches=('arm64', 'arm64e')):
        paths = {}
        for product, relative in verify.PRODUCTS.items():
            path = self.package / prefix.lstrip('/') / relative
            self.runner.register(path, self.identities(product, arches), b'SHIPPED-MACHO\0' +
                                 (product + ','.join(arches)).encode())
            paths[product] = path
        return paths

    def full_inputs(self, prefix='', arches=('arm64', 'arm64e')):
        self.shipped(prefix, arches)
        inputs = []
        for product, root in zip(verify.PRODUCTS, self.roots):
            for arch in arches:
                _, bundle = self.image(root, 'release with spaces/' + arch, product, (arch,))
                inputs.append(bundle)
        return inputs

    def run_collect(self, roots=None, out=None, require=True):
        args = ['--out', str(out or self.out)]
        for root in self.roots if roots is None else roots:
            args += ['--objects', str(root)]
        if require:
            args.append('--require')
        return invoke(collect.main, args, self.tools)

    def run_verify(self, prefix='', directory=None, extra=None):
        args = [str(directory or self.out), '--package-root', str(self.package),
                '--package-prefix', prefix]
        args += extra or []
        return invoke(verify.main, args, self.tools)

    def payload(self, bundle):
        return bundle / 'Contents/Resources/DWARF' / bundle.name.removesuffix('.dSYM')

    def collected(self, product):
        return sorted(self.out.rglob(product + '.dSYM'))

    def rewrite(self, path, data):
        record = copy.deepcopy(self.runner.record(path))
        path.write_bytes(data)
        self.runner.files[hashlib.sha256(data).hexdigest()] = record


class CollectSymbols(SymbolsFixtureCase):
    def test_all_nested_architectures_products_paths_and_images_survive(self):
        inputs = self.full_inputs()
        images = [bundle.parent / bundle.name.removesuffix('.dSYM') for bundle in inputs]
        before = {path: path.read_bytes() for path in images}
        status, output, error = self.run_collect()
        self.assertEqual(status, 0, output + error)
        self.assertIn('6/6 bundle(s) collected', output)
        self.assertEqual(before, {path: path.read_bytes() for path in images})
        for index, (product, root) in enumerate(zip(verify.PRODUCTS, self.roots)):
            copies = self.collected(product)
            self.assertEqual(len(copies), 2)
            for source in [p for p in inputs if p.name == product + '.dSYM']:
                expected = self.out / product / ('root-%03d' % index) / source.relative_to(root)
                self.assertTrue(expected.is_dir(), expected)
                self.assertEqual(verify.bundle_digest(source), verify.bundle_digest(expected))
        self.assertTrue(all('--lookup' not in call for call in self.runner.calls))
        self.assertTrue(all('dsymutil' not in call for call in self.runner.calls))

    def test_relative_root_is_normalized_and_output_default_excludes_vendor(self):
        self.image(self.obj, 'arm64e', 'Vedette.dylib')
        self.image(self.tmp / 'theos/vendor/.theos/obj', 'arm64e', 'Vedette.dylib')
        self.image(self.tmp / 'vendor/child/.theos/obj', 'arm64e', 'VedettePrefs')
        self.image(self.tmp, 'unrelated/arm64e', 'vedette-nicectl')
        with in_directory(self.tmp):
            status, output, error = invoke(collect.main, ['--out', 'symbols', '--require'], self.tools)
            target = collect.destination(Path('.theos/obj/arm64e/Vedette.dylib.dSYM'),
                                         self.obj, 'symbols')
        self.assertEqual(status, 0, output + error)
        self.assertTrue(target.is_dir())
        self.assertEqual(len(list((self.tmp / 'symbols').rglob('*.dSYM'))), 1)
        # An explicitly different output is a different collection, not the
        # first one's exclude root. Remove that fixture before the broad scan.
        shutil.rmtree(self.tmp / 'symbols')
        # Even an explicit overly broad root cannot pull vendor/Theos symbols.
        status, output, error = self.run_collect(roots=[self.tmp], out=self.tmp / 'broad output')
        self.assertEqual(status, 0, output + error)
        self.assertIn('2/2 bundle(s) collected', output)
        self.assertNotIn('-> ' + str(self.tmp / 'broad output/theos'), output)

    def test_arbitrary_arch_and_bundle_subdirectory_are_not_guessed(self):
        _, source = self.image(self.prefs, 'scheme/deeper/x86_64h/VedettePrefs.bundle',
                               'VedettePrefs', ('x86_64h',))
        status, output, error = self.run_collect(roots=[self.prefs])
        self.assertEqual(status, 0, output + error)
        target = self.out / 'VedettePrefs/root-000' / source.relative_to(self.prefs)
        self.assertTrue(target.is_dir())
        self.assertIn('(x86_64h)', output)

    def test_unknown_products_ignored_but_no_selected_required_is_failure(self):
        unknown = self.obj / 'arm64e/AltList.framework.dSYM/Contents/Resources/DWARF'
        unknown.mkdir(parents=True)
        (unknown / 'AltList').write_bytes(b'x' * 4096)
        status, output, error = self.run_collect(require=False)
        self.assertEqual(status, 0, output + error)
        self.assertIn('ignored non-product', output)
        self.assertFalse(self.runner.calls)
        self.assertEqual(self.run_collect(require=True)[0], 1)
        self.assertEqual(self.run_collect(roots=[self.tmp / 'missing root'])[0], 1)

    def test_small_tool_proven_payload_is_not_filtered_by_size(self):
        _, source = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        self.assertLess(self.payload(source).stat().st_size, 1024)
        self.assertEqual(self.run_collect()[0], 0)

    def test_large_file_without_debug_info_fails_even_without_require(self):
        _, source = self.image(self.obj, 'arm64e', 'Vedette.dylib', debug=NO_DEBUG_INFO)
        payload = self.payload(source)
        self.rewrite(payload, b'large but stripped' * 4096)
        self.runner.record(payload)['errors'][('verify', 'arm64e')] = (1, '', 'no usable DWARF')
        for require in (False, True):
            status, output, error = self.run_collect(require=require)
            self.assertEqual(status, 1, output + error)
            self.assertIn('no usable DWARF', error)
            self.assertFalse(self.out.exists())

    def test_preflight_failure_copies_nothing_and_never_mutates_sources(self):
        _, valid = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        _, broken = self.image(self.prefs, 'arm64e', 'VedettePrefs')
        self.runner.record(self.payload(broken))['errors'][('verify', 'arm64e')] = (1, '', 'malformed')
        before = verify.bundle_digest(valid)
        status, output, error = self.run_collect()
        self.assertEqual(status, 1, output + error)
        self.assertFalse(self.out.exists())
        self.assertEqual(verify.bundle_digest(valid), before)
        self.assertTrue(broken.is_dir())

    def test_overlapping_roots_deduplicated_and_identical_rerun_is_idempotent(self):
        self.image(self.obj, 'arm64e', 'Vedette.dylib')
        roots = [self.obj, self.obj, self.tmp]
        self.assertEqual(self.run_collect(roots=roots)[0], 0)
        status, output, error = self.run_collect(roots=roots)
        self.assertEqual(status, 0, output + error)
        self.assertIn('unchanged identical', output)
        self.assertIn('1/1 bundle(s) collected', output)
        self.assertEqual(len(self.collected('Vedette.dylib')), 1)

    def test_different_existing_destination_never_overwritten(self):
        self.image(self.obj, 'arm64e', 'Vedette.dylib')
        self.assertEqual(self.run_collect()[0], 0)
        target = self.collected('Vedette.dylib')[0]
        altered = self.payload(target)
        altered.write_bytes(b'different existing payload')
        _, fresh = self.image(self.prefs, 'arm64e', 'VedettePrefs')
        status, output, error = self.run_collect()
        self.assertEqual(status, 1, output + error)
        self.assertIn('different content', error)
        self.assertEqual(altered.read_bytes(), b'different existing payload')
        self.assertFalse(self.collected('VedettePrefs'))
        self.assertTrue(fresh.is_dir())

    def test_output_root_pruned_before_walk_including_reentry(self):
        self.image(self.obj, 'arm64e', 'Vedette.dylib')
        output_dir = self.obj / 'nested output'
        for _ in range(2):
            status, output, error = self.run_collect(out=output_dir)
            self.assertEqual(status, 0, output + error)
            self.assertIn('1/1 bundle(s) collected', output)
        self.assertEqual(len(list(output_dir.rglob('*.dSYM'))), 1)
        status, _, _ = self.run_collect(roots=[output_dir], out=output_dir)
        self.assertEqual(status, 1)  # --require + only excluded output.

    def test_output_inside_input_bundle_is_failure_without_self_copy(self):
        _, source = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        status, output, error = self.run_collect(out=source / 'recursive output')
        self.assertEqual(status, 1, output + error)
        self.assertIn('self-copy prohibited', error)
        self.assertFalse((source / 'recursive output').exists())

    def test_bad_dwarf_payload_names_and_multiple_files_are_not_copied(self):
        _, source = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        payload = self.payload(source)
        (payload.parent / 'unexpected').write_bytes(b'also a file')
        self.assertEqual(self.run_collect()[0], 1)
        (payload.parent / 'unexpected').unlink()
        payload.rename(payload.with_name('wrong product name'))
        self.assertEqual(self.run_collect()[0], 1)

    def test_input_changed_while_tools_read_it_fails_before_copy(self):
        _, source = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        # Compare resolved paths: macOS reports temp dirs under /private/var.
        payload = self.payload(source).resolve()

        def changing_runner(command):
            result = self.runner(command)
            if '--verify' in command and Path(command[-1]).resolve() == payload:
                payload.write_bytes(b'input changed during inspection')
            return result

        self.tools.runner = changing_runner
        status, output, error = self.run_collect()
        self.assertEqual(status, 1, output + error)
        self.assertIn('dSYM changed during verification', error)
        self.assertFalse(self.out.exists())

    def test_dsym_file_instead_of_directory_fails(self):
        (self.obj / 'Vedette.dylib.dSYM').write_bytes(b'not a bundle directory')
        status, output, error = self.run_collect()
        self.assertEqual(status, 1, output + error)
        self.assertIn('dSYM path is not a directory', error)

    def test_symlink_payload_bundle_and_destination_escape_fail(self):
        _, source = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        payload = self.payload(source)
        external = self.tmp / 'external original'
        external.write_bytes(payload.read_bytes())
        original = payload.read_bytes()
        payload.unlink()
        try:
            payload.symlink_to(external)
        except OSError as error:
            self.skipTest('host symlink creation privilege unavailable: %s' % error)
        status, output, error = self.run_collect()
        self.assertEqual(status, 1, output + error)
        self.assertIn('non-regular file inside dSYM', error)
        self.assertEqual(external.read_bytes(), original)
        payload.unlink()
        payload.write_bytes(original)
        # A selected bundle alias is also rejected, not followed into another tree.
        alias = self.prefs / 'Vedette.dylib.dSYM'
        alias.symlink_to(source, target_is_directory=True)
        self.assertEqual(self.run_collect()[0], 1)
        alias.unlink()
        outside = self.tmp / 'outside collection'
        outside.mkdir()
        (self.out / 'Vedette.dylib').mkdir(parents=True)
        (self.out / 'Vedette.dylib/root-000').symlink_to(outside, target_is_directory=True)
        status, output, error = self.run_collect()
        self.assertEqual(status, 1, output + error)
        self.assertIn('destination escapes collection', error)
        self.assertFalse(list(outside.iterdir()))


class VerifySymbols(SymbolsFixtureCase):
    def ready(self, prefix='', arches=('arm64', 'arm64e')):
        inputs = self.full_inputs(prefix, arches)
        status, output, error = self.run_collect()
        self.assertEqual(status, 0, output + error)
        return inputs

    def test_exact_three_product_pairs_and_manifest_both_prefixes(self):
        for prefix in ('', '/var/jb'):
            with self.subTest(prefix=prefix):
                if self.out.exists():
                    shutil.rmtree(self.out)
                shutil.rmtree(self.package)
                self.package.mkdir()
                self.ready(prefix)
                with mock.patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40}):
                    status, output, error = self.run_verify(prefix)
                self.assertEqual(status, 0, output + error)
                manifest = json.loads((self.out / 'manifest.json').read_text(encoding='utf-8'))
                self.assertEqual(manifest['commit'], 'a' * 40)
                self.assertEqual(manifest['package_prefix'], prefix)
                self.assertEqual(len(manifest['matches']), 6)
                self.assertEqual({entry['product'] for entry in manifest['matches']}, set(verify.PRODUCTS))
                for entry in manifest['matches']:
                    self.assertEqual(entry['uuid'], self.identities(entry['product'])[entry['arch']])
                    self.assertEqual(entry['binary_sha256'], verify.sha256_file(self.package / entry['binary_path']))
                    self.assertEqual(entry['dsym_dwarf_sha256'], verify.sha256_file(self.out / entry['dwarf_path']))
                    self.assertEqual(entry['dsym_bundle_sha256'], verify.bundle_digest(self.out / entry['dsym_path']))
                    self.assertFalse(Path(entry['binary_path']).is_absolute())
                    self.assertFalse(Path(entry['dsym_path']).is_absolute())
                    self.assertFalse(entry['duplicate_dsym_paths'])
                self.assertEqual(manifest['symbolication']['address_equation'],
                                 'runtimeAddress = base + imageOffset')
                self.assertIn('-arch arm64e -l BASE RUNTIME_ADDRESS',
                              manifest['symbolication']['atos_arm64e_example'])
                self.assertIn('--lookup=<address>', manifest['symbolication']['dwarfdump_lookup'])

    def test_shipped_architectures_come_from_binary_not_folder_labels(self):
        self.shipped(arches=('x86_64',))
        for product, root in zip(verify.PRODUCTS, self.roots):
            self.image(root, 'misleading/arm64e', product, ('x86_64',))
        self.assertEqual(self.run_collect()[0], 0)
        status, output, error = self.run_verify()
        self.assertEqual(status, 0, output + error)
        manifest = json.loads((self.out / 'manifest.json').read_text())
        self.assertEqual({entry['arch'] for entry in manifest['matches']}, {'x86_64'})

    def test_wrong_uuid_fails_even_when_good_match_also_exists(self):
        self.ready()
        source = self.collected('Vedette.dylib')[0]
        stale = self.out / 'stale copy/Vedette.dylib.dSYM'
        shutil.copytree(source, stale)
        self.rewrite(self.payload(stale), b'different stale dSYM')
        record = self.runner.record(self.payload(stale))
        record['uuids'] = {arch: '11111111-2222-3333-4444-555555555555'
                           for arch in record['archs']}
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('UUID mismatch', error)
        self.assertFalse((self.out / 'manifest.json').exists())

    def test_missing_architecture_fails_and_stale_manifest_is_removed(self):
        self.ready()
        self.assertEqual(self.run_verify()[0], 0)
        # Remove only one slice, leaving other valid UUIDs and products present.
        for bundle in self.collected('VedettePrefs'):
            if 'arm64e' in self.runner.record(self.payload(bundle))['uuids']:
                shutil.rmtree(bundle)
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('missing matching dSYM architecture: VedettePrefs (arm64e', error)
        self.assertFalse((self.out / 'manifest.json').exists())

    def test_missing_prefs_binary_is_not_satisfied_by_other_two_products(self):
        self.ready()
        (self.package / verify.PRODUCTS['VedettePrefs']).unlink()
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('package product VedettePrefs', error)
        self.assertFalse((self.out / 'manifest.json').exists())

    def test_package_product_extra_location_and_wrong_prefix_fail(self):
        self.ready('/var/jb')
        self.assertEqual(self.run_verify('')[0], 1)
        binary = self.package / 'var/jb' / verify.PRODUCTS['Vedette.dylib']
        extra = self.package / 'extra location/Vedette.dylib'
        extra.parent.mkdir()
        shutil.copy2(binary, extra)
        status, output, error = self.run_verify('/var/jb')
        self.assertEqual(status, 1, output + error)
        self.assertIn('duplicate/unexpected package product', error)

    def test_unknown_product_and_extra_unshipped_arch_fail(self):
        self.ready(arches=('arm64e',))
        unknown = self.out / 'unknown/Other.dSYM/Contents/Resources/DWARF'
        unknown.mkdir(parents=True)
        (unknown / 'Other').write_bytes(b'not an enumerated product')
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('unenumerated dSYM product', error)
        shutil.rmtree(self.out / 'unknown')
        _, extra = self.image(self.obj, 'x86_64', 'Vedette.dylib', ('x86_64',))
        shutil.copytree(extra, self.out / 'extra architecture/Vedette.dylib.dSYM')
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('unshipped architecture', error)

    def test_identical_duplicates_are_reported_and_manifest_has_all_sources(self):
        self.ready()
        source = self.collected('Vedette.dylib')[0]
        duplicate = self.out / 'duplicate origin/Vedette.dylib.dSYM'
        shutil.copytree(source, duplicate)
        status, output, error = self.run_verify()
        self.assertEqual(status, 0, output + error)
        self.assertIn('deduplicated identical', output)
        manifest = json.loads((self.out / 'manifest.json').read_text())
        pairs = [entry for entry in manifest['matches'] if entry['duplicate_dsym_paths']]
        self.assertEqual(len(pairs), 1)
        self.assertEqual(len(pairs[0]['duplicate_dsym_paths']), 1)
        self.assertEqual({pairs[0]['dsym_path'], pairs[0]['duplicate_dsym_paths'][0]},
                         {source.relative_to(self.out).as_posix(), duplicate.relative_to(self.out).as_posix()})

    def test_same_uuid_nonidentical_dwarf_or_bundle_metadata_is_ambiguous(self):
        self.ready()
        source = self.collected('Vedette.dylib')[0]
        duplicate = self.out / 'second origin/Vedette.dylib.dSYM'
        shutil.copytree(source, duplicate)
        info = duplicate / 'Contents/Info.plist'
        info.write_bytes(b'different bundle metadata')
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('ambiguous nonidentical dSYMs', error)
        info.write_bytes((source / 'Contents/Info.plist').read_bytes())
        self.rewrite(self.payload(duplicate), b'changed dwarf but same UUID')
        self.assertEqual(self.run_verify()[0], 1)

    def test_empty_or_declaration_only_dwarf_fails_per_arch_not_by_file_size(self):
        self.ready()
        payload = self.payload(self.collected('Vedette.dylib')[0])
        # Rejection comes from the verifier, which is the only authority on
        # whether the debug info is complete; the text pass was removed.
        self.runner.record(payload)['errors'][('verify', 'arm64')] = (1, '', 'malformed debug info')
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('malformed debug info', error)
        payload.unlink()
        self.assertEqual(self.run_verify()[0], 1)

    def test_fat_dsym_checked_each_arch_not_only_first(self):
        self.shipped()
        for product, root in zip(verify.PRODUCTS, self.roots):
            self.image(root, 'fat', product, ('arm64', 'arm64e'))
        self.assertEqual(self.run_collect()[0], 0)
        self.assertEqual(self.run_verify()[0], 0)
        payload = self.payload(self.collected('vedette-nicectl')[0])
        self.runner.record(payload)['errors'][('verify', 'arm64e')] = (1, '', 'malformed DWARF')
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('--arch=arm64e', error)

    def test_uuid_tool_missing_or_malformed_or_duplicate_arch_fails(self):
        self.ready()
        binary = self.package / verify.PRODUCTS['Vedette.dylib']
        record = self.runner.record(binary)
        original = dict(record['uuids'])
        for mode in ('empty', 'missing arch', 'malformed', 'duplicate'):
            with self.subTest(mode=mode):
                record['uuids'] = dict(original)
                record.pop('uuid_output', None)
                if mode == 'empty':
                    record['uuids'] = {}
                elif mode == 'missing arch':
                    record['uuids'].pop('arm64e')
                elif mode == 'malformed':
                    record['uuid_output'] = 'UUID: not-a-uuid (arm64e) %s\n' % binary
                else:
                    record['uuid_output'] = ('UUID: %s (arm64) %s\n' %
                                             (original['arm64'], binary)) * 2
                status, output, error = self.run_verify()
                self.assertEqual(status, 1, output + error)
                self.assertFalse((self.out / 'manifest.json').exists())

    def test_tool_errors_including_verify_stderr_with_exit_zero_fail(self):
        self.ready()
        payload = self.payload(self.collected('VedettePrefs')[0])
        record = self.runner.record(payload)
        for mode in ('archs', 'uuid', ('verify', record['archs'][0]),
                     ('verify', record['archs'][0])):
            with self.subTest(mode=mode):
                record['errors'] = {mode: (1, 'plausible output', 'error: corrupt DWARF')}
                status, output, error = self.run_verify()
                self.assertEqual(status, 1, output + error)
                self.assertIn('tool failed', error)
        record['errors'] = {('verify', record['archs'][0]): (0, '', 'warning: invalid abbreviation')}
        self.assertEqual(self.run_verify()[0], 1)

    def test_empty_collection_and_unsafe_manifest_or_prefix_fail(self):
        self.shipped()
        self.out.mkdir()
        self.assertEqual(self.run_verify()[0], 1)
        self.assertEqual(self.run_verify(extra=['--manifest', str(self.tmp / 'outside.json')])[0], 1)
        self.assertEqual(self.run_verify(extra=['--manifest', str(self.out / 'Other.dSYM/proof.json')])[0], 1)
        for prefix in ('relative/path', '/var/../jb', '/var/./jb', '/var\\jb'):
            self.assertEqual(self.run_verify(prefix)[0], 1)
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            verify.main([str(self.out)], tools=self.tools)
        self.assertEqual(error.exception.code, 2)  # --package-root is compulsory.

    def test_cli_tool_executable_path_is_one_argument_and_python39_syntax(self):
        self.ready()
        with mock.patch.object(verify, 'DwarfTools', return_value=self.tools) as factory:
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = verify.main([str(self.out), '--package-root', str(self.package),
                                      '--dwarfdump', '/tool dir/dwarfdump',
                                      '--lipo', '/tool dir/lipo', '--tool-timeout', '12'])
            self.assertEqual(status, 0, stdout.getvalue() + stderr.getvalue())
            factory.assert_called_once_with('/tool dir/dwarfdump', '/tool dir/lipo', timeout=12.0)
        for path in (ROOT / 'ci/collect_symbols.py', ROOT / 'ci/verify_symbols.py'):
            ast.parse(path.read_text(encoding='utf-8'), feature_version=(3, 9))

    def test_package_changed_after_uuid_probe_is_not_attested(self):
        self.ready()
        binary = self.package / verify.PRODUCTS['Vedette.dylib']
        target = binary.resolve()

        def changing_runner(command):
            result = self.runner(command)
            # Resolved: macOS resolves its temp directory through /private/var.
            if '--uuid' in command and Path(command[-1]).resolve() == target:
                binary.write_bytes(b'changed shipped binary')
            return result

        self.tools.runner = changing_runner
        status, output, error = self.run_verify()
        self.assertEqual(status, 1, output + error)
        self.assertIn('package binary changed during verification', error)
        self.assertFalse((self.out / 'manifest.json').exists())


class ToolRunnerTests(SymbolsFixtureCase):
    def test_default_subprocess_runner_uses_argv_redirection_deadline_and_real_formats(self):
        binary = self.shipped()['Vedette.dylib']

        def subprocess_result(command, **kwargs):
            result = self.runner(command)
            kwargs['stdout'].write(result.stdout.encode('utf-8'))
            kwargs['stderr'].write(result.stderr.encode('utf-8'))
            self.assertNotIn('shell', kwargs)
            self.assertEqual(kwargs['timeout'], 17)
            self.assertEqual(kwargs['env']['LC_ALL'], 'C')
            return subprocess.CompletedProcess(command, result.returncode)

        tools = verify.DwarfTools(self.runner.dwarfdump, self.runner.lipo, timeout=17)
        with mock.patch.object(verify.subprocess, 'run', side_effect=subprocess_result):
            self.assertEqual(tools.uuids(binary), self.identities('Vedette.dylib'))
        self.assertTrue(all(call[-1] == str(binary) for call in self.runner.calls))

    def test_spawn_timeout_and_retained_output_over_budget_fail(self):
        tools = verify.DwarfTools()
        for exception in (FileNotFoundError('missing tool'), subprocess.TimeoutExpired(['dwarfdump'], 1)):
            with self.subTest(exception=exception):
                with mock.patch.object(verify.subprocess, 'run', side_effect=exception):
                    with self.assertRaisesRegex(verify.SymbolsError, 'tool execution failed'):
                        tools.run(['dwarfdump', '--uuid', 'file with spaces'])
        tools = verify.DwarfTools(runner=lambda command: subprocess.CompletedProcess(
            command, 0, 'x' * (verify.MAX_TOOL_OUTPUT_BYTES + 1), ''))
        with self.assertRaisesRegex(verify.SymbolsError, 'output exceeded'):
            tools.run(['fixture'])
        for timeout in (0, -1, float('nan'), float('inf')):
            with self.assertRaisesRegex(verify.SymbolsError, 'positive'):
                verify.DwarfTools(timeout=timeout)

    def test_lipo_and_uuid_inventories_must_agree(self):
        binary = self.shipped()['Vedette.dylib']
        record = self.runner.record(binary)
        for output in ('', 'arm64 arm64', 'Architectures in file: arm64', 'arm64'):
            with self.subTest(output=output):
                record['arch_output'] = output
                with self.assertRaises(verify.SymbolsError):
                    self.tools.uuids(binary)
        record.pop('arch_output')
        record['uuid_output'] = ''.join('UUID: %s (%s) %s\n' % (value.lower(), arch, binary)
                                       for arch, value in record['uuids'].items())
        self.assertEqual(self.tools.uuids(binary), self.identities('Vedette.dylib'))

    def test_dwarf_ranges_must_be_nonempty_and_zero_code_range_fails(self):
        # Extent and range validity belong to dwarfdump --verify, which walks the
        # full DIE graph. This test used to re-derive it from the --debug-info
        # text, but at --recurse-depth=0 the tool prints neither children nor
        # DW_AT_* attributes, so that reading was an assumption rather than
        # evidence. What this pass must still prove is the presence of compile
        # units; a payload with none cannot describe any code.
        _, bundle = self.image(self.obj, 'arm64e', 'Vedette.dylib')
        payload = self.payload(bundle)
        record = self.runner.record(payload)
        self.tools.verify_dwarf(payload, 'arm64e')
        record['errors'][('verify', 'arm64e')] = (1, '', 'malformed DWARF')
        with self.assertRaisesRegex(verify.SymbolsError, 'malformed DWARF'):
            self.tools.verify_dwarf(payload, 'arm64e')

    def test_uuid_output_for_a_different_path_fails(self):
        binary = self.shipped()['Vedette.dylib']
        record = self.runner.record(binary)
        record['uuid_output'] = ''.join('UUID: %s (%s) other input path\n' % (value, arch)
                                       for arch, value in record['uuids'].items())
        with self.assertRaisesRegex(verify.SymbolsError, 'different input'):
            self.tools.uuids(binary)

    def test_runner_type_contract_and_default_output_budget_fail_closed(self):
        for result in (object(), subprocess.CompletedProcess(['fixture'], 0, b'bytes', ''),
                       subprocess.CompletedProcess(['fixture'], None, '', '')):
            tools = verify.DwarfTools(runner=lambda command: result)
            with self.assertRaisesRegex(verify.SymbolsError, 'tool runner must return'):
                tools.run(['fixture'])

        def too_large(command, **kwargs):
            kwargs['stdout'].write(b'x' * (verify.MAX_TOOL_OUTPUT_BYTES + 1))
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(verify.subprocess, 'run', side_effect=too_large):
            with self.assertRaisesRegex(verify.SymbolsError, 'output exceeded'):
                verify.DwarfTools().run(['fixture'])


@unittest.skipUnless(sys.platform == 'darwin', 'actual Xcode/Mach-O integration requires macOS')
class ActualMacOSToolchain(unittest.TestCase):
    def test_real_uuid_dwarf_and_stripped_file_negative(self):
        commands = {name: shutil.which(name) for name in ('clang', 'dsymutil', 'strip', 'lipo', 'dwarfdump')}
        self.assertTrue(all(commands.values()), 'actual macOS integration requires all Xcode tools')
        arch = platform.machine()
        if arch not in ('arm64', 'x86_64'):
            self.skipTest('unsupported native macOS fixture architecture: ' + arch)
        with tempfile.TemporaryDirectory(prefix='Actual Xcode symbols with spaces ') as temporary:
            root = Path(temporary)
            source = root / 'fixture.c'
            source.write_text('int fixture(int n) { return n + 7; }\nint main(void) { return fixture(0); }\n')
            tools = verify.DwarfTools(commands['dwarfdump'], commands['lipo'])
            objects, symbols, package = root / '.theos/obj', root / 'symbols', root / 'package'

            def build(command):
                # Compilers and dsymutil are not fail-closed tools here: dsymutil
                # reports ordinary warnings on stderr with a zero exit, and only
                # the archived DWARF is inspected by DwarfTools later.
                subprocess.run(command, check=True, capture_output=True)

            for product, relative in verify.PRODUCTS.items():
                image = objects / arch / product
                image.parent.mkdir(parents=True, exist_ok=True)
                command = [commands['clang'], '-g', '-O0', '-arch', arch, str(source), '-o', str(image)]
                if product == 'Vedette.dylib':
                    command.append('-dynamiclib')
                build(command)
                build([commands['dsymutil'], str(image)])
                build([commands['strip'], '-S', str(image)])
                shipped = package / relative
                shipped.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(image, shipped)
            status, output, error = invoke(collect.main, ['--objects', str(objects), '--out', str(symbols),
                                                        '--require'], tools)
            self.assertEqual(status, 0, output + error)
            status, output, error = invoke(verify.main, [str(symbols), '--package-root', str(package)], tools)
            self.assertEqual(status, 0, output + error)
            manifest = json.loads((symbols / 'manifest.json').read_text())
            self.assertEqual(len(manifest['matches']), 3)
            # Real stripped Mach-O still has LC_UUID, but must fail DWARF checks.
            payload = symbols / manifest['matches'][0]['dwarf_path']
            binary = package / manifest['matches'][0]['binary_path']
            shutil.copy2(binary, payload)
            status, output, error = invoke(verify.main, [str(symbols), '--package-root', str(package)], tools)
            self.assertEqual(status, 1, output + error)
            self.assertFalse((symbols / 'manifest.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
