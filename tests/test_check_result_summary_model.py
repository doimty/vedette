#!/usr/bin/env python3
"""Focused summary/reader/localization source contracts, NOT native execution.

The production model consumes the portable C helper. Foundation-directed cases
remain in test_check_result_model_native.m and require Darwin; these tests only
check source wiring and reject targeted source regressions on any Python host.
No build, install, notification, scan, retry, timer, or device/kernel operation.
"""
from pathlib import Path
import re
import unittest

from test_preferences_ui import read_strings, validate_keys
from test_resource_preferences_native import function_source

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'
FOOTER = 'Tap a result for details. These are the latest recorded checks, not live monitoring.'
COUNT_KEYS = ('total', 'applied', 'restored', 'failed', 'pending', 'unknown', 'disabled')
COUNT_IDS = ('summaryTotal', 'summaryConfirmed', 'summaryApplied', 'summaryRestored',
             'summaryFailed', 'summaryPending', 'summaryUnknown', 'summaryDisabled')


def model_contracts(source):
    assert '#include "../VDTResourceSummary.h"' in source, 'use the actual portable summary helper'
    integer = function_source(source, 'static NSNumber *VDTCheckInteger(')
    for required in ('CFBooleanGetTypeID()', 'strchr("cCsSiIlLqQ", type[0])',
                     'number >= INT32_MIN', 'number <= UINT32_MAX'):
        assert required in integer, 'strict integer type/range: ' + required
    latest = function_source(source, 'static NSDictionary *VDTCheckLatestCheck(')
    for required in ('VDTCheckDictionary(receipt[@"latestCheck"])',
                     'VDTCheckInteger(latest[@"version"])', 'version.longLongValue != 1',
                     'VDTCheckInteger(latest[@"batch"])', 'batch.longLongValue <= 0',
                     'VDTCheckBoolean(latest[@"enumerationComplete"])',
                     'VDTCheckInteger(latest[@"error"])', 'error.longLongValue < 0',
                     'error.longLongValue > INT_MAX', 'VDTCheckEpoch(latest[@"attemptedAt"])'):
        assert required in latest, 'strict latest-attempt envelope: ' + required
    summary = function_source(source, 'static VDTCheckSummary VDTCheckResourceSummary(')
    for required in ('result.state = VDTResourceSummaryInvalid;',
                     'receipt[@"summaries"] || receipt[@"checkBatch"] || receipt[@"latestCheck"]',
                     'VDTCheckTrue(receipt[@"sideEnvelopeInvalid"])',
                     '(receipt[@"historicalOnly"] && !VDTCheckFalse(receipt[@"historicalOnly"]))',
                     'VDTCheckTrue(receipt[@"configurationValid"])',
                     'VDTCheckDictionary(summaries[side])', 'VDTCheckLatestCheck(receipt)',
                     'VDTCheckInteger(summary[@"version"])', 'version.longLongValue != 1',
                     'VDTCheckInteger(summary[@"batch"])', 'batch.longLongValue <= 0',
                     'VDTCheckInteger(receipt[@"checkBatch"])', 'rowBatch.longLongValue <= 0',
                     '![batch isEqual:rowBatch]', '![batch isEqual:latest[@"batch"]]',
                     '![VDTCheckString(summary[@"scope"]) isEqual:@"identified-targets"]',
                     'VDTCheckBoolean(summary[@"enumerationComplete"])',
                     '![summary[@"enumerationComplete"] isEqual:latest[@"enumerationComplete"]]',
                     'NSNumber *count = VDTCheckInteger(summary[key]);',
                     '!count || count.longLongValue < 0 || count.longLongValue > 65536',
                     'if (!VDTResourceSummaryCountsValid(result.counts)) return result;',
                     'result.state = VDTResourceSummaryDecide(result.counts);'):
        assert required in summary, 'strict summary evidence: ' + required
    loop = 'for (NSString *key in @[' + ', '.join('@"' + key + '"' for key in COUNT_KEYS) + '])'
    assert loop in summary, 'every counter must be present; do not infer missing zeros'
    assert summary.index('VDTResourceSummaryCountsValid(') < summary.index('VDTResourceSummaryDecide(')
    selected = function_source(source, 'static NSDictionary *VDTCheckResourceReceipt(')
    for key in ('summaries', 'checkBatch', 'historicalOnly', 'latestCheck', 'configurationValid', 'settingsAvailable'):
        assert '@"' + key + '"' in selected, 'lost aggregate metadata on selected side: ' + key
    for required in ('[sideReceipt mutableCopy]',
                     'if (receipt[@"sideReceipts"] && !sideReceipt) selected[@"sideEnvelopeInvalid"] = @YES;',
                     'id checked = selected[[side stringByAppendingString:@"CheckedAt"]];',
                     'if (checked) selected[@"checkedAt"] = checked;'):
        assert required in selected, 'retain side evidence without success fallback: ' + required
    assert 'selected[@"checkedAt"] = receipt[@"checkedAt"]' not in selected
    row = function_source(source, 'static NSDictionary *VDTCheckRow(')
    for required in ('else if (resourceSummary.present)', 'resourceSummary.valid && !historical',
                     'VDTResourceSummaryConfirmedCount(counts)', 'counts.total > 1',
                     '@"Confirmed (%@/%@)"', '@"Partly confirmed (%@/%@)"',
                     'multiple ? @"Selected instance confirmed"', 'else if (localPending) compactState = @"Checking…";',
                     'if (unavailable) compactState = @"Saved settings unavailable";',
                     'else if (paused && !restored && !pending) compactState = @"Paused";',
                     'else if (off && !restored && !pending) compactState = @"Not enabled";',
                     '? @"No restoration needed" : @"No write requested"',
                     'memory && VDTCheckTrue(rule[@"enabled"]) &&',
                     '@"compactState": compactDisplay', '@"compactTone": compactTone'):
        assert required in row, 'honest compact summary: ' + required
    assert 'multiple ? @"Partly confirmed"' not in row, 'multiple is scope, not partial failure'
    assert '(restored ? @"Restored" : @"Applied")' not in row, 'confirmation is not an unqualified write claim'
    assert not re.search(r'if\s*\([^)]*resourceSummary[^)]*\)\s*rawObserved\s*=\s*nil', row), 'unknown coverage must keep history'
    assert row.count('VDTCheckField(@"policyNote",') == 1
    core = row[row.index('NSMutableArray *core ='):row.index('// Stable IDs/counts')]
    assert 'VDTCheckField(@"policyNote", @"Interpretation", interpretation, nil, localize)' in core.split(']];', 1)[0], 'interpretation must be an unconditional stable core field'
    assert 'VDTCheckField(@"coverage", @"Coverage"' in core
    assert 'VDTCheckField(@"lastAttempt", @"Last attempt", VDTCheckDate(latest[@"attemptedAt"])' in core
    assert 'VDTCheckField(@"checkTime", @"Last check", VDTCheckDate(VDTCheckTimeValue(receipt, nice))' in core
    for identifier in COUNT_IDS:
        assert row.count('VDTCheckDiagnostic(diagnostics, @"' + identifier + '",') == 1, 'stable count field: ' + identifier
    time = function_source(source, 'static id VDTCheckTimeValue(')
    assert '(receipt[@"oldestCheckedAt"] ?: receipt[@"checkedAt"])' in time
    for forbidden in ('latestCheck', 'attemptedAt', 'receiptUpdatedAt', 'NSDate.date', 'timeIntervalSince1970'):
        assert forbidden not in time, 'no lent observation time: ' + forbidden
    read_only_contracts(source)


