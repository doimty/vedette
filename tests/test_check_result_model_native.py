#!/usr/bin/env python3
"""Required cloud gate: real Foundation model + compiled, targeted mutants.
The Preferences adapter is source-checked; this is NOT UIKit/device validation.
Non-Darwin exits 77 (or 1 with --require-native), without invoking any build.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'
BASE = 'abb5f4cfe09573c8effa1964266051bbbbb267cb'
MODEL = PREFS / 'VDTCheckResultModel.m'


def source_contracts():
    from test_resource_preferences_native import function_source
    from test_preferences_ui import read_strings, validate_keys
    owner = (PREFS / 'VDTProcessConfiguration.m').read_text()
    adapter = (PREFS / 'VDTCheckResultsPreferences.m').read_text()
    reader = (PREFS / 'VDTCheckResultReader.m').read_text()
    nice = (PREFS / 'VDTNicePreferences.m').read_text()
    cell = (PREFS / 'VDTCheckResultCell.m').read_text()
    model = MODEL.read_text()
    insertion = '[rootSpecifiers addObjectsFromArray:[self vdtCheckResultSpecifiers]];'
    assert owner.count(insertion) == 1 and owner.index(insertion) > owner.index('[rootSpecifiers addObject:jetsamBandSpec];')
    assert 'vdtResourceReceiptText' not in owner
    assert 'Nice execution status' not in nice and 'Check / retry nice' not in nice
    assert adapter.count('VDTLoc(self.class, @"Check / retry nice")') == 1
    assert 'index < 3' in adapter and 'VDTCheckResultSpecifier(@{})' in adapter
    assert 'VDTCheckDetailsController' not in adapter and 'vdtCheckContext' not in adapter
    assert '@"Check details"' not in adapter and '@"Refresh display"' not in adapter
    assert 'footerText' not in adapter and '@"Last apply result"' in adapter
    assert '[refresh setButtonAction:' not in adapter
    assert 'compactState' in cell and 'compactTone' in cell
    for removed in ('checkSummary', 'checkTime', 'checkScope', 'model[@"state"]', 'model[@"summary"]'):
        assert removed not in cell, 'expanded result content returned: ' + removed
    assert cell.count('[UILabel new]') == 2, 'compact row must contain only title and status'
    assert 'VDTCheckResultSpecifier(@{}, NO)' not in adapter
    assert 'VDTNiceMatchingStatusWithHost(' in reader and 'VDTResourceMatchingStatus(' in reader
    assert 'VDTCheckResultModels(' in reader
    assert 'cellClass' in cell and 'VDTCheckResultCell.class' in cell
    assert 'label.numberOfLines = 0' in cell and 'adjustsFontForContentSizeCategory = YES' in cell
    assert 'UIContentSizeCategoryIsAccessibilityCategory' in cell
    assert 'setPendingStatusAndReload' in nice and 'vdtMarkNiceCheckPending' in nice and 'vdtNiceCheckDidRefresh' in nice
    assert 'notify_cancel(_resourceToken)' in adapter and '__weak VDTCheckResultsPreferences' in adapter
    for forbidden in ('notify_post(', 'memorystatus_control(', 'setpriority(', 'VDTResourceSetWriteEnabled', '_specifiers = nil'):
        assert forbidden not in adapter + model, 'read-only display violated: ' + forbidden
    for prefix in ('- (void)refreshDisplay', '- (void)reloadModels'):
        assert 'requestRetry' not in function_source(adapter, prefix)
    assert '[[_owner vdtNicePreferences] requestRetry]' in function_source(adapter, '- (void)requestNiceRetry')
    assert 'notify_post(VDT_NICE_RETRY_NOTIFICATION)' in function_source(nice, '- (void)requestRetry {')
    assert '$(wildcard *.m)' in (PREFS / 'Makefile').read_text(), 'new UI files not built'
    # Independent, exact CPU and settings checks: do not rely on regenerated
    # formal projections to rubber-stamp changed CPU behavior.
    previous = subprocess.check_output(['git', 'show', BASE + ':vedetteprefs/VDTProcessConfiguration.m'], cwd=ROOT).decode()
    for prefix in ('- (void)setProcessConfigValue:', '- (id)readProcessConfigValue:'):
        assert function_source(owner, prefix) == function_source(previous, prefix), 'CPU behavior changed'
    def cpu_rows(text):
        start = text.index('        NSString *validIdentifier = [self validIdentifier];')
        end = text.index('        // Keep the nice controls independent', start)
        return text[start:end]
    assert cpu_rows(owner) == cpu_rows(previous), 'original CPU layout changed'
    old_nice = subprocess.check_output(['git', 'show', BASE + ':vedetteprefs/VDTNicePreferences.m'], cwd=ROOT).decode()
    for prefix in ('- (void)requestRetry {', '- (void)setPreferenceValue:', '- (id)readPreferenceValue:',
                   '- (void)saveValue:', '- (void)removeIndependentNiceRule'):
        assert function_source(nice, prefix) == function_source(old_nice, prefix), 'nice action changed'
    en = read_strings(PREFS / 'Resources/en.lproj/Localizable.strings')
    zh = read_strings(PREFS / 'Resources/zh-Hans.lproj/Localizable.strings')
    required = set(re.findall(r'VDTCheckText\(localize,\s*@"([^"\n]+)"', model))
    for prefix in ('static NSString *VDTCheckNiceState(', 'static NSString *VDTCheckResourceState('):
        body = function_source(model, prefix)
        required |= set(re.findall(r'return @"([^"\n]+)"', body))
        required |= set(re.findall(r'@"[^"\n]+": @"([^"\n]+)"', body))
    required |= {'nice', 'Memory', 'Reclaim priority', 'Recent check results', 'Check details', 'Refresh display',
                 'Check / retry nice', 'Multiple instances; selected instance only',
                 'Multiple instances; individual readbacks unavailable', 'Recorded instances: %@',
                 'Original: %@', 'errno: %@', 'Pending targets: %@', 'Selected PID: %@', 'Skip code: %@',
                 'Nice receipt exceeds size limit', 'Nice receipt unavailable', 'Receipt saved at'}
    required |= {'Last apply result', 'Applied', 'Restored', 'Not enabled', 'Pending', 'Not confirmed', 'Not applied', 'Partly confirmed'}
    validate_keys(required, en, zh)
    print('PASS check-result source wiring, compact rows, CPU/nice freeze, localization (not UIKit)')


def mutants(source):
    changes = [
        ('compact-unknown-as-success', 'NSString *compactState = @"Not confirmed", *compactTone = @"neutral";',
         'NSString *compactState = @"Applied", *compactTone = @"ok";', 'compact-missing-not-success'),
        ('policy-is-success', 'case VDTApplySkipUnsupported: return @"Rule not applied";',
         'case VDTApplySkipUnsupported: return @"Rule readback matched";', 'skip-not-success'),
        ('unlimited-active-attrs', '[pair[1] longLongValue] == VDT_APPLY_UNLIMITED_ATTRS &&',
         'YES &&', 'reject-partial-unlimited'),
        ('unlimited-inactive-attrs', '[pair[3] longLongValue] == VDT_APPLY_UNLIMITED_ATTRS)',
         'YES)', 'reject-partial-unlimited'),
        ('borrow-overall-state', 'return @"Side result not recorded";',
         'return @"Rule readback matched";', 'no-overall-fallback'),
        ('invent-missing-readback', 'NSString *observed = memory ? VDTCheckMemoryReadback(rawObserved, localize)\n        : (VDTCheckNumber(rawObserved) ?: VDTCheckText(localize, @"Not recorded"));',
         'NSString *observed = memory ? VDTCheckMemoryReadback(rawObserved, localize)\n        : (VDTCheckNumber(rawObserved) ?: target);', 'missing-readback'),
        ('forget-oldest-check', '(receipt[@"oldestCheckedAt"] ?: receipt[@"checkedAt"])',
         'receipt[@"checkedAt"]', 'receipt-time'),
        ('receipt-error-as-applied', '? @"Nice receipt exceeds size limit" : @"Nice receipt unavailable";',
         '? @"Nice state applied" : @"Nice receipt unavailable";', 'nice-status-limit'),
        ('receipt-save-time-as-check', '(receipt[@"oldestCheckedAt"] ?: receipt[@"checkedAt"])',
         '(receipt[@"oldestCheckedAt"] ?: receipt[@"checkedAt"] ?: receipt[@"receiptUpdatedAt"])', 'nice-status-no-check-time'),
    ]
    for name, old, new, expected in changes:
        assert source.count(old) == 1, 'non-unique mutation: ' + name
        yield name, source.replace(old, new, 1), expected


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--require-native', action='store_true')
    args = p.parse_args()
    if platform.system() != 'Darwin':
        print('SKIP check-result native gate: requires Darwin Foundation; no local build performed')
        return 1 if args.require_native else 77
    source_contracts()
    source = MODEL.read_text()
    with tempfile.TemporaryDirectory(prefix='vdt-check-model-') as directory:
        root = Path(directory)
        def build(text):
            src = root / 'VDTCheckResultModel.m'; src.write_text(text)
            binary = root / 'check-model'
            command = ['xcrun', 'clang', '-std=gnu11', '-fobjc-arc', '-fblocks', '-O1',
                       '-Wall', '-Wextra', '-Werror', '-I' + str(PREFS), '-I' + str(ROOT),
                       str(src), str(ROOT / 'tests/test_check_result_model_native.m'),
                       '-framework', 'Foundation', '-framework', 'CoreFoundation', '-o', str(binary)]
            subprocess.run(command, cwd=ROOT, check=True)
            return binary
        binary = build(source)
        subprocess.run([str(binary)], cwd=root, check=True)
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        for name, altered, expected in mutants(source):
            binary = build(altered)  # compile errors fail, never count as mutant kills
            result = subprocess.run([str(binary)], cwd=root, capture_output=True, text=True)
            assert result.returncode != 0 and 'CHECK_MODEL_FAIL:' + expected in result.stderr, \
                'mutant survived or failed off-target: ' + name + '\n' + result.stderr
            print('KILLED compiled display-model mutant:', name)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
