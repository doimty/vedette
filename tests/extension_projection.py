#!/usr/bin/env python3
"""Exact inverse projection of reviewed App-extension additions.

The readable patch is a REGION allowlist against git 2994f24, NOT a new-source
hash baseline. Each old region must exist verbatim in that immutable baseline;
each reviewed new region must occur exactly once before reversal. Unknown
changes survive reversal and fail whole-file equality. No fuzzy patching,
blanket function replacement, stripping keys, or whitespace normalization.
The source integration suite additionally checks the extension behavior and
executes mutation negatives in both allowed regions and old frozen logic.
"""
from functools import lru_cache
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APPEX_BASE = '2994f24bbc73a6081d958f8f64ba4ff76640b8af'
REVIEWED_PATHS = frozenset({
    'VDTShared.h', 'VDTShared.mm', 'VDTProcessManager.mm', 'VDTProcessManager.h',
    'vedetteprefs/VDTRootListController.m',
    'vedetteprefs/VDTProcessConfiguration.m', 'vedetteprefs/Makefile',
    'Vedette.xm',
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
        baseline = baseline_bytes(name).decode()
        assert hunks, name
        for previous, current in hunks:
            assert previous != current, name
            assert baseline.count(previous) == 1, 'old region not uniquely in baseline: ' + name
    return result


def inverse_extension_source(path, source):
    """Undo only literal reviewed new regions, without hiding old-path mutations."""
    if path == CI_PATH:
        assert source.count(CI_ADDITIONS) == 1, 'CI host calls missing/changed'
        return source.replace(CI_ADDITIONS, '', 1)
    for previous, current in reviewed_regions().get(path, []):
        assert source.count(current) == 1, 'authorized region missing/changed: ' + path
        source = source.replace(current, previous, 1)
    return source


def projected_bytes(path, source=None):
    if source is None: source = (ROOT / path).read_bytes()
    if isinstance(source, bytes): source = source.decode()
    return inverse_extension_source(path, source).encode()


def assert_ui21_freeze(path, source=None):
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
