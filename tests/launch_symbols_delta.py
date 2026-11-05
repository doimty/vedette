#!/usr/bin/env python3
"""Reverse only the reviewed launch/symbol changes before historical projections.

A separate, literal delta against the last green build keeps all older fixtures
immutable. Each hunk is anchored to fixed Git bytes with exact coordinates and
unique old/current regions. Full-file equality rejects residual unknown edits;
this does not prove runtime correctness of the reviewed changes.
"""
from functools import lru_cache
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = '38d6f44d3fbf24245a0f0d8db1a79fb53105a36c'
PATHS = frozenset({
    '.github/workflows/roothide-build.yml', '.gitignore',
    'Vedette.xm', 'ci/run_host_tests.sh',
})
FIXTURE = 'tests/fixtures/launch-symbols-inverse.patch'
# Existing projection APIs also receive these exact historical inputs directly.
# They remain pass-through observations, not inferred partial matches.
HISTORICAL_REVISIONS = (
    '7cef39b6058f699e2c5bd7f17a1562f37a6aeb4c',
    '2a3108cc797da453599086a7f4cbbf13bb32a162',
    '1dfce93bd54b83292b1547d6a608a180fb4cd8b4',
    '788f43bcb17a2c3890ed8bdeea3f1a97660e13c7',
    '2994f24bbc73a6081d958f8f64ba4ff76640b8af',
)


def lines(data):
    parts = data.split(b'\n')
    return [p + b'\n' for p in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


@lru_cache(maxsize=None)
def baseline(path, revision=BASE):
    assert path in PATHS, 'launch/symbol scope changed: ' + path
    return subprocess.check_output(['git', 'show', revision + ':' + path], cwd=ROOT)


@lru_cache(maxsize=None)
def historical_bytes(path):
    assert path in PATHS, 'launch/symbol scope changed: ' + path
    observed = []
    for revision in HISTORICAL_REVISIONS:
        reply = subprocess.run(['git', 'show', revision + ':' + path], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if reply.returncode == 0:
            observed.append(reply.stdout)
        else:
            # A helper script may not yet have existed in an older revision.
            exists = subprocess.run(['git', 'cat-file', '-e', revision], cwd=ROOT,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            assert exists.returncode == 0, 'missing fixed historical revision: ' + revision
    return tuple(observed)


def parse_regions(patch):
    """Validate a new fixture against immutable base bytes, never live sources."""
    assert isinstance(patch, bytes) and patch.endswith(b'\n'), 'truncated launch/symbol fixture'
    rows = lines(patch)
    result = {}
    index = 0
    while index < len(rows):
        match = re.fullmatch(rb'diff --git a/(\S+) b/(\S+)\n', rows[index])
        assert match and match[1] == match[2], 'fixture aliases/renames forbidden'
        path = match[1].decode('utf-8')
        assert path in PATHS and path not in result, 'duplicate/unreviewed delta path: ' + path
        assert index + 3 < len(rows), 'truncated delta file header'
        assert re.fullmatch(rb'index [a-f0-9]{7,40}\.\.[a-f0-9]{7,40} 100644\n', rows[index + 1]), \
            'unexpected delta mode/header'
        assert rows[index + 2] == b'--- a/' + match[1] + b'\n', 'wrong old delta path'
        assert rows[index + 3] == b'+++ b/' + match[1] + b'\n', 'wrong new delta path'
        index += 4
        base = baseline(path)
        base_rows = lines(base)
        cursor = delta = 0
        pieces = []
        hunks = []
        while index < len(rows) and not rows[index].startswith(b'diff --git '):
            h = re.fullmatch(rb'@@ -(\d+),(\d+) \+(\d+),(\d+) @@[^\n]*\n', rows[index])
            assert h, 'invalid delta hunk header: ' + path
            old_start, old_count, new_start, new_count = map(int, h.groups())
            assert min(old_start, old_count, new_start, new_count) > 0, 'delta needs old/new context'
            index += 1
            old, new = [], []
            while index < len(rows) and not rows[index].startswith((b'@@ ', b'diff --git ')):
                prefix = rows[index][:1]
                assert prefix in (b' ', b'-', b'+'), 'invalid delta hunk data: ' + path
                if prefix in (b' ', b'-'):
                    old.append(rows[index][1:])
                if prefix in (b' ', b'+'):
                    new.append(rows[index][1:])
                index += 1
            assert len(old) == old_count and len(new) == new_count, 'delta hunk count mismatch: ' + path
            previous, current = b''.join(old), b''.join(new)
            start, end = old_start - 1, old_start - 1 + old_count
            assert cursor <= start < end <= len(base_rows), 'overlapping/out-of-range delta: ' + path
            assert new_start == old_start + delta, 'inconsistent delta coordinates: ' + path
            assert previous != current, 'unchanged delta hunk: ' + path
            assert b''.join(base_rows[start:end]) == previous, 'wrong fixed-base delta context: ' + path
            assert base.count(previous) == 1, 'ambiguous old delta context: ' + path
            pieces.extend((b''.join(base_rows[cursor:start]), current))
            cursor = end
            delta += new_count - old_count
            hunks.append((new_start, new_count, previous, current))
        assert hunks, 'missing delta hunks: ' + path
        pieces.append(b''.join(base_rows[cursor:]))
        reviewed = b''.join(pieces)
        reviewed_rows = lines(reviewed)
        for new_start, new_count, _, current in hunks:
            assert b''.join(reviewed_rows[new_start - 1:new_start - 1 + new_count]) == current, \
                'wrong new delta coordinates: ' + path
            assert reviewed.count(current) == 1, 'ambiguous new delta context: ' + path
        result[path] = tuple((previous, current) for _, _, previous, current in hunks)
    assert set(result) == PATHS, 'incomplete launch/symbol delta scope'
    return result


@lru_cache(maxsize=1)
def reviewed_regions():
    return parse_regions((ROOT / FIXTURE).read_bytes())


def without_launch_symbols(path, source):
    """Inverse exact new hunks or pass exact known historical input onward."""
    if path not in PATHS:
        return source
    assert isinstance(source, (bytes, str)), 'delta source must be bytes or str'
    data = source.encode('utf-8') if isinstance(source, str) else source
    base = baseline(path)
    if data == base or data in historical_bytes(path):
        return source
    pieces = []
    cursor = 0
    for previous, current in reviewed_regions()[path]:
        assert data.count(current) == 1, 'launch/symbol reviewed region missing/changed: ' + path
        start = data.index(current)
        assert start >= cursor, 'reordered/overlapping new delta regions: ' + path
        pieces.extend((data[cursor:start], previous))
        cursor = start + len(current)
    pieces.append(data[cursor:])
    restored = b''.join(pieces)
    assert restored == base, 'unknown launch/symbol source bytes: ' + path
    return restored.decode('utf-8') if isinstance(source, str) else restored
