#!/usr/bin/env python3
"""Extension integration + exact legacy source freezes (not UIKit/device tests).

Evidence assertions are function-scoped. Mutants must change real source once
and be rejected by the relevant evidence gate, not merely by a missing field
or a self-hash. Old CPU/UI logic also remains byte-equal after exact projection.
"""
import json
import re
import subprocess
import unittest
from extension_projection import (
    ROOT, APPEX_BASE, REVIEWED_PATHS, CI_PATH, baseline_bytes, assert_ui21_freeze,
    function_source, projected_bytes, reviewed_regions,
)

SHARED = 'VDTShared.mm'
MANAGER = 'VDTProcessManager.mm'
DETAIL = 'vedetteprefs/VDTProcessConfiguration.m'
LIST = 'vedetteprefs/VDTExtensionListController.m'
METADATA = 'VDTBundleIdentity.mm'
SOURCES = [SHARED, 'VDTShared.h', MANAGER, DETAIL, LIST, METADATA,
           'Vedette.xm', 'vedetteprefs/VDTRootListController.m']


def has(text, *tokens):
    for token in tokens:
        assert token in text, 'missing extension evidence: ' + token


def storage_contract(sources):
    h = sources['VDTShared.h']
    has(h, 'VDTConfigTypeApp = 0,', 'VDTConfigTypeDaemon = 1,', 'VDTConfigTypeExtension = 2')
    shared = sources[SHARED]
    for signature, pairs in (
        ('static NSString *VDTConfigIdentifier', [('App', 'bundleIdentifier'), ('Daemon', 'daemonName'), ('Extension', 'extensionIdentifier')]),
        ('static NSString *VDTConfigSection', [('App', 'appConfigs'), ('Daemon', 'daemonConfigs'), ('Extension', 'extensionConfigs')]),
    ):
        body = function_source(shared, signature)
        for kind, key in pairs: has(body, 'case VDTConfigType' + kind + ': return @"' + key + '";')
        has(body, 'default: return nil;')
    getter = function_source(shared, 'id valueForProcessConfigKeyWithPrefs')
    setter = function_source(shared, 'void setValueForProcessConfigKeyWithPrefs')
    has(getter, 'if (!identifierKey || !sectionKey) return defaultValue;', 'VDTConfigArray(source[sectionKey])')
    has(setter, 'if (!identifierKey || !sectionKey) return;', 'setValueForKeyWithPrefs(sectionKey, configs, source);')
    presence = function_source(shared, 'BOOL VDTHasProcessConfig')
    has(presence, 'if (!sectionKey || !identifierKey) return NO;', 'isEqualToString:identifier]) return YES;')
    assert '@"enabled"' not in presence, 'disabled override must still be present'
    remove = function_source(shared, 'void VDTRemoveProcessConfig')
    has(remove, 'if (!sectionKey || !identifierKey) return;', 'for (id raw in VDTConfigArray(source[sectionKey]))',
        'removed = YES;', '[remaining addObject:raw];', 'if (removed) setValueForKeyWithPrefs(sectionKey, remaining, source);')
    assert 'break;' not in remove, 'inheritance must remove ALL duplicate overrides'
    save = function_source(shared, 'void setValueForKeyWithPrefs')
    has(save, '[newPrefs writeToFile:PREFS_PATH atomically:YES];',
        'CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),', '(CFStringRef)PREFS_CHANGED_NN,')


