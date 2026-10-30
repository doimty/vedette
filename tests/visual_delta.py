#!/usr/bin/env python3
"""Literal visual inverse to fixed 7cef39b, before the historical freeze chain.

Only existing, explicitly named paths may have reviewed Git hunks. Restoring
those hunks must reproduce the entire fixed-base file byte for byte. This is
source-delta evidence, not a claim about runtime or visual correctness.
"""
from functools import lru_cache
from pathlib import Path
import re
import subprocess

from comfort_delta import _bytes, _lines

ROOT = Path(__file__).resolve().parents[1]
VISUAL_BASE = '7cef39b6058f699e2c5bd7f17a1562f37a6aeb4c'
VISUAL_PATHS = frozenset({
    'vedetteprefs/VDTCheckDetailsController.m',
    'vedetteprefs/VDTCheckFieldCell.m',
    'vedetteprefs/VDTCheckResultCell.m',
    'vedetteprefs/VDTCheckResultModel.m',
    'vedetteprefs/Resources/en.lproj/Localizable.strings',
    'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings',
    'control', '.github/workflows/roothide-build.yml', 'ci/stage_release.py',
    'ci/run_host_tests.sh', 'Makefile.tests', '.gitattributes',
})
VISUAL_WHITESPACE_ADDITION = (
    b'tests/fixtures/visual-11146-inverse.patch whitespace=-blank-at-eol,-space-before-tab\n'
)
_REQUIRED_PATHS = frozenset({
    'control', '.github/workflows/roothide-build.yml', 'ci/stage_release.py', '.gitattributes',
})


@lru_cache(maxsize=None)
def visual_baseline(path):
    assert path in VISUAL_PATHS, 'unauthorized visual baseline path: ' + str(path)
    return subprocess.check_output(['git', 'show', VISUAL_BASE + ':' + path], cwd=ROOT)


def _validate_regions(path, hunks):
    base = visual_baseline(path)
    lines = _lines(base)
    pieces = []
    cursor = delta = 0
    for old_start, old_count, new_start, new_count, previous, current in hunks:
        start, end = old_start - 1, old_start - 1 + old_count
        assert cursor <= start < end <= len(lines), 'overlapping/out-of-range visual hunk: ' + path
        assert new_start == old_start + delta, 'inconsistent visual hunk positions: ' + path
        assert b''.join(lines[start:end]) == previous, 'wrong visual old context: ' + path
        assert base.count(previous) == 1, 'visual old context is not unique: ' + path
        pieces.extend((b''.join(lines[cursor:start]), current))
        cursor = end
        delta += new_count - old_count
    pieces.append(b''.join(lines[cursor:]))
    reviewed = b''.join(pieces)
    reviewed_lines = _lines(reviewed)
    for _, _, new_start, new_count, _, current in hunks:
        assert b''.join(reviewed_lines[new_start - 1:new_start - 1 + new_count]) == current, \
            'wrong visual new context: ' + path
        assert reviewed.count(current) == 1, 'visual new context is not unique: ' + path
    if path == '.gitattributes':
        assert reviewed == base + VISUAL_WHITESPACE_ADDITION, 'visual whitespace scope changed'
    return tuple((previous, current) for _, _, _, _, previous, current in hunks)


def parse_visual_regions(patch):
    """Parse literal Git hunks against fixed blobs without reading live sources."""
    patch = _bytes(patch)
    assert patch and patch.endswith(b'\n'), 'empty/truncated visual fixture'
    lines = _lines(patch)
    result = {}
    index = 0
    while index < len(lines):
        match = re.fullmatch(rb'diff --git a/(\S+) b/(\S+)\n', lines[index])
        assert match and match[1] == match[2], 'visual aliases/renames forbidden'
        path = match[1].decode('utf-8')
        assert path in VISUAL_PATHS and path not in result, 'unauthorized/duplicate visual path: ' + path
        assert index + 3 < len(lines), 'truncated visual file header'
        assert re.fullmatch(rb'index [0-9a-f]{7,40}\.\.[0-9a-f]{7,40} (100644|100755)\n', lines[index + 1]), \
            'visual file creation/deletion/mode changes forbidden'
        assert lines[index + 2] == b'--- a/' + match[1] + b'\n', 'wrong visual old path'
        assert lines[index + 3] == b'+++ b/' + match[1] + b'\n', 'wrong visual new path'
        index += 4
        hunks = []
        while index < len(lines) and not lines[index].startswith(b'diff --git '):
            header = re.fullmatch(rb'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n', lines[index])
            assert header, 'bad visual hunk header: ' + path
            old_start, old_count = int(header[1]), int(header[2] or b'1')
            new_start, new_count = int(header[3]), int(header[4] or b'1')
            assert min(old_start, old_count, new_start, new_count) > 0, 'visual hunks require old/new context'
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
                    assert prefix in (b' ', b'+', b'-'), 'bad visual hunk data: ' + path
                    if prefix in (b' ', b'-'):
                        assert not old_eof, 'old data after no-newline marker'
                        old.append(line[1:])
                    if prefix in (b' ', b'+'):
                        assert not new_eof, 'new data after no-newline marker'
                        new.append(line[1:])
                    last_prefix, marked = prefix, False
                index += 1
            assert len(old) == old_count and len(new) == new_count, 'visual hunk line counts changed: ' + path
            previous, current = b''.join(old), b''.join(new)
            assert previous and current and previous != current, 'empty/unchanged visual hunk: ' + path
            hunks.append((old_start, old_count, new_start, new_count, previous, current))
        assert hunks, 'visual path has no hunks: ' + path
        result[path] = _validate_regions(path, hunks)
    assert result, 'missing visual delta'
    return result


@lru_cache(maxsize=1)
def visual_regions():
    result = parse_visual_regions((ROOT / 'tests/fixtures/visual-11146-inverse.patch').read_bytes())
    assert _REQUIRED_PATHS <= result.keys(), 'missing visual version/whitespace delta'
    return result


def without_visual_rules(path, source):
    """Reverse reviewed current hunks and require the exact full visual base."""
    assert path in VISUAL_PATHS, 'unauthorized visual source path: ' + str(path)
    data = _bytes(source)
    base = visual_baseline(path)
    if data == base:
        return source
    regions = visual_regions().get(path, ())
    pieces = []
    cursor = 0
    for previous, current in regions:
        assert data.count(current) == 1, 'visual reviewed region missing/changed: ' + path
        start = data.index(current)
        assert start >= cursor, 'overlapping/reordered visual current regions: ' + path
        pieces.extend((data[cursor:start], previous))
        cursor = start + len(current)
    pieces.append(data[cursor:])
    restored = b''.join(pieces)
    assert restored == base, 'unknown visual source bytes: ' + path
    return restored.decode('utf-8') if isinstance(source, str) else restored