def reader_contracts(source):
    read = function_source(source, 'NSArray<NSDictionary *> *VDTReadCheckResultModels(')
    assert read.count('VDTResourceReadPreferences()') == 1, 'one strict saved snapshot'
    assert 'getPrefs(' not in source and 'prefs = @{}' not in source, 'no empty/defaulting preference reader'
    for required in ('if ([prefs isKindOfClass:NSDictionary.class])',
                     'VDTNiceEffectiveRule(identifier, type, host, prefs)',
                     'VDTNiceMatchingStatusWithHost(identifier, type, host, prefs)',
                     'VDTResourceMatchingStatus(identifier, type, prefs)',
                     'resourceRule(@"memoryRules", identifier, type, host, prefs)',
                     'resourceRule(@"jetsamRules", identifier, type, host, prefs)',
                     '[niceReceipt mutableCopy]', 'pending[@"localPending"] = @YES;',
                     'niceReceipt = [pending copy];'):
        assert required in read, 'snapshot/pending receipt preserved: ' + required
    assert 'nicePending ? nil' not in read and 'niceReceipt = nicePending ?' not in read, 'pending is a flag, not erased history'
    rule = function_source(source, 'static NSDictionary *resourceRule(')
    assert rule.index('if (![prefs isKindOfClass:NSDictionary.class]') < rule.index('VDTHasProcessResourceRule('), 'nil WithPrefs must not reread the file'
    assert 'valueForProcessResourceRuleKeyWithPrefs(source, key, nil, sourceType, section, prefs)' in rule
    assert 'readerSectionValid(prefs, section)' in rule
    metadata = function_source(source, 'static NSDictionary *readerRule(')
    assert 'result[@"settingsAvailable"] = @(available);' in metadata
    assert 'result[@"configurationValid"] = available && readerGlobalValid(prefs) && sectionValid ? @YES : @NO;' in metadata
    assert 'result[@"configurationValid"] = @(available &&' not in metadata, 'logical expression boxes as int in Objective-C'
    assert 'return [result copy];' in metadata
    read_only_contracts(source)