def resolution_contract(sources):
    pm = sources[MANAGER]
    normalized = function_source(pm, 'NSArray<NSDictionary *>* vdt_configs_from_prefs')
    has(normalized, 'configs_from_section(validatedPrefs, @"extensionConfigs", @"extensionIdentifier",\n                                                     VDTConfigTypeExtension, globallyEnabled)')
    split = function_source(pm, 'static void split_configs')
    has(split, 'else if (type == VDTConfigTypeExtension)', 'if (!extensionConfigsById[identifier]) extensionConfigsById[identifier] = config;',
        'else if (type == VDTConfigTypeDaemon)')
    assert not re.search(r'else\s*\{', split), 'unknown types cannot become daemons'
    target = function_source(pm, 'static NSDictionary *target_for_pid')
    has(target, 'NSString *extensionPath', 'if (ruleChoice == VDTBundleRuleDaemon && daemonConfigs.count > 0)')
    classification = target[target.index('NSString *extensionPath'):target.index('if (ruleChoice == VDTBundleRuleDaemon')]
    has(classification, 'VDTNearestBundlePath(executablePath, @"appex")', 'VDTReadExtensionBundleInfo(extensionPath, executablePath)',
        'vdt_nonEmptyString(extensionInfo[@"extensionIdentifier"])',
        'extensionIdentifier ? extensionConfigsById[extensionIdentifier] : nil',
        '(!extensionPath || (extensionIdentifier && !extensionConfig))',
        'VDTChooseBundleRule(bundlePath != nil, extensionPath != nil,\n        extensionIdentifier != nil, extensionConfig != nil, appConfig != nil)',
        'if (ruleChoice == VDTBundleRuleExtension)', 'matched = extensionConfig;', 'matchedName = extensionIdentifier;',
        'else if (ruleChoice == VDTBundleRuleApp)')
    assert 'VDTConfigEnabledKey' not in classification, 'explicit off/invalid cannot fall back to App'
    has(target, 'if (ruleChoice == VDTBundleRuleDaemon && daemonConfigs.count > 0)',
        'if (!matched && !hasResourceIntent) return nil;', 'NSNumber *policy = enabled ? vdt_number(matched[VDTConfigPolicyKey]) : @(VDTViolationPolicyNone);')
    for signature in ('NSArray<NSDictionary *>* vdt_resolve_targets', 'NSArray<NSDictionary *>* vdt_targets_for_pid'):
        scan = function_source(pm, signature)
        has(scan, 'NSMutableDictionary<NSString *, NSDictionary *> *extensionConfigsById = [NSMutableDictionary dictionary];',
            'split_configs(configs, appConfigsById, extensionConfigsById, daemonConfigs);',
            'target_for_pid(pid, appConfigsById, extensionConfigsById, daemonConfigs, resourceMaps)')
        assert 'if (appConfigsById.count == 0 && daemonConfigs.count == 0)' not in scan, 'extension-only configs must reach PID matching'
    scan = function_source(pm, 'NSArray<NSDictionary *>* vdt_resolve_targets')
    has(scan, 'if (appConfigsById.count == 0 && extensionConfigsById.count == 0 && daemonConfigs.count == 0 &&\n        resource_maps_empty(resourceMaps)) return @[];')
    one = function_source(pm, 'NSArray<NSDictionary *>* vdt_targets_for_pid')
    has(one, 'return target ? @[target] : @[];')


def metadata_contract(sources):
    info = function_source(sources[METADATA], 'NSDictionary<NSString *, NSString *> *VDTReadExtensionBundleInfo')
    has(info, '[bundlePath hasPrefix:@"/"]', '[bundlePath.pathExtension caseInsensitiveCompare:@"appex"] != NSOrderedSame',
        '[raw isKindOfClass:[NSDictionary class]]', 'valid_string(info[@"CFBundleIdentifier"])',
        '!VDTBundleExecutableNameIsValid(name.UTF8String)', '![extension isKindOfClass:[NSDictionary class]]',
        '!valid_string(((NSDictionary *)extension)[@"NSExtensionPointIdentifier"])',
        'fileExistsAtPath:expectedPath isDirectory:&isDirectory] || isDirectory',
        '![expectedPath isEqualToString:executablePath]', '@"extensionIdentifier": identifier', '@"executablePath": expectedPath')


