#!/usr/bin/env python3
"""Literal formal delta against fixed 1dfce93, before the unchanged freeze chain.

This is a reviewed inverse-patch contract, not a current-file hash or blanket
function replacement. Each old region must occur once in immutable Git bytes;
each current region must occur once, and unknown bytes fail whole-file equality.
"""
from functools import lru_cache
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FORMAL_BASE = '1dfce93bd54b83292b1547d6a608a180fb4cd8b4'
FORMAL_VERSION = '1.1.14-2'
FORMAL_PATHS = frozenset({
    'VDTNiceShared.h', 'VDTNiceShared.mm', 'VDTNiceRuntime.h', 'VDTNiceRuntime.mm',
    'VDTShared.h', 'VDTShared.mm', 'VDTProcessManager.h', 'VDTProcessManager.mm',
    'Vedette.xm', 'vedetteprefs/VDTProcessConfiguration.h',
    'vedetteprefs/VDTProcessConfiguration.m', 'vedetteprefs/VDTNicePreferences.h',
    'vedetteprefs/VDTNicePreferences.m', 'vedetteprefs/VDTListPresentation.h',
    'vedetteprefs/VDTListPresentation.m', 'vedetteprefs/VDTExtensionListController.m',
    'vedetteprefs/VDTApplicationListSubcontrollerController.m',
    'vedetteprefs/ChoicyPreferences/CHPDaemonListController.m',
    'vedetteprefs/ChoicyPreferences/CHPDaemonInfo.h', 'vedetteprefs/ChoicyPreferences/CHPDaemonInfo.m',
    'vedetteprefs/ChoicyPreferences/CHPDaemonList.h', 'vedetteprefs/ChoicyPreferences/CHPDaemonList.m',
    'vedetteprefs/ChoicyPreferences/CHPDaemonListController.h',
    'vedetteprefs/ChoicyPreferences/CHPDaemonListObserver.h',
    'vedetteprefs/ChoicyPreferences/CHPListController.h', 'vedetteprefs/ChoicyPreferences/CHPListController.m',
    'vedetteprefs/VDTRootListController.m', 'vedetteprefs/VDTExtensionListController.h',
    'vedetteprefs/Resources/en.lproj/Localizable.strings',
    'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings',
    '.github/workflows/roothide-build.yml', 'ci/stage_release.py', 'control',
    '.gitattributes', 'nicectl/main.mm', 'vedetteprefs/Makefile',
    'layout/DEBIAN/postinst', 'layout/DEBIAN/prerm',
    'layout-rootless/DEBIAN/postinst', 'layout-rootless/DEBIAN/prerm',
})


@lru_cache(maxsize=None)
def formal_baseline(path):
    assert path in FORMAL_PATHS, 'formal scope changed: ' + path
    return subprocess.check_output(['git', 'show', FORMAL_BASE + ':' + path], cwd=ROOT)


@lru_cache(maxsize=1)
def formal_regions():
    result = {}
    name = None
    old = new = None

    def finish():
        if old is not None:
            assert old and new, 'empty formal hunk side'
            previous, current = ''.join(old), ''.join(new)
            assert previous != current, 'unchanged formal hunk'
            result[name].append((previous, current))

    for line in (ROOT / 'tests/fixtures/formal-1113-inverse.patch').read_text().splitlines(keepends=True):
        if line.startswith('diff --git '):
            finish(); old = new = None
            match = re.fullmatch(r'diff --git a/(\S+) b/(\S+)\n', line)
            assert match and match[1] == match[2], 'formal renames forbidden'
            name = match[1]
            assert name in FORMAL_PATHS and name not in result, 'unauthorized formal path: ' + str(name)
            result[name] = []
        elif line.startswith('@@ '):
            finish(); old, new = [], []
        elif line == '\\ No newline at end of file\n':
            assert old is not None and last_prefix in ' +-', 'orphan no-newline marker'
            if last_prefix in ' -':
                assert old and old[-1].endswith('\n'); old[-1] = old[-1][:-1]
            if last_prefix in ' +':
                assert new and new[-1].endswith('\n'); new[-1] = new[-1][:-1]
        elif old is not None:
            assert line[0] in ' +-', 'bad formal hunk data'
            last_prefix = line[0]
            if line[0] in ' -': old.append(line[1:])
            if line[0] in ' +': new.append(line[1:])
        else:
            assert line.startswith(('index ', '--- a/', '+++ b/')), line
    finish()
    assert result and {'control', 'VDTNiceRuntime.mm', 'vedetteprefs/VDTListPresentation.m'} <= set(result), 'missing formal delta layers'
    for path, hunks in result.items():
        base = formal_baseline(path).decode()
        assert hunks, path
        for previous, current in hunks:
            assert base.count(previous) == 1, 'formal baseline region is not unique: ' + path
    return result


def without_formal_rules(path, source):
    is_bytes = isinstance(source, bytes)
    regions = formal_regions().get(path)
    if regions is None:
        return source
    text = source.decode() if is_bytes else source
    for previous, current in regions:
        assert text.count(current) == 1, 'formal reviewed region missing/changed: ' + path
        text = text.replace(current, previous, 1)
    assert text.encode() == formal_baseline(path), 'unknown formal source bytes: ' + path
    return text.encode() if is_bytes else text
