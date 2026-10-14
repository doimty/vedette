#!/usr/bin/env python3
"""M5 resource-rule UI + storage contracts (source level, not a UIKit runtime test).

Pins: independent memoryRules/jetsamRules storage separate from the CPU config
records, a distinct get/set path, saved-vs-applied wording, schema stamping,
notification-only-on-successful-save, and localization for the new rows.
Negative controls must be rejected by the same evidence gates.
"""
from pathlib import Path
import unittest

from extension_projection import function_source
from test_resource_preferences_native import detail_contract as input_and_selector_contract
from test_preferences_ui import read_strings, validate_keys

ROOT = Path(__file__).resolve().parents[1]
DETAIL = ROOT / 'vedetteprefs/VDTProcessConfiguration.m'
SHARED_MM = ROOT / 'VDTShared.mm'
SHARED_H = ROOT / 'VDTShared.h'

NEW_LOC_KEYS = (
    'Memory',
    'Enable memory rule',
    'Active limit (MiB)',
    'Inactive limit (MiB)',
    'Saved memory rules are applied only with resource writes enabled. 0 restores the recorded value; -1 on both sides removes the per-process limit; positive pairs are hard MiB limits. Mixed modes are not supported.',
    'Reclaim priority',
    'Enable reclaim priority rule',
    'Priority band',
    'Saved reclaim-priority rules require resource writes. 0 = idle; disabling restores recorded values. Reserved and special bands are not applied. Observed effective priority may differ. High priority does not prevent memory-limit termination.',
)

RESOURCE_SELECTORS = 'set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:)'
CPU_SELECTORS = 'set:@selector(setProcessConfigValue:specifier:)'


def detail_contract(source):
    input_and_selector_contract(source)
    assert source.count(RESOURCE_SELECTORS) == 5, 'five resource rows must use the new get/set path'
    assert source.count(CPU_SELECTORS) == 4, 'CPU rows must keep the legacy path'
    assert 'PSSegmentCell' not in source
    for line in (
        '[memoryEnabledSpec setProperty:@"enabled" forKey:@"key"];',
        '[memoryEnabledSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];',
        '[memoryActiveSpec setProperty:@"active" forKey:@"key"];',
        '[memoryActiveSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];',
        '[memoryInactiveSpec setProperty:@"inactive" forKey:@"key"];',
        '[memoryInactiveSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];',
        '[jetsamEnabledSpec setProperty:@"enabled" forKey:@"key"];',
        '[jetsamEnabledSpec setProperty:@"jetsamRules" forKey:@"vdtRuleSection"];',
        '[jetsamBandSpec setProperty:@"priority" forKey:@"key"];',
        '[jetsamBandSpec setProperty:@"jetsamRules" forKey:@"vdtRuleSection"];',
    ):
        assert line in source, 'missing specifier contract: ' + line
    order = [
        'PSSpecifier *memoryGroupSpec',
        'PSSpecifier *memoryEnabledSpec',
        'memoryActiveSpec = [PSTextFieldSpecifier',
        'memoryInactiveSpec = [PSTextFieldSpecifier',
        'PSSpecifier *jetsamGroupSpec',
        'PSSpecifier *jetsamEnabledSpec',
        'jetsamBandSpec = [PSTextFieldSpecifier',
        '[rootSpecifiers addObject:jetsamBandSpec];',
    ]
    positions = [source.index(token) for token in order]
    assert positions == sorted(positions), 'resource sections must keep canonical order'
    assert source.index('[rootSpecifiers addObject:intervalSpec];') < positions[0]
    setter = function_source(source, '- (void)setResourceRuleValue:')
    assert 'setValueForProcessResourceRuleKey([self validIdentifier], key, parsed, [self configurationType], section);' in setter
    assert 'setValueForProcessConfigKey(' not in setter, 'resource setter must not write CPU records'
    reader = function_source(source, '- (id)readResourceRuleValue:')
    assert 'valueForProcessResourceRuleKey([self validIdentifier], key, [specifier propertyForKey:@"default"], [self configurationType], section);' in reader
    assert 'only with resource writes enabled' in source
    assert 'Historical readback, not live monitoring.' in source
    assert 'VDTResourceMatchingStatus(' in source
    assert 'this build only saves' not in source


