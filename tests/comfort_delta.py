#!/usr/bin/env python3
"""Literal comfort inverse to fixed 2a3108c, before the unchanged formal chain.

Only reviewed, existing paths can have hunks. Both sides are literal bytes, not
function replacements, aliases, current-file hashes, fuzzy patches or cleanup.
This proves the permitted source delta and preserved historical bytes, not
product/runtime correctness. Importing this module performs no I/O or mutation.
"""
from functools import lru_cache
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
COMFORT_BASE = '2a3108cc797da453599086a7f4cbbf13bb32a162'
COMFORT_PATHS = frozenset({
    'VDTProcessManager.h', 'VDTProcessManager.mm',
    'VDTResourceRuntime.h', 'VDTResourceRuntime.mm',
    'VDTResourceShared.h', 'VDTResourceShared.mm',
    'libproc/libproc_internal.h', 'Vedette.xm',
    'vedetteprefs/VDTCheckResultModel.m', 'vedetteprefs/VDTCheckResultReader.m',
    'vedetteprefs/VDTCheckResultsPreferences.m',
    'vedetteprefs/VDTCheckResultCell.h', 'vedetteprefs/VDTCheckResultCell.m',
    'vedetteprefs/VDTCheckDetailsController.h', 'vedetteprefs/VDTCheckDetailsController.m',
    'vedetteprefs/Resources/en.lproj/Localizable.strings',
    'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings',
    'control', '.github/workflows/roothide-build.yml', 'ci/stage_release.py',
    'ci/run_host_tests.sh', 'Makefile.tests', '.gitattributes',
})
COMFORT_WHITESPACE_RULE = (
    b'tests/fixtures/comfort-1114-inverse.patch whitespace=-blank-at-eol,-space-before-tab\n'
)
COMFORT_WHITESPACE_ADDITION = (
    b'\n# Preserve literal reviewed comfort delta context; production whitespace remains checked.\n'
    + COMFORT_WHITESPACE_RULE
)


def _bytes(source):
    assert isinstance(source, (bytes, str)), 'comfort source must be bytes or str'
    return source.encode('utf-8') if isinstance(source, str) else source


