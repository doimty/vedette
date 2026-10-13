#!/usr/bin/env python3
"""List re-entry: source contracts on Linux; extracted Foundation methods on Darwin.

Only the four production lifecycle/reload methods are embedded, byte for byte.
Catalog/search/rule signals enter that real reload method; no UIKit, enumeration,
search algorithm, rule grouping or real Preferences implementation is exercised.
The native host assumes super clears table indexes BEFORE releasing _specifiers,
then rebuilds. This is a test model, not an observation of Apple's implementation.

  python3 -B tests/test_list_reentry.py --static-only
  python3 -B tests/test_list_reentry.py --require-native   # Darwin
  python3 -B tests/test_list_reentry.py --sdk /path/iPhoneOS.sdk

SDK checking is syntax-only for arm64/arm64e, never execution. Without Darwin the
normal exit is 77 (or 1 with --require-native); --static-only explicitly exits 0.
Every Darwin negative must compile and exit 86 with its class assertion marker;
compile/link errors, crashes and other exits are failures, not killed mutants.
"""
import argparse
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OLD = 'b03088431c263a2855da1a6d7efc58dc98b046e5'
METHODS = ('viewWillAppear', 'viewDidAppear', 'viewWillDisappear', 'reloadSpecifiers')
CONTROLLERS = {
    'VDTDaemonListController': (
        'vedetteprefs/ChoicyPreferences/CHPDaemonListController.m',
        '_vdtVisible', '_vdtNeedsReload',
        '[[VDTDaemonList sharedInstance] updateDaemonListIfNeeded];', 'DAEMON'),
    'VDTExtensionListController': (
        'vedetteprefs/VDTExtensionListController.m',
        'self.catalogVisible', 'self.catalogNeedsReload',
        '[[VDTExtensionCatalog sharedInstance] ensureLoaded];', 'EXTENSION'),
}
# Preserve offsets while excluding comments and quoted text from brace matching.
LEXEMES = re.compile(r'//[^\n]*|/\*.*?\*/|@?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
COMMENTS = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)


def extract(source):
    masked = LEXEMES.sub(lambda m: ' ' * len(m.group()), source)
    result = {}
    for name in METHODS:
        signature = r'^-\s*\(\s*void\s*\)\s*' + name
        signature += (r'\s*:\s*\(\s*BOOL\s*\)\s*animated' if name != 'reloadSpecifiers' else r'\b')
        hits = list(re.finditer(signature + r'\s*\{', masked, re.M))
        if len(hits) != 1:
            raise ValueError(f'{name}: expected one method definition, found {len(hits)}')
        hit = hits[0]
        depth = 1
        end = hit.end()
        while end < len(masked) and depth:
            depth += (masked[end] == '{') - (masked[end] == '}')
            end += 1
        if depth:
            raise ValueError(f'{name}: unbalanced method')
        # Slice the ORIGINAL source, not the comment-stripped/masked version.
        result[name] = source[hit.start():end]
    return result


def compact(text):
    return re.sub(r'\s+', '', COMMENTS.sub('', text))


def source_contract(name, methods):
    _, visible, dirty, ensure, _ = CONTROLLERS[name]
    # Source-only operation/order contract. These strings are NEVER compiled.
    expected = {
        'viewWillAppear': [visible + '=NO;', dirty + '=YES;',
                           '[super viewWillAppear:animated];', ensure],
        'viewDidAppear': ['[super viewDidAppear:animated];', visible + '=YES;',
                          f'if ({dirty}) [self reloadSpecifiers];'],
        'viewWillDisappear': [visible + '=NO;', '[super viewWillDisappear:animated];'],
        'reloadSpecifiers': [dirty + '=YES;', f'if (!{visible}) return;',
                             dirty + '=NO;', '[super reloadSpecifiers];'],
    }
    for selector, operations in expected.items():
        body = methods[selector].split('{', 1)[1].rsplit('}', 1)[0]
        if compact(body) != compact(''.join(operations)):
            raise AssertionError(f'{name}.{selector}: final no-nil lifecycle contract violated')


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'mutation anchor not unique: {old!r}')
    return text.replace(old, new, 1)