def read_only_contracts(source):
    for forbidden in ('notify_post(', 'notify_register', 'memorystatus_control(', 'setpriority(',
                      'writeToFile:', 'VDTResourceSetWriteEnabled', 'VDTResourceSave',
                      'requestRetry', 'CFNotificationCenterPostNotification', 'NSTimer',
                      'scheduledTimer', 'dispatch_after', 'dispatch_source_create', 'NSURLSession',
                      'vdt_resource_apply(', 'vdt_resource_reconcile(', 'NSDate.date'):
        assert forbidden not in source, 'read-only historical projection: ' + forbidden


def localization_keys(source):
    required = set(re.findall(r'VDTCheckText\(localize,\s*@"([^"\n]+)"', source))
    required |= set(re.findall(r'\b(?:key|compactState|stateKey)\s*=\s*@"([^"\n]+)"', source))
    for prefix in ('static NSString *VDTCheckNiceState(', 'static NSString *VDTCheckResourceState('):
        body = function_source(source, prefix)
        required |= set(re.findall(r'return @"([^"\n]+)"', body))
        required |= set(re.findall(r'@"[^"\n]+": @"([^"\n]+)"', body))
    for expression in re.findall(r'VDTCheckField\(@"[^"\n]+",\s*([^,]+),', source):
        required |= set(re.findall(r'@"([^"\n]+)"', expression))
    required |= set(re.findall(r'VDTCheckDiagnostic\(diagnostics,\s*@"[^"\n]+",\s*@"([^"\n]+)"', source))
    required |= {'nice', 'Memory', 'Reclaim priority', 'Recent check results', FOOTER,
                 'Confirmed', 'Confirmed (%@/%@)', 'Partly confirmed (%@/%@)',
                 'Selected instance confirmed', 'Checking…', 'Paused', 'No restoration needed',
                 'No write requested', 'Saved target (active / inactive): %@', 'Saved target: %@'}
    return required


def localization_contracts(source):
    en = read_strings(PREFS / 'Resources/en.lproj/Localizable.strings')
    zh = read_strings(PREFS / 'Resources/zh-Hans.lproj/Localizable.strings')
    validate_keys(localization_keys(source), en, zh)
    for key, expected in {'Confirmed': '已确认', 'Confirmed (%@/%@)': '已确认（%@/%@）',
                          'Partly confirmed (%@/%@)': '部分确认（%@/%@）',
                          'Selected instance confirmed': '已确认（仅此记录）',
                          'Not applied': '未应用', 'Checking…': '正在检查…',
                          'No restoration needed': '无需恢复', 'Yes': '是', 'No': '否',
                          'Edit settings': '返回修改设置'}.items():
        assert zh[key] == expected, 'user-facing Chinese status: ' + key


def source_contracts():
    model = (PREFS / 'VDTCheckResultModel.m').read_text(encoding='utf-8')
    reader = (PREFS / 'VDTCheckResultReader.m').read_text(encoding='utf-8')
    model_contracts(model)
    reader_contracts(reader)
    localization_contracts(model)


class CheckResultSummarySourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = (PREFS / 'VDTCheckResultModel.m').read_text(encoding='utf-8')
        cls.reader = (PREFS / 'VDTCheckResultReader.m').read_text(encoding='utf-8')

    def test_production_summary_reader_localization(self):
        source_contracts()

    def reject(self, source, old, new, contract=model_contracts):
        self.assertEqual(source.count(old), 1, 'unique mutation anchor')
        with self.assertRaises(AssertionError):
            contract(source.replace(old, new, 1))

    def test_bypassing_portable_sum_is_rejected(self):
        self.reject(self.model, 'if (!VDTResourceSummaryCountsValid(result.counts)) return result;', '')

    def test_bypassing_portable_decision_is_rejected(self):
        self.reject(self.model, 'result.state = VDTResourceSummaryDecide(result.counts);', 'result.state = VDTResourceSummaryConfirmed;')

    def test_missing_unknown_counter_is_rejected(self):
        self.reject(self.model, '@"failed", @"pending", @"unknown", @"disabled"]', '@"failed", @"pending", @"disabled"]')

    def test_coerced_counter_is_rejected(self):
        self.reject(self.model, 'NSNumber *count = VDTCheckInteger(summary[key]);', 'NSNumber *count = @([summary[key] intValue]);')

    def test_negative_counter_is_rejected(self):
        self.reject(self.model, '!count || count.longLongValue < 0 || count.longLongValue > 65536', '!count || count.longLongValue > 65536')

    def test_oversized_counter_is_rejected(self):
        self.reject(self.model, 'count.longLongValue > 65536', 'count.longLongValue > UINT32_MAX')

    def test_stale_row_batch_is_rejected(self):
        self.reject(self.model, ' || ![batch isEqual:rowBatch]', '')

    def test_stale_latest_batch_is_rejected(self):
        self.reject(self.model, ' || ![batch isEqual:latest[@"batch"]]', '')

    def test_numeric_enumeration_is_rejected(self):
        self.reject(self.model, '!VDTCheckBoolean(summary[@"enumerationComplete"])', '!summary[@"enumerationComplete"]')

    def test_inconsistent_enumeration_is_rejected(self):
        self.reject(self.model, '![summary[@"enumerationComplete"] isEqual:latest[@"enumerationComplete"]]', 'NO')

    def test_unbounded_latest_error_is_rejected(self):
        self.reject(self.model, 'error.longLongValue > INT_MAX', 'NO')

    def test_invalid_latest_time_is_rejected(self):
        self.reject(self.model, '!VDTCheckEpoch(latest[@"attemptedAt"])', 'NO')

    def test_historical_success_fallback_is_rejected(self):
        self.reject(self.model, '(receipt[@"historicalOnly"] && !VDTCheckFalse(receipt[@"historicalOnly"]))', 'NO')

    def test_missing_selected_side_is_rejected(self):
        self.reject(self.model, 'if (receipt[@"sideReceipts"] && !sideReceipt) selected[@"sideEnvelopeInvalid"] = @YES;', '')

    def test_lost_selected_batch_metadata_is_rejected(self):
        self.reject(self.model, '@"storeError", @"summaries", @"checkBatch",', '@"storeError", @"summaries",')

    def test_legacy_multi_as_partial_is_rejected(self):
        self.reject(self.model, 'multiple ? @"Selected instance confirmed"', 'multiple ? @"Partly confirmed"')

    def test_summary_unknown_erasing_readback_is_rejected(self):
        self.reject(self.model, 'if (nice && multiple) rawObserved = nil;', 'if (!resourceSummary.valid) rawObserved = nil;')

    def test_conditional_missing_interpretation_is_rejected(self):
        self.reject(self.model, 'VDTCheckField(@"policyNote", @"Interpretation", interpretation, nil, localize)', 'VDTCheckField(@"extra", @"Interpretation", interpretation, nil, localize)')

    def test_unnecessary_restoration_as_off_is_rejected(self):
        self.reject(self.model, '? @"No restoration needed" : @"No write requested"', '? @"Not enabled" : @"Not enabled"')

    def test_pending_dropping_receipt_is_rejected(self):
        self.reject(self.reader, '[niceReceipt mutableCopy]', '[NSMutableDictionary dictionary]', reader_contracts)

    def test_logical_expression_integer_boxing_is_rejected(self):
        self.reject(self.reader,
            'result[@"configurationValid"] = available && readerGlobalValid(prefs) && sectionValid ? @YES : @NO;',
            'result[@"configurationValid"] = @(available && readerGlobalValid(prefs) && sectionValid);', reader_contracts)

    def test_defaulted_preferences_are_rejected(self):
        self.reject(self.reader, 'VDTResourceReadPreferences()', 'getPrefs() ?: @{}', reader_contracts)

    def test_new_timer_is_rejected(self):
        self.reject(self.reader, 'pending[@"localPending"] = @YES;', 'pending[@"localPending"] = @YES; dispatch_after();', reader_contracts)


if __name__ == '__main__':
    unittest.main(verbosity=2)