def storage_contract(shared, header):
    for signature in ('static BOOL VDTSavePrefsReportingResult',
                      'id valueForProcessResourceRuleKeyWithPrefs',
                      'id valueForProcessResourceRuleKey(',
                      'BOOL setValueForProcessResourceRuleKeyWithPrefs',
                      'BOOL setValueForProcessResourceRuleKey(',
                      'BOOL VDTHasProcessResourceRule',
                      'void VDTRemoveProcessResourceRule'):
        assert signature in shared, 'missing storage function: ' + signature
    for declaration in ('valueForProcessResourceRuleKey', 'valueForProcessResourceRuleKeyWithPrefs',
                        'setValueForProcessResourceRuleKey', 'setValueForProcessResourceRuleKeyWithPrefs',
                        'VDTHasProcessResourceRule', 'VDTRemoveProcessResourceRule'):
        assert declaration in header, 'missing header declaration: ' + declaration
    save = function_source(shared, 'static BOOL VDTSavePrefsReportingResult')
    assert 'BOOL saved = [candidate writeToFile:PREFS_PATH atomically:YES];' in save
    assert 'if (!saved) return NO;' in save
    assert save.index('if (!saved) return NO;') < save.index('CFNotificationCenterPostNotification'), \
        'notification must follow a successful atomic save'
    setter = function_source(shared, 'BOOL setValueForProcessResourceRuleKeyWithPrefs')
    assert 'config[@"schema"] = VDT_RESOURCE_RULE_SCHEMA_VERSION;' in setter
    assert '@"schema": VDT_RESOURCE_RULE_SCHEMA_VERSION' in setter
    assert 'return VDTSavePrefsReportingResult(newPrefs);' in setter
    remove = function_source(shared, 'void VDTRemoveProcessResourceRule')
    assert 'VDTSavePrefsReportingResult(newPrefs);' in remove
    assert 'removed = YES;' in remove
    presence = function_source(shared, 'BOOL VDTHasProcessResourceRule')
    assert 'isEqualToString:identifier]) return YES;' in presence


class ResourceRuleUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.detail = DETAIL.read_text()
        cls.shared = SHARED_MM.read_text()
        cls.header = SHARED_H.read_text()
        cls.en = read_strings(ROOT / 'vedetteprefs/Resources/en.lproj/Localizable.strings')
        cls.zh = read_strings(ROOT / 'vedetteprefs/Resources/zh-Hans.lproj/Localizable.strings')

    def test_detail_and_storage_contracts(self):
        detail_contract(self.detail)
        storage_contract(self.shared, self.header)

    def test_new_rows_are_localized_in_both_languages(self):
        validate_keys(set(NEW_LOC_KEYS), self.en, self.zh)

    def test_missing_translation_is_rejected(self):
        broken = dict(self.zh)
        del broken['Memory']
        with self.assertRaises(AssertionError):
            validate_keys(set(NEW_LOC_KEYS), self.en, broken)

    def test_resource_setter_rerouted_to_cpu_store_is_rejected(self):
        mutated = self.detail.replace(
            'setValueForProcessResourceRuleKey([self validIdentifier], key, parsed, [self configurationType], section);',
            'setValueForProcessConfigKey([self validIdentifier], key, value, [self configurationType]);', 1)
        self.assertNotEqual(mutated, self.detail)
        with self.assertRaises(AssertionError):
            detail_contract(mutated)

    def test_old_getter_signature_is_rejected(self):
        mutated = self.detail.replace('get:@selector(readResourceRuleValue:)',
                                      'get:@selector(readResourceRuleValue:specifier:)', 1)
        self.assertNotEqual(mutated, self.detail)
        with self.assertRaises(AssertionError): detail_contract(mutated)

    def test_wrong_actual_getter_arity_is_rejected(self):
        mutated = self.detail.replace('- (id)readResourceRuleValue:(PSSpecifier*)specifier{',
                                      '- (id)readResourceRuleValue:(id)value specifier:(PSSpecifier*)specifier{', 1)
        self.assertNotEqual(mutated, self.detail)
        with self.assertRaises(AssertionError): detail_contract(mutated)

    def test_unconditional_notification_is_rejected(self):
        mutated = self.shared.replace('    if (!saved) return NO;\n', '', 1)
        self.assertNotEqual(mutated, self.shared)
        with self.assertRaises(AssertionError):
            storage_contract(mutated, self.header)

    def test_dropped_schema_marker_is_rejected(self):
        mutated = self.shared.replace('        config[@"schema"] = VDT_RESOURCE_RULE_SCHEMA_VERSION;\n', '', 1)
        self.assertNotEqual(mutated, self.shared)
        with self.assertRaises(AssertionError):
            storage_contract(mutated, self.header)

    def test_retitled_row_missing_storage_key_is_rejected(self):
        mutated = self.detail.replace(
            '[memoryEnabledSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];',
            '[memoryEnabledSpec setProperty:@"appConfigs" forKey:@"vdtRuleSection"];', 1)
        self.assertNotEqual(mutated, self.detail)
        with self.assertRaises(AssertionError):
            detail_contract(mutated)


if __name__ == '__main__':
    unittest.main(verbosity=2)
