#!/usr/bin/env python3
"""Source-level safety wiring contracts. NOT Foundation or device execution."""
from pathlib import Path
import unittest
from test_resource_preferences_native import function_source
ROOT = Path(__file__).resolve().parents[1]

def contracts(runtime, shared, tweak):
    reconcile = function_source(runtime, 'void vdt_resource_reconcile(')
    apply = function_source(runtime, 'static BOOL resourceApply(')
    intent = function_source(runtime, 'static VDTResourceCurrentIntent resourceCurrentIntent(')
    check = function_source(runtime, 'void vdt_resource_begin_check(')
    publish = function_source(runtime, 'void vdt_resource_publish(')
    strict = function_source(shared, 'NSDictionary *VDTResourceReadPreferences(')
    reload = function_source(tweak, 'static void reloadPrefsSync(')
    for text in ('VDTResourceSelectRestores(', 'resourceCurrentIntent(retiredTarget, @"memoryRules")',
                 'resourceCurrentIntent(retiredTarget, @"jetsamRules")', 'resourceSuspendUnobservedDue(instance, selection)'):
        assert text in reconcile, text
    assert 'vdt_resource_apply(resourceRecords[instance][@"target"], NULL, NULL)' not in reconcile
    assert reconcile.index('resourceSuspendUnobservedDue(instance, selection)') < reconcile.index('if (!selection.memory && !selection.priority)')
    assert '!memory && restoreMissing && resourceCurrentIntent(target, @"memoryRules") == VDTResourceIntentRevoke' in apply
    assert '!jetsam && restoreMissing && resourceCurrentIntent(target, @"jetsamRules") == VDTResourceIntentRevoke' in apply
    assert '(memory || revokeMissingMemory || revokeAll)' in apply and '(jetsam || revokeMissingPriority || revokeAll)' in apply
    assert 'resourceGlobalConfigurationValid' in apply
    assert 'VDTPlanMemoryRule(&parsed, resourceDarwin, YES)' in intent and 'VDTPolicyPlanRestoreRequired' in intent
    assert 'type != VDTConfigTypeExtension) return VDTResourceIntentUnknown' in intent
    assert 'resourceSectionValid(section)' in intent
    assert 'resourceRowsByInstance = [NSMutableDictionary dictionary]' in check
    assert 'resourcePreviousRows = [resourceRows copy]' in check
    assert 'resourceRecords' not in check, 'display batch must not discard recovery'
    assert 'historical[@"historicalOnly"] = @YES' in publish
    assert '[historical removeObjectForKey:@"summaries"]' in publish
    assert '@"attemptedAt": resourceLastCheckAttempt' in publish
    for text in ('NSFileTypeRegular', 'VDT_NICE_STORE_LIMIT', 'NSPropertyListImmutable', 'return nil'):
        assert text in strict, text
    assert ': @{}' not in strict, 'failed preference read must not fabricate empty configuration'
    assert 'NSDictionary *resourcePrefs = VDTResourceReadPreferences()' in reload
    assert 'vdt_resource_rules_from_prefs(resourcePrefs)' in reload
    assert 'vdt_resource_reload(resourcePrefs)' in reload and 'vdt_resource_reload(newPrefs)' not in reload
    assert 'vdt_resolve_targets_checked(' in reload
    side = function_source(runtime, 'static BOOL resourceExecuteSide(')
    assert 'if (restore && [side[@"phase"] isEqual:@"restore-pending"] && atWanted)' in side
    assert side.index('if (!resourcePersist()) { detail[name] = @"store-error"; return NO; }') < side.index('VDTApplyExecute(')
    assert '@"original": current' in side
    assert 'side[@"original"] = current' not in side
    suspend = function_source(runtime, 'static void resourceSuspendUnobservedDue(')
    assert '[resourceDue removeObjectForKey:key]' in suspend and 'resourceAttempts' not in suspend
    assert 'memoryRestore' in suspend and 'priorityRestore' in suspend

class ComfortSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = (ROOT/'VDTResourceRuntime.mm').read_text(encoding='utf-8')
        cls.shared = (ROOT/'VDTResourceShared.mm').read_text(encoding='utf-8')
        cls.tweak = (ROOT/'Vedette.xm').read_text(encoding='utf-8')
    def test_current_source_wiring(self):
        contracts(self.runtime,self.shared,self.tweak)
    def test_old_missing_pointer_authority_is_rejected(self):
        old = '!memory && restoreMissing && resourceCurrentIntent(target, @"memoryRules") == VDTResourceIntentRevoke'
        with self.assertRaises(AssertionError):
            contracts(self.runtime.replace(old,'restoreMissing',1),self.shared,self.tweak)
    def test_reenable_restore_fast_return_is_rejected(self):
        with self.assertRaises(AssertionError):
            contracts(self.runtime.replace('if (restore && [side[@"phase"] isEqual:@"restore-pending"]',
                'if ([side[@"phase"] isEqual:@"restore-pending"]',1),self.shared,self.tweak)
    def test_legacy_empty_default_reload_is_rejected(self):
        with self.assertRaises(AssertionError):
            contracts(self.runtime,self.shared,self.tweak.replace('vdt_resource_reload(resourcePrefs)',
                'vdt_resource_reload(newPrefs)',1))
    def test_new_batch_cannot_erase_journal(self):
        old = 'resourcePreviousRows = [resourceRows copy]'
        with self.assertRaises(AssertionError):
            contracts(self.runtime.replace(old,'resourceRecords = [NSMutableDictionary dictionary]',1),self.shared,self.tweak)

if __name__ == '__main__': unittest.main(verbosity=2)
