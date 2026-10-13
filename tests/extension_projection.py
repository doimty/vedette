#!/usr/bin/env python3
"""Exact release-resource projection, then the unchanged historical freeze chain.

The readable REGION fixture is anchored in immutable full release 788f43b,
which already includes nice and SpringBoard. Every hunk old side must be unique
in that fixed git blob; the reviewed current side must occur exactly once.
Unknown bytes survive subtraction and fail full-file equality. There is no
current-file hash, function replacement, fuzzy patching or whitespace cleanup.
Only the single control/CI version field and exact host-call addition are
special cases. Historical softremove -> SpringBoard -> release -> nice then
returns the actual 2994 UI21 blob, never an invented intermediate baseline.
"""
from functools import lru_cache
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APPEX_BASE = '2994f24bbc73a6081d958f8f64ba4ff76640b8af'
RELEASE_BASE = '788f43bcb17a2c3890ed8bdeea3f1a97660e13c7'
RELEASE_VERSION = '1.1.12-3'
CANDIDATE_VERSION = '1.1.13-1+rc1'
REVIEWED_PATHS = frozenset({
    'VDTShared.h', 'VDTShared.mm', 'VDTProcessManager.mm', 'VDTProcessManager.h',
    'vedetteprefs/VDTRootListController.m',
    'vedetteprefs/VDTProcessConfiguration.m', 'vedetteprefs/Makefile',
    'Vedette.xm',
    'vedetteprefs/Resources/en.lproj/Localizable.strings',
    'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings',
})
CI_PATH = '.github/workflows/roothide-build.yml'
# Host test calls only. CI setup, build, artifact metadata and triggers stay frozen.
CI_ADDITIONS = (
    '          python3 -B tests/test_extension_contracts.py\n'
    '          python3 -B tests/test_bundle_rules.py\n'
    '          python3 -B tests/test_extensions_native.py --require-native\n'
    '          python3 -B tests/test_memory_policy.py\n'
    '          python3 -B tests/test_resource_apply.py\n'
    '          python3 -B tests/test_resource_manager.py\n'
    '          python3 -B tests/test_resource_ui21.py\n'
    '          python3 -B tests/test_resource_preferences_native.py --require-native\n'
    '          python3 -B tests/test_rebuild_baseline.py\n'
)

@lru_cache(maxsize=None)
def baseline_bytes(path, revision=APPEX_BASE):
    return subprocess.check_output(['git', 'show', revision + ':' + path], cwd=ROOT)

@lru_cache(maxsize=1)
def reviewed_regions():
    path = ROOT / 'tests/fixtures/appex-ui21-inverse.patch'
    result = {}
    name = None
    old, new = None, None

    def finish():
        if old is not None:
            assert old and new, 'reviewed hunks need exact baseline/current context'
            result[name].append((''.join(old), ''.join(new)))

    for line in path.read_text().splitlines(keepends=True):
        if line.startswith('diff --git '):
            finish()
            old = new = None
            match = re.fullmatch(r'diff --git a/(\S+) b/(\S+)\n', line)
            assert match and match[1] == match[2], 'no renames in region allowlist'
            name = match[1]
            assert name in REVIEWED_PATHS and name not in result, name
            result[name] = []
        elif line.startswith('@@ '):
            finish()
            old, new = [], []
        elif old is not None:
            assert line[0] in ' +-', 'unexpected hunk data'
            if line[0] in ' -': old.append(line[1:])
            if line[0] in ' +': new.append(line[1:])
        else:
            assert line.startswith(('index ', '--- a/', '+++ b/')), line
    finish()
    assert set(result) == REVIEWED_PATHS, 'projection scope changed'
    for name, hunks in result.items():
        baseline = baseline_bytes(name, RELEASE_BASE).decode()
        assert hunks, name
        for previous, current in hunks:
            assert previous != current, name
            assert baseline.count(previous) == 1, 'old region not uniquely in baseline: ' + name
    return result


def inverse_extension_source(path, source):
    """Subtract literal reviewed additions while retaining unknown old-path bytes."""
    if path in (CI_PATH, 'control'):
        field = '      PACKAGE_VERSION: ' if path == CI_PATH else 'Version: '
        current = field + CANDIDATE_VERSION + '\n'
        previous = field + RELEASE_VERSION + '\n'
        assert baseline_bytes(path, RELEASE_BASE).decode().count(previous) == 1
        assert source.count(current) == 1, 'candidate version missing/changed: ' + path
        source = source.replace(current, previous, 1)
    if path == '.gitattributes':
        addition = ('\n# Literal inverse-diff fixture includes context-only spaces and frozen old\n'
                    '# whitespace; do not rewrite those bytes or relax checks on production files.\n'
                    'tests/fixtures/appex-ui21-inverse.patch whitespace=-blank-at-eol\n')
        assert source.count(addition) == 1, 'literal fixture whitespace rule missing/changed'
        source = source.replace(addition, '', 1)
    if path == 'ci/stage_release.py':
        current = "fields.get('Version','').strip()!='" + CANDIDATE_VERSION + "'"
        previous = "fields.get('Version','').strip()!='" + RELEASE_VERSION + "'"
        assert baseline_bytes(path, RELEASE_BASE).decode().count(previous) == 1
        assert source.count(current) == 1, 'staging version missing/changed'
        source = source.replace(current, previous, 1)
    if path == CI_PATH:
        anchor = '          sudo bash tests/run_springboard_native_tests.sh\n'
        assert source.count(anchor + CI_ADDITIONS) == 1, 'CI host calls missing/changed'
        source = source.replace(anchor + CI_ADDITIONS, anchor, 1)
    for previous, current in reviewed_regions().get(path, []):
        assert source.count(current) == 1, 'authorized region missing/changed: ' + path
        source = source.replace(current, previous, 1)
    return source


def released_bytes(path, source=None):
    """Candidate -> full 788; only reviewed regions/fields are reversed."""
    if source is None: source = (ROOT / path).read_bytes()
    if path not in REVIEWED_PATHS and path not in (CI_PATH, 'control', 'ci/stage_release.py', '.gitattributes'):
        # Unchanged binary assets are frozen as bytes, never UTF-8 decoded.
        return source if isinstance(source, bytes) else source.encode()
    if isinstance(source, bytes): source = source.decode()
    return inverse_extension_source(path, source).encode()


def assert_release_freeze(path, source=None):
    assert released_bytes(path, source) == baseline_bytes(path, RELEASE_BASE), 'release freeze: ' + path


def projected_bytes(path, source=None):
    """Candidate -> 788 -> softremove -> SB -> release -> nice -> real UI21."""
    from nice_delta import without_nice
    return without_nice(path, released_bytes(path, source))


def assert_ui21_freeze(path, source=None):
    assert_release_freeze(path, source)
    assert projected_bytes(path, source) == baseline_bytes(path), 'ui21 freeze: ' + path


def function_source(text, signature):
    """Crop a named C/ObjC function/method, preserving every body byte."""
    start = text.find(signature)
    assert start >= 0, 'missing function: ' + signature
    opening = text.find('{', start)
    assert opening >= 0, 'missing function body: ' + signature
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{': depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0: return text[start:index + 1]
    raise AssertionError('unterminated function: ' + signature)