def _lines(source):
    """Split only LF, retaining every byte (including CR and a missing final LF)."""
    parts = source.split(b'\n')
    return [part + b'\n' for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


@lru_cache(maxsize=None)
def comfort_baseline(path):
    assert path in COMFORT_PATHS, 'unauthorized comfort baseline path: ' + str(path)
    return subprocess.check_output(['git', 'show', COMFORT_BASE + ':' + path], cwd=ROOT)


def _validate_regions(path, hunks):
    base = comfort_baseline(path)
    lines = _lines(base)
    pieces = []
    cursor = delta = 0
    for old_start, old_count, new_start, new_count, previous, current in hunks:
        start, end = old_start - 1, old_start - 1 + old_count
        assert cursor <= start < end <= len(lines), 'overlapping/out-of-range comfort hunk: ' + path
        assert new_start == old_start + delta, 'inconsistent comfort hunk positions: ' + path
        assert b''.join(lines[start:end]) == previous, 'wrong comfort old context: ' + path
        assert base.count(previous) == 1, 'comfort old context is not unique: ' + path
        pieces.extend((b''.join(lines[cursor:start]), current))
        cursor = end
        delta += new_count - old_count
    pieces.append(b''.join(lines[cursor:]))
    reviewed = b''.join(pieces)
    reviewed_lines = _lines(reviewed)
    for _, _, new_start, new_count, _, current in hunks:
        assert b''.join(reviewed_lines[new_start - 1:new_start - 1 + new_count]) == current, \
            'wrong comfort new context: ' + path
        assert reviewed.count(current) == 1, 'comfort new context is not unique: ' + path
    if path == '.gitattributes':
        assert reviewed == base + COMFORT_WHITESPACE_ADDITION, 'comfort whitespace scope changed'
    return tuple((previous, current) for _, _, _, _, previous, current in hunks)


def parse_comfort_regions(patch):
    """Validate a literal Git diff against immutable blobs; never read live sources."""
    patch = _bytes(patch)
    assert patch and patch.endswith(b'\n'), 'empty/truncated comfort fixture'
    lines = _lines(patch)
    result = {}
    index = 0
    while index < len(lines):
        match = re.fullmatch(rb'diff --git a/(\S+) b/(\S+)\n', lines[index])
        assert match and match[1] == match[2], 'comfort aliases/renames forbidden'
        path = match[1].decode('utf-8')
        assert path in COMFORT_PATHS and path not in result, 'unauthorized/duplicate comfort path: ' + path
        assert index + 3 < len(lines), 'truncated comfort file header'
        assert re.fullmatch(rb'index [0-9a-f]{7,40}\.\.[0-9a-f]{7,40} (100644|100755)\n', lines[index + 1]), \
            'comfort file creation/deletion/mode changes forbidden'
        assert lines[index + 2] == b'--- a/' + match[1] + b'\n', 'wrong comfort old path'
        assert lines[index + 3] == b'+++ b/' + match[1] + b'\n', 'wrong comfort new path'
        index += 4
        hunks = []
        while index < len(lines) and not lines[index].startswith(b'diff --git '):
            header = re.fullmatch(rb'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n', lines[index])
            assert header, 'bad comfort hunk header: ' + path
            old_start, old_count = int(header[1]), int(header[2] or b'1')
            new_start, new_count = int(header[3]), int(header[4] or b'1')
            assert min(old_start, old_count, new_start, new_count) > 0, 'comfort hunks require old/new context'
            old, new = [], []
            old_eof = new_eof = marked = False
            last_prefix = None
            index += 1
            while index < len(lines) and not lines[index].startswith((b'@@ ', b'diff --git ')):
                line = lines[index]
                if line == b'\\ No newline at end of file\n':
                    assert last_prefix in (b' ', b'+', b'-') and not marked, 'orphan/duplicate no-newline marker'
                    if last_prefix in (b' ', b'-'):
                        assert old and old[-1].endswith(b'\n'), 'bad old no-newline marker'
                        old[-1] = old[-1][:-1]
                        old_eof = True
                    if last_prefix in (b' ', b'+'):
                        assert new and new[-1].endswith(b'\n'), 'bad new no-newline marker'
                        new[-1] = new[-1][:-1]
                        new_eof = True
                    marked = True
                else:
                    prefix = line[:1]
                    assert prefix in (b' ', b'+', b'-'), 'bad comfort hunk data: ' + path
                    if prefix in (b' ', b'-'):
                        assert not old_eof, 'old data after no-newline marker'
                        old.append(line[1:])
                    if prefix in (b' ', b'+'):
                        assert not new_eof, 'new data after no-newline marker'
                        new.append(line[1:])
                    last_prefix, marked = prefix, False
                index += 1
            assert len(old) == old_count and len(new) == new_count, 'comfort hunk line counts changed: ' + path
            previous, current = b''.join(old), b''.join(new)
            assert previous and current and previous != current, 'empty/unchanged comfort hunk: ' + path
            hunks.append((old_start, old_count, new_start, new_count, previous, current))
        assert hunks, 'comfort path has no hunks: ' + path
        result[path] = _validate_regions(path, hunks)
    assert result, 'missing comfort delta'
    return result


@lru_cache(maxsize=1)
def comfort_regions():
    return parse_comfort_regions((ROOT / 'tests/fixtures/comfort-1114-inverse.patch').read_bytes())


def without_comfort_rules(path, source):
    """Subtract only literal comfort hunks, then require the exact fixed-base file.

    Unsupported paths and aliases cannot acquire an exemption. Exact historical
    COMFORT_BASE bytes pass through first; other visual-scope inputs must pass
    the strict visual inverse before the original comfort checks run.
    """
    assert path in COMFORT_PATHS, 'unauthorized comfort source path: ' + str(path)
    data = _bytes(source)
    base = comfort_baseline(path)
    if data == base:
        return source
    from launch_symbols_delta import without_launch_symbols
    source = without_launch_symbols(path, source)
    data = _bytes(source)
    from visual_delta import VISUAL_PATHS, without_visual_rules
    if path in VISUAL_PATHS:
        source = without_visual_rules(path, source)
        data = _bytes(source)
    regions = comfort_regions().get(path, ())
    pieces = []
    cursor = 0
    for previous, current in regions:
        assert data.count(current) == 1, 'comfort reviewed region missing/changed: ' + path
        start = data.index(current)
        assert start >= cursor, 'overlapping/reordered comfort current regions: ' + path
        pieces.extend((data[cursor:start], previous))
        cursor = start + len(current)
    pieces.append(data[cursor:])
    restored = b''.join(pieces)
    assert restored == base, 'unknown comfort source bytes: ' + path
    return restored.decode('utf-8') if isinstance(source, str) else restored