def ui_contract(sources):
    source = sources[LIST]
    records = function_source(source, 'static NSArray<NSDictionary *> *extension_records')
    has(records, 'respondsToSelector:@selector(defaultWorkspace)', 'respondsToSelector:@selector(allApplications)',
        'respondsToSelector:@selector(bundleURL)', 'stringByAppendingPathComponent:@"PlugIns"',
        'contentsOfDirectoryAtPath:pluginsPath', 'VDTReadExtensionBundleInfo(path, nil)',
        'if (!identifier || byIdentifier[identifier]) continue;', 'byIdentifier[identifier] = [record copy];')
    for token in ('enumeratorAtPath:', 'enumeratorAtURL:', 'subpathsAtPath:'): assert token not in source, 'no recursive scanning'
    refresh = function_source(source, '- (void)refreshExtensionRecords')
    stages = ['dispatch_async(dispatch_get_global_queue(', 'NSArray *records = extension_records();',
              'dispatch_async(dispatch_get_main_queue(),', 'owner.extensionRecords = records;', '[owner reloadSpecifiers];']
    has(refresh, *stages)
    positions = [refresh.index(stage) for stage in stages]
    assert positions == sorted(positions), 'enumeration must be background, publication/reload main'
    has(refresh, 'if (self.enumerating) return;', 'if (!owner || generation != owner.enumerationGeneration) return;')
    specifiers = function_source(source, '- (NSArray *)specifiers')
    has(specifiers, 'VDTGroupedListSpecifiers(rows, @"extensionIdentifier", VDTConfigTypeExtension,',
        'setProperty:@(VDTConfigTypeExtension) forKey:@"configurationType"',
        '[row.name localizedStandardContainsString:query]',
        '[[row propertyForKey:@"extensionIdentifier"] localizedStandardContainsString:query]',
        '[[row propertyForKey:@"containingAppName"] localizedStandardContainsString:query]')
    preview = function_source(source, '- (id)previewStringForSpecifier')
    has(preview, 'if (!VDTHasProcessConfig(identifier, VDTConfigTypeExtension, prefs))',
        '@"Follow containing app"', '@"Independent rule off"')
    detail = sources[DETAIL]
    button = function_source(detail, '- (void)confirmFollowContainingApp')
    has(button, 'if ([self configurationType] != VDTConfigTypeExtension) return;', 'UIAlertActionStyleDestructive',
        'VDTRemoveProcessConfig([owner validIdentifier], VDTConfigTypeExtension);',
        'reloadExtensionRule:[owner validIdentifier]', '[owner reloadSpecifiers];')
    has(detail, '[inheritance setButtonAction:@selector(confirmFollowContainingApp)];', 'case VDTConfigTypeExtension:',
        'propertyForKey:@"extensionIdentifier"')
    root = sources['vedetteprefs/VDTRootListController.m']
    has(root, 'detail:VDTExtensionListController.class cell:PSLinkCell edit:nil]', '[rootSpecifiers addObject:extensionListSpec];')
    for forbidden in ('scheduledTimer', 'dispatch_source_create', 'NSURLSession', ' appearance]'):
        assert forbidden not in source, 'no polling/network/global UI change'


def parse_strings(source):
    pattern = r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;'
    pairs = re.findall(pattern, source)
    assert not re.sub(pattern, '', source).strip(), 'invalid strings syntax'
    result = {}
    for key, value in pairs:
        key, value = json.loads(key), json.loads(value)
        assert key not in result, 'duplicate translation key'
        result[key] = value
    return result


def localization_contract(path, source):
    old = parse_strings(baseline_bytes(path).decode())
    now = parse_strings(source)
    for key, value in old.items(): assert now.get(key) == value, 'legacy translation changed: ' + key
    assert 'App extensions' in now and 'Follow containing app' in now, 'extension labels missing'


def extension_evidence(sources):
    storage_contract(sources)
    resolution_contract(sources)
    metadata_contract(sources)
    ui_contract(sources)


class ExtensionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {name: (ROOT / name).read_text() for name in SOURCES}

    def test_reviewed_regions_project_to_real_ui21_baseline(self):
        self.assertGreaterEqual(sum(len(v) for v in reviewed_regions().values()), 15)
        for name in REVIEWED_PATHS:
            with self.subTest(file=name): assert_ui21_freeze(name)
        assert_ui21_freeze(CI_PATH)

    def test_storage_types_and_presence_remove_notifications(self): storage_contract(self.sources)
    def test_two_pid_entries_precedence_and_no_daemon_fallback(self): resolution_contract(self.sources)
    def test_validated_extension_metadata_and_executable(self): metadata_contract(self.sources)
    def test_native_ui_enumeration_search_and_inheritance_wiring(self): ui_contract(self.sources)

    def test_every_preexisting_production_source_keeps_ui21_bytes(self):
        names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', APPEX_BASE], cwd=ROOT, text=True).splitlines()
        for name in names:
            if name.startswith('tests/'): continue
            if name.endswith(('.h', '.c', '.m', '.mm', '.xm', '.plist')) or name in (
                    'control', 'Makefile', 'vedetteprefs/Makefile', 'layout/DEBIAN/postinst', 'layout/DEBIAN/postrm'):
                with self.subTest(file=name): assert_ui21_freeze(name)

    def test_legacy_english_chinese_keys_and_values_cannot_change(self):
        for language in ('en', 'zh-Hans'):
            path = 'vedetteprefs/Resources/' + language + '.lproj/Localizable.strings'
            source = (ROOT / path).read_text()
            localization_contract(path, source)
            broken = source.replace('"Enable Vedette" = ', '"Changed old key" = ', 1)
            self.assertNotEqual(broken, source)
            with self.assertRaises(AssertionError): localization_contract(path, broken)
            marker = re.search(r'"Enable Vedette"\s*=\s*"[^"]*";', source)[0]
            broken = source.replace(marker, '"Enable Vedette" = "changed old value";', 1)
            with self.assertRaises(AssertionError): localization_contract(path, broken)

    def test_source_mutations_are_rejected_by_extension_evidence(self):
        mutations = [
            ('VDTShared.h', 'VDTConfigTypeExtension = 2', 'VDTConfigTypeExtension = 3'),
            (SHARED, 'default: return nil;', 'default: return @"daemonName";'),
            (SHARED, 'if (!identifierKey || !sectionKey) return defaultValue;', 'if (!identifierKey && !sectionKey) return defaultValue;'),
            (SHARED, 'removed = YES;', 'removed = YES; break;'),
            (MANAGER, 'if (!extensionConfigsById[identifier]) extensionConfigsById[identifier] = config;', 'extensionConfigsById[identifier] = config;'),
            (MANAGER, 'VDTNearestBundlePath(executablePath, @"appex")', 'VDTNearestBundlePath(executablePath, @"app")'),
            (MANAGER, 'extensionIdentifier != nil, extensionConfig != nil, appConfig != nil)', 'extensionIdentifier != nil, extensionConfig && [extensionConfig[VDTConfigEnabledKey] boolValue], appConfig != nil)'),
            (MANAGER, 'if (ruleChoice == VDTBundleRuleDaemon && daemonConfigs.count > 0)', 'if (daemonConfigs.count > 0)'),
            (METADATA, '![expectedPath isEqualToString:executablePath]', '![expectedPath hasPrefix:executablePath]'),
            (LIST, 'dispatch_async(dispatch_get_main_queue(),', 'dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),'),
            (LIST, 'if (!identifier || byIdentifier[identifier]) continue;', 'if (!identifier) continue;'),
            (DETAIL, 'VDTRemoveProcessConfig([owner validIdentifier], VDTConfigTypeExtension);', 'VDTRemoveProcessConfig([owner validIdentifier], VDTConfigTypeApp);'),
        ]
        for name, old, new in mutations:
            with self.subTest(file=name, mutant=old):
                altered = dict(self.sources)
                self.assertIn(old, altered[name])
                altered[name] = altered[name].replace(old, new, 1)
                self.assertNotEqual(altered[name], self.sources[name])
                with self.assertRaises(AssertionError): extension_evidence(altered)

    def test_old_logic_mutations_cannot_hide_in_projection(self):
        for name, old, new in [
            (MANAGER, 'percentage <= UINT8_MAX : percentage <= 100', 'percentage <= UINT8_MAX : percentage <= 1000'),
            ('Vedette.xm', '100 * NSEC_PER_MSEC', '1000 * NSEC_PER_MSEC'),
            ('VDTShared.mm', '[newPrefs writeToFile:PREFS_PATH atomically:YES];', '[newPrefs writeToFile:PREFS_PATH atomically:NO];'),
        ]:
            with self.subTest(file=name):
                original = (ROOT / name).read_text()
                self.assertEqual(original.count(old), 1)
                with self.assertRaises(AssertionError): assert_ui21_freeze(name, original.replace(old, new, 1))

if __name__ == '__main__':
    unittest.main(verbosity=2)