def negatives(current, original):
    # Each negative changes just one class, so BOTH controllers are independently
    # exercised, including the two actual b030884 method sets.
    for name, (_, visible, dirty, _, _) in CONTROLLERS.items():
        yield 'old-b030884-' + name, name, {**current, name: original[name]}
        edits = [
            ('willAppear-nil', 'viewWillAppear', dirty + ' = YES;',
             '_specifiers = nil;\n    ' + dirty + ' = YES;'),
            ('hidden-reload-nil', 'reloadSpecifiers', dirty + ' = YES;',
             '_specifiers = nil;\n    ' + dirty + ' = YES;'),
            ('no-visible-guard', 'reloadSpecifiers', f'if (!{visible}) return;', ''),
            ('dirty-not-set', 'reloadSpecifiers', dirty + ' = YES;', ''),
            ('dirty-not-cleared', 'reloadSpecifiers', dirty + ' = NO;', ''),
            ('didAppear-no-reload', 'viewDidAppear', f'if ({dirty}) [self reloadSpecifiers];', ''),
            ('visible-reload-nil', 'reloadSpecifiers', '[super reloadSpecifiers];',
             '_specifiers = nil;\n    [super reloadSpecifiers];'),
            ('no-super-reload', 'reloadSpecifiers', '[super reloadSpecifiers];', ''),
        ]
        edits += [('no-super-' + s, s, f'[super {s}:animated];', '(void)animated;')
                  for s in METHODS[:3]]
        for label, selector, old, new in edits:
            changed = dict(current[name])
            changed[selector] = replace_once(changed[selector], old, new)
            yield label + '-' + name, name, {**current, name: changed}


def render(methods):
    template = (ROOT / 'tests/test_list_reentry_native.mm').read_text()
    for name, (_, _, _, _, marker) in CONTROLLERS.items():
        slot = '/* VDT_EXTRACTED_' + marker + '_METHODS */'
        if template.count(slot) != 1:
            raise ValueError('missing or repeated fixture slot: ' + slot)
        template = template.replace(slot, '\n\n'.join(methods[name][s] for s in METHODS))
    return template


def run(command, **kwargs):
    return subprocess.run(command, check=True, timeout=120, **kwargs)


def native_check(directory, current, cases):
    clang = shutil.which('clang++')
    if not clang:
        raise RuntimeError('Darwin clang++ unavailable')
    for label, target, methods in [('baseline', None, current), *cases]:
        source = directory / (label + '.mm')
        binary = directory / label
        source.write_text(render(methods))
        # NO source_contract call here: compile and execute every negative.
        run([clang, '-std=c++17', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
             '-Werror', '-framework', 'Foundation', str(source), '-o', str(binary)])
        result = subprocess.run([str(binary)] + ([target] if target else []),
                                capture_output=True, text=True, timeout=30)
        if target:
            marker = 'ASSERTION FAILED: ' + target + ' '
            if result.returncode != 86 or marker not in result.stderr:
                raise RuntimeError(f'{label}: expected assertion exit 86, got '
                                   f'{result.returncode}\n{result.stdout}{result.stderr}')
            print('KILLED runtime:', label, result.stderr.strip(), flush=True)
        elif result.returncode:
            raise RuntimeError(f'native baseline exit {result.returncode}\n'
                               f'{result.stdout}{result.stderr}')
        else:
            print(result.stdout.strip(), flush=True)
    print(f'PASS Foundation execution + {len(cases)} assertion negatives; NOT UIKit/device')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--static-only', action='store_true')
    mode.add_argument('--require-native', action='store_true')
    parser.add_argument('--sdk', type=Path)
    args = parser.parse_args()
    current, original = {}, {}
    for name, (path, *_) in CONTROLLERS.items():
        current[name] = extract((ROOT / path).read_bytes().decode('utf-8'))
        original[name] = extract(run(['git', 'show', OLD + ':' + path], cwd=ROOT,
                                     capture_output=True, text=True).stdout)
        source_contract(name, current[name])
    cases = list(negatives(current, original))
    for label, target, methods in cases:
        try:
            source_contract(target, methods[target])
        except AssertionError:
            pass
        else:
            raise AssertionError('source negative survived: ' + label)
    # Extraction itself must not count commented braces or methods in comments.
    sample = '// - (void)reloadSpecifiers { }\n' + '\n'.join(current[next(iter(current))].values())
    if extract(sample) != current[next(iter(current))]:
        raise AssertionError('extractor failed comment/offset preservation')
    print(f'PASS source-only: both controllers, b030884 + {len(cases)-2} mutants rejected; '
          'NOT native execution', flush=True)
    with tempfile.TemporaryDirectory(prefix='vdt-list-reentry-') as tmp:
        directory = Path(tmp)
        if args.sdk:
            if not args.sdk.is_dir():
                raise ValueError('SDK directory does not exist: ' + str(args.sdk))
            source = directory / 'baseline.mm'
            source.write_text(render(current))
            for arch in ('arm64', 'arm64e'):
                run(['clang++', '-target', arch + '-apple-ios15.0', '-isysroot',
                     str(args.sdk), '-std=c++17', '-fobjc-arc', '-fblocks',
                     '-Wall', '-Wextra', '-Werror', '-fsyntax-only', str(source)])
                print('PASS SDK syntax:', arch, '(NOT execution)', flush=True)
        if args.static_only:
            print('SKIP Foundation runtime: explicitly --static-only (source-only exit 0)')
            return 0
        if platform.system() != 'Darwin':
            print('SKIP Foundation runtime + runtime negatives: Darwin required; NOT PASS')
            return 1 if args.require_native else 77
        native_check(directory, current, cases)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (AssertionError, ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(1)
