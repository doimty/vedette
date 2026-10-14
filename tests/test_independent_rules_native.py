#!/usr/bin/env python3
"""Independent-rules native regression (four pin kinds x three types, mixed
duplicate families, nice UI save/follow, real VDTShared/VDTNiceShared stores).

--static-only : source-level evidence everywhere (runs on Linux/Alpine).
default       : static, then native. Non-Darwin native => explicit SKIP exit 77.
--require-native: non-Darwin native is a FAILURE (exit 1), never a passing skip.

Native builds compile the real production translation units (VDTShared.mm,
VDTNiceShared.mm, VDTNiceStore.c) plus verbatim-extracted VDTListPresentation.m
and VDTNicePreferences.m text. No production file, old test or projection is
modified. Mutants are compiled production text; a mutant counts as killed only
when it builds AND the fixture fails at the designated assert tag.
"""
from pathlib import Path
import argparse
import platform
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STUBS = ROOT / 'tests/independent_rules_stubs'
LIST = ROOT / 'vedetteprefs/VDTListPresentation.m'
NICE = ROOT / 'vedetteprefs/VDTNicePreferences.m'
OWNER = ROOT / 'vedetteprefs/VDTProcessConfiguration.m'
EXTLIST = ROOT / 'vedetteprefs/VDTExtensionListController.m'
SHARED = ROOT / 'VDTShared.mm'
NICE_SHARED = ROOT / 'VDTNiceShared.mm'
FIXTURE = ROOT / 'tests/test_independent_rules_native.mm'

LIST_FUNCS = (
    'static BOOL VDTListStrictEnabled',
    'BOOL VDTListConfigurationEnabled',
    'NSString *VDTListExtensionSubtitleKey',
    'static int VDTCompareListNames',
    'NSMutableArray<PSSpecifier *> *VDTGroupedListSpecifiers',
)
OWNER_FUNCS = (
    '- (NSString*)validIdentifier',
    '-(VDTConfigType)configurationType',
    '- (NSString *)vdtNiceIdentifier',
    '- (VDTConfigType)vdtNiceConfigurationType',
    '- (VDTNicePreferences *)vdtNicePreferences',
    '- (NSArray *)specifiers',
    '- (void)vdtReloadIndependentRules',
    '- (void)vdtFollowMemoryApp', '- (void)vdtFollowJetsamApp',
    '- (void)vdtFollowResourceSection:', '- (void)presentResourceRuleError:',
)
NICE_MARKERS = (
    '// Metadata is populated only by the list\'s verified background enumeration.',
    '@interface VDTNicePreferences () {',
    '@implementation VDTNicePreferences',
)
FOUR_PINS = 'cpuEnabled || niceEnabled || memoryEnabled || jetsamEnabled'
SUBTITLE_RESOURCE = '"CPU follows app; independent rules enabled"'
SUBTITLE_CPU = '"Independent configurations enabled"'
CPU_SKIP = '(cpuField && !VDTProcessConfigHasCPUFields(config))'
NICE_SKIP = '(niceField && !config[@"niceEnabled"] && !config[@"niceValue"] && !config[@"niceRevision"])'


def function_source(source, prefix):
    """Balanced extraction with comments / string and character literals skipped."""
    assert source.count(prefix) == 1, 'function anchor not unique: ' + prefix
    start = source.index(prefix)
    opening = source.index('{', start)
    depth, index = 0, opening
    while index < len(source):
        if source.startswith('//', index):
            index = source.find('\n', index)
            assert index >= 0, 'unterminated source comment'
        elif source.startswith('/*', index):
            closing = source.find('*/', index + 2)
            assert closing >= 0, 'unterminated block comment'
            index = closing + 2
            continue
        elif source[index] in ('"', "'"):
            quote = source[index]
            index += 1
            while index < len(source) and source[index] != quote:
                index += 2 if source[index] == '\\' else 1
            assert index < len(source), 'unterminated literal'
        elif source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise AssertionError('unbalanced function: ' + prefix)


def list_contract(source):
    strict = function_source(source, LIST_FUNCS[0])
    assert 'CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()' in strict
    assert 'CFBooleanGetValue((__bridge CFBooleanRef)value)' in strict
    enabled = function_source(source, LIST_FUNCS[1])
    assert 'type != VDTConfigTypeApp && type != VDTConfigTypeDaemon &&' in enabled
    assert 'type != VDTConfigTypeExtension)) return NO;' in enabled
    assert 'NSDictionary *snapshot = prefs ?: getPrefs();' in enabled
    assert enabled.count('getPrefs()') == 1, 'no extra disk read in the pin decision'
    for text in ('valueForProcessConfigKeyWithPrefs(identifier, @"enabled", nil, type, snapshot)',
                 'VDT_NICE_ENABLED_KEY, @NO, type, snapshot',
                 'identifier, @"enabled", @NO, type, @"memoryRules", snapshot',
                 'identifier, @"enabled", @NO, type, @"jetsamRules", snapshot'):
        assert text in enabled, 'missing independent pin input: ' + text
    assert FOUR_PINS in enabled, 'pin is CPU || nice || memory || jetsam'
    assert 'VDT_NICE_VALUE_KEY' not in enabled, 'saved nice value alone must not pin'
    subtitle = function_source(source, LIST_FUNCS[2])
    assert 'NSDictionary *snapshot = prefs ?: getPrefs();' in subtitle
    assert 'VDTHasProcessConfig(identifier, VDTConfigTypeExtension, snapshot)' in subtitle
    for text in (SUBTITLE_RESOURCE, SUBTITLE_CPU, '"CPU follows app; independent rules off"',
                 '"Follow containing app"', '"Independent rule off"'):
        assert text in subtitle, 'missing subtitle distinction: ' + text
    grouped = function_source(source, LIST_FUNCS[4])
    assert grouped.count('getPrefs()') == 1, 'one snapshot per rebuild'
    assert '[specifier setProperty:prefs forKey:@"vdtListPrefsSnapshot"];' in grouped
    assert 'VDTListConfigurationEnabled(identifier, type, prefs)' in grouped
    assert '[source ' not in grouped and 'source addObject' not in grouped, \
        'must not mutate the source array'


def nice_contract(source):
    assert source.count(NICE_MARKERS[0]) == 1 and source.count(NICE_MARKERS[1]) == 1
    static = source[source.index(NICE_MARKERS[0]):source.index(NICE_MARKERS[1])]
    assert 'static NSString *VDTNiceContainingAppIdentifier(NSString *identifier, NSDictionary *metadata)' in static
    assert '![metadata[@"extensionIdentifier"] isEqual:identifier]) return nil;' in static
    assert 'return [host isKindOfClass:[NSString class]] && [host length] > 0 ? host : nil;' in static
    assert 'NSDictionary *rule = VDTNiceEffectiveRule(identifier, type, host, snapshot);' in static
    assert 'rule[field] ?: fallback;' in static
    body = source[source.index(NICE_MARKERS[2]):source.rindex('@end')]
    remove = function_source(body, '- (void)removeIndependentNiceRule')
    assert 'if (self.configurationType != VDTConfigTypeExtension) return;' in remove, 'extension-only guard'
    assert 'BOOL saved = VDTNiceRemoveIndependentRule(self.identifier, self.configurationType, &error);' in remove
    assert 'if (!saved) [self presentSaveError:error];' in remove
    inheritance = function_source(body, '- (void)updateInheritancePresentation')
    assert 'VDTNiceHasIndependentRule(self.identifier, self.configurationType, getPrefs())' in inheritance
    assert inheritance.count('[_owner reloadSpecifier:') == 2, 'inheritance reload reaches the owner'
    save = function_source(body, '- (void)saveValue:')
    for text in ('[self setPendingStatusAndReload];', '[self updateInheritancePresentation];',
                 '[_owner vdtReloadIndependentRules];'):
        assert text in save, 'lost parent refresh: ' + text
    setter = function_source(body, '- (void)setPreferenceValue:')
    assert 'if ([key isEqualToString:VDT_NICE_VALUE_KEY])' in setter
    assert 'value = @(parsed);' in setter, 'value save must store only the value'
    assert 'setValueForProcessConfigKey' not in body, 'nice UI must not write CPU records'
    reader = function_source(body, '- (id)readPreferenceValue:')
    assert 'VDTNicePreferenceValueWithPrefs(self.identifier, self.configurationType,' in reader
    assert 'VDTNiceParseValue(value, &parsed) ? @(parsed) : @0' in reader
    assert 'applicationIdentifier' not in body


def owner_contract(source):
    guard = re.search(r'if \(\[self configurationType\] == VDTConfigTypeApp \|\| '
                      r'\[self configurationType\] == VDTConfigTypeDaemon \|\|\s*\n\s*'
                      r'\[self configurationType\] == VDTConfigTypeExtension\) \{', source)
    assert guard, 'nice editor guard must accept all three legal types'
    valid = function_source(source, OWNER_FUNCS[0])
    assert valid.count('default: return nil;') == 1, 'unknown type must resolve to no identifier'
    for text in ('case VDTConfigTypeApp:', 'case VDTConfigTypeDaemon:', 'case VDTConfigTypeExtension:'):
        assert text in valid
    reload = function_source(source, OWNER_FUNCS[6])
    assert 'valueForKey:@"_parentController"' in reload
    assert 'reloadSpecifiers' in reload, 'parent list must rebuild from fresh snapshot'
    resource = function_source(source, '- (void)setResourceRuleValue:')
    assert '[self vdtReloadIndependentRules];' in resource.split('} else {')[1]


def extension_list_contract(source):
    preview = function_source(source, '- (id)previewStringForSpecifier:')
    assert '[specifier propertyForKey:@"vdtListPrefsSnapshot"] ?: getPrefs()' in preview
    assert 'VDTListExtensionSubtitleKey(identifier, prefs)' in preview
    assert '"Follow containing app"' not in preview, 'no unconditional follow claim'


def shared_contract(source):
    getter = function_source(source, 'id valueForProcessConfigKeyWithPrefs')
    assert 'BOOL cpuField = [@[@"enabled", @"percentage", @"interval", @"violationPolicy"] containsObject:key];' in getter
    assert 'BOOL niceField = [@[@"niceEnabled", @"niceValue", @"niceRevision"] containsObject:key];' in getter
    assert 'if (type == VDTConfigTypeExtension &&' in getter, 'family skip is Extension-only'
    assert CPU_SKIP in getter, 'CPU lookups must skip nice-only extension rows'
    assert NICE_SKIP in getter, 'nice lookups must skip CPU-only extension rows'
    assert 'return config[key] ?: defaultValue;' in getter, 'first record with this family wins'
    assert getter.index(NICE_SKIP) < getter.index('id configuredIdentifier = config[identifierKey];')
    remove = function_source(source, 'void VDTRemoveProcessConfig')
    assert 'VDTConfigTypeExtension' in remove
    assert 'VDTRemoveExtensionCPUConfigReportingResult(identifier)' in remove, \
        'extension CPU Follow must use the CPU-fields-only removal path'
    assert 'memoryRules' not in remove and 'jetsamRules' not in remove, 'CPU Follow keeps resource rules'
    helper_anchor = 'VDTRemoveExtensionCPUConfigReportingResult(NSString *identifier)'
    if helper_anchor in source:  # defined: it may only clear the four CPU keys
        helper = function_source(source, helper_anchor)
        assert 'VDT_NICE_ENABLED_KEY' not in helper and 'niceValue' not in helper
        assert 'memoryRules' not in helper and 'jetsamRules' not in helper
        for field in ('@"enabled"', '@"percentage"', '@"interval"', '@"violationPolicy"'):
            assert field in helper
    has_cpu = function_source(source, 'BOOL VDTProcessConfigHasCPUFields')
    for field in ('@"enabled"', '@"percentage"', '@"interval"', '@"violationPolicy"'):
        assert field in has_cpu


def nice_shared_contract(source):
    rules = function_source(source, 'NSDictionary<NSString *, NSDictionary *> *VDTNiceRulesFromPrefs')
    assert 'if (type == VDTConfigTypeExtension && !niceFieldsPresent(entry)) continue;' in rules
    has = function_source(source, 'BOOL VDTNiceHasIndependentRule')
    assert 'niceFieldsPresent(entry)) return YES;' in has
    remove = function_source(source, 'BOOL VDTNiceRemoveIndependentRule')
    assert 'for (NSString *field in @[VDT_NICE_ENABLED_KEY, VDT_NICE_VALUE_KEY, VDT_NICE_REVISION_KEY])' in remove
    assert '[entry removeObjectForKey:field];' in remove
    assert 'if (entry.count > 1) [remaining addObject:entry];' in remove, 'CPU/unknown fields survive'
    save = function_source(source, 'BOOL VDTNiceSavePreference')
    assert 'entry[key] = isSwitch ? value : @(numeric);' in save
    assert 'if (isSwitch && [value boolValue] && !entry[VDT_NICE_VALUE_KEY]) entry[VDT_NICE_VALUE_KEY] = @0;' in save
    assert 'entry[VDT_NICE_ENABLED_KEY]' not in save, 'a value save must not enable the switch'
    status = function_source(source, 'NSDictionary *VDTNiceMatchingStatusWithHost')
    for field in ('@"present", @"inherited", @"sourceType", @"sourceIdentifier", @"sourceRevision"'):
        assert field in status, 'status must compare source-aware fields'


def native_source(list_text, nice_text, owner_text):
    """Everything compiled for native is verbatim production text."""
    pieces = [function_source(list_text, prefix) for prefix in LIST_FUNCS]
    body = nice_text[nice_text.index(NICE_MARKERS[2]) + len(NICE_MARKERS[2]):nice_text.rindex('@end')]
    return ('#import "PreferencesHost.h"\n'
            '#import "vedetteprefs/VDTListOrder.h"\n'
            '#import "VDTNiceShared.h"\n'
            '#import "VDTResourceShared.h"\n'
            '#import "vedetteprefs/VDTNicePreferences.h"\n'
            + '\n\n'.join(pieces) + '\n'
            + nice_text[nice_text.index(NICE_MARKERS[0]):nice_text.index(NICE_MARKERS[1])]
            + nice_text[nice_text.index(NICE_MARKERS[1]):nice_text.index(NICE_MARKERS[2])]
            + '@implementation VDTNicePreferences' + body + '@end\n'
            + '\n@implementation VDTProcessConfiguration\n'
            + '\n\n'.join(function_source(owner_text, prefix) for prefix in OWNER_FUNCS)
            + '\n@end\n')


MUTANTS = (
    dict(id='drop-nice-pin', file=LIST, old=FOUR_PINS,
         new='cpuEnabled || memoryEnabled || jetsamEnabled', tag='pin.nice-only.app', contract=list_contract),
    dict(id='drop-memory-pin', file=LIST, old=FOUR_PINS,
         new='cpuEnabled || niceEnabled || jetsamEnabled', tag='pin.memory-only.app', contract=list_contract),
    dict(id='drop-jetsam-pin', file=LIST, old=FOUR_PINS,
         new='cpuEnabled || niceEnabled || memoryEnabled', tag='pin.jetsam-only.app', contract=list_contract),
    dict(id='numeric-bool-accept', file=LIST,
         old='    return [value isKindOfClass:[NSNumber class]]\n'
             '        && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()\n'
             '        && CFBooleanGetValue((__bridge CFBooleanRef)value);',
         new='    return [value isKindOfClass:[NSNumber class]] && [value boolValue];',
         tag='pin.numeric-not.ext', contract=list_contract),
    dict(id='remove-extension-guard', file=NICE,
         old='- (void)removeIndependentNiceRule {\n    if (self.configurationType != VDTConfigTypeExtension) return;\n',
         new='- (void)removeIndependentNiceRule {\n', tag='follow.guard', contract=nice_contract),
    dict(id='nice-follow-deletes-cpu', file=NICE,
         old='BOOL saved = VDTNiceRemoveIndependentRule(self.identifier, self.configurationType, &error);',
         new=('VDTNiceRemoveIndependentRule(self.identifier, self.configurationType, &error);\n'
              '    VDTRemoveProcessConfig(self.identifier, self.configurationType);\n'
              '    BOOL saved = YES;'), tag='follow.fields', contract=nice_contract),
    dict(id='value-autoenable', file=NICE_SHARED,
         old='entry[key] = isSwitch ? value : @(numeric);',
         new='entry[key] = isSwitch ? value : @(numeric);\n    if (!isSwitch) entry[VDT_NICE_ENABLED_KEY] = @YES;',
         tag='nice.value-no-autoenable', contract=nice_shared_contract),
    dict(id='lost-parent-refresh', file=NICE,
         old=('    [self setPendingStatusAndReload];\n    [self updateInheritancePresentation];\n'
              '    [self updateProtectedSwitchAvailability];\n    [_owner reloadSpecifier:specifier animated:NO];\n'
              '    [_owner vdtReloadIndependentRules];'),
         new=('    [self setPendingStatusAndReload];\n    [self updateProtectedSwitchAvailability];\n'
              '    [_owner reloadSpecifier:specifier animated:NO];\n    [_owner vdtReloadIndependentRules];'),
         tag='nice.owner-reload', contract=nice_contract),
    dict(id='cpu-family-skip-gone', file=SHARED, old=CPU_SKIP, new='(cpuField && NO)',
         tag='mixed.cpu-second', contract=shared_contract),
    dict(id='nice-family-skip-gone', file=SHARED, old=NICE_SKIP, new='(niceField && NO)',
         tag='pin.cpu-off-nice', contract=shared_contract),
    dict(id='extension-rules-skip-gone', file=NICE_SHARED,
         old='if (type == VDTConfigTypeExtension && !niceFieldsPresent(entry)) continue;',
         new='if (type == VDTConfigTypeExtension && NO) continue;', count=2,
         tag='pin.host-inherit-rule', contract=nice_shared_contract),
)


class SourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {path: path.read_text() for path in
                       (LIST, NICE, OWNER, EXTLIST, SHARED, NICE_SHARED)}

    def test_list_pin_and_grouping_contract(self):
        list_contract(self.sources[LIST])

    def test_extension_list_reports_subtitle_not_follow(self):
        extension_list_contract(self.sources[EXTLIST])

    def test_nice_ui_contract(self):
        nice_contract(self.sources[NICE])

    def test_owner_guard_contract(self):
        owner_contract(self.sources[OWNER])

    def test_shared_family_skip_contract(self):
        shared_contract(self.sources[SHARED])

    def test_nice_shared_store_contract(self):
        nice_shared_contract(self.sources[NICE_SHARED])

    def test_extracted_units_are_verbatim_production(self):
        generated = native_source(self.sources[LIST], self.sources[NICE], self.sources[OWNER])
        for prefix in LIST_FUNCS:
            self.assertIn(function_source(self.sources[LIST], prefix), generated)
        for prefix in OWNER_FUNCS:
            self.assertIn(function_source(self.sources[OWNER], prefix), generated)
        nice = self.sources[NICE]
        for block in (nice[nice.index(NICE_MARKERS[0]):nice.index(NICE_MARKERS[1])],
                      nice[nice.index(NICE_MARKERS[1]):nice.index(NICE_MARKERS[2])],
                      nice[nice.index(NICE_MARKERS[2]):nice.rindex('@end')]):
            self.assertIn(block, generated)
        self.assertNotIn('UIKit', generated)

    def test_each_mutant_is_rejected_by_its_contract(self):
        for mutant in MUTANTS:
            source = self.sources[mutant['file']]
            count = mutant.get('count', 1)
            self.assertEqual(source.count(mutant['old']), count, 'mutation anchor: ' + mutant['id'])
            mutated = source.replace(mutant['old'], mutant['new'], count)
            self.assertNotEqual(mutated, source)
            with self.assertRaises(AssertionError, msg='survived: ' + mutant['id']):
                mutant['contract'](mutated)


def build_and_run(directory, label, list_text, nice_text, owner_text, shared_text, nice_shared_text):
    """One compile+run. Returns (ok, first_fail_tag, log)."""
    extracted = directory / (label + '-ui.m')
    extracted.write_text(native_source(list_text, nice_text, owner_text))
    shared_path = directory / (label + '-VDTShared.mm')
    shared_path.write_text(shared_text)
    nice_shared_path = directory / (label + '-VDTNiceShared.mm')
    nice_shared_path.write_text(nice_shared_text)
    common = ['-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
              '-I' + str(ROOT), '-I' + str(STUBS)]
    # The UI extraction carries production methods such as requestRetry: that
    # legitimately ignore a parameter, so -Werror applies only to store TUs.
    strict = common + ['-Werror']
    objects = []

    def compile_one(command, target):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            return (False, None, (result.stdout + result.stderr))
        objects.append(str(target))
        return None

    steps = (
        (['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-I' + str(ROOT),
          '-c', str(ROOT / 'VDTNiceStore.c'), '-o', str(directory / (label + '-store.o'))],
         directory / (label + '-store.o')),
        (['xcrun', 'clang', *common, '-x', 'objective-c', '-c', str(extracted),
          '-o', str(directory / (label + '-ui.o'))], directory / (label + '-ui.o')),
        (['xcrun', 'clang++', '-std=c++17', *strict, '-DCFNotificationCenterPostNotification=VDTTestPostNotification', '-c', str(shared_path),
          '-o', str(directory / (label + '-shared.o'))], directory / (label + '-shared.o')),
        (['xcrun', 'clang++', '-std=c++17', *strict, '-Dnotify_post=VDTTestNotifyPost', '-c',
          str(nice_shared_path), '-o', str(directory / (label + '-niceshared.o'))],
         directory / (label + '-niceshared.o')),
        (['xcrun', 'clang++', '-std=c++17', *strict, '-Dnotify_post=VDTTestNotifyPost',
          '-DCFNotificationCenterPostNotification=VDTTestPostNotification', '-c', str(ROOT / 'VDTResourceShared.mm'),
          '-o', str(directory / (label + '-resourceshared.o'))], directory / (label + '-resourceshared.o')),
        (['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
          '-Dnotify_post=VDTTestNotifyPost', '-DCFNotificationCenterPostNotification=VDTTestPostNotification', '-I' + str(ROOT), '-I' + str(STUBS), '-c',
          str(FIXTURE), '-o', str(directory / (label + '-fixture.o'))],
         directory / (label + '-fixture.o')),
    )
    for command, target in steps:
        failure = compile_one(command, target)
        if failure:
            return (False, None, 'compiler failed: ' + failure[2])
    link = subprocess.run(['xcrun', 'clang++', *objects, '-framework', 'Foundation',
                           '-o', str(directory / (label + '-run'))],
                          capture_output=True, text=True)
    if link.returncode != 0:
        return (False, None, 'linker failed: ' + link.stdout + link.stderr)
    run = subprocess.run([str(directory / (label + '-run'))], capture_output=True, text=True)
    tag = None
    for line in (run.stdout + run.stderr).splitlines():
        match = re.match(r'FIXTURE_FAIL:([\w.\-]+)', line)
        if match:
            tag = match.group(1)
            break
    return (run.returncode == 0, tag, (run.stdout + run.stderr))


def run_native():
    with tempfile.TemporaryDirectory(prefix='vdt-independent-rules-') as temporary:
        directory = Path(temporary)
        sources = {path: path.read_text() for path in (LIST, NICE, OWNER, SHARED, NICE_SHARED)}

        def build(label, list_text=None, nice_text=None, owner_text=None,
                  shared_text=None, nice_shared_text=None):
            return build_and_run(
                directory, label,
                list_text if list_text is not None else sources[LIST],
                nice_text if nice_text is not None else sources[NICE],
                owner_text if owner_text is not None else sources[OWNER],
                shared_text if shared_text is not None else sources[SHARED],
                nice_shared_text if nice_shared_text is not None else sources[NICE_SHARED])

        ok, tag, log = build('baseline')
        if not ok:
            print('NATIVE BASELINE FAILED (tag %s)\n%s' % (tag, log[-4000:]))
            return 1
        failures = []
        for mutant in MUTANTS:
            source = sources[mutant['file']]
            count = mutant.get('count', 1)
            if source.count(mutant['old']) != count:
                print('MUTANT %s: anchor drift, not a kill' % mutant['id'])
                failures.append(mutant['id'])
                continue
            mutated = source.replace(mutant['old'], mutant['new'], count)
            ok, tag, log = build_and_run(
                directory, 'mutant-' + mutant['id'],
                mutated if mutant['file'] == LIST else sources[LIST],
                mutated if mutant['file'] == NICE else sources[NICE],
                sources[OWNER],
                mutated if mutant['file'] == SHARED else sources[SHARED],
                mutated if mutant['file'] == NICE_SHARED else sources[NICE_SHARED])
            if tag is None:
                print('MUTANT %s: %s (first tag %s)' % (
                    mutant['id'], 'compile failure' if 'compiler failed' in log or 'linker failed' in log
                    else 'SURVIVED (exit %s)' % ok, tag))
                failures.append(mutant['id'])
            elif tag != mutant['tag']:
                print('MUTANT %s: failed at %s, expected %s' % (mutant['id'], tag, mutant['tag']))
                failures.append(mutant['id'])
            else:
                print('MUTANT %s: killed at %s' % (mutant['id'], tag))
        print('baseline ok; %d/%d mutants killed by the designated assert'
              % (len(MUTANTS) - len(failures), len(MUTANTS)))
        return 1 if failures else 0


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('--static-only', action='store_true')
    parser.add_argument('--require-native', action='store_true')
    args = parser.parse_args(argv)

    static = unittest.TextTestRunner(verbosity=1).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SourceContracts))
    if not static.wasSuccessful():
        return 1
    if args.static_only:
        if args.require_native:
            print('FAIL: static-only cannot satisfy require-native')
            return 1
        print('STATIC OK (source/mutation evidence only; not native execution)')
        return 0
    if platform.system() != 'Darwin':
        if args.require_native:
            print('NATIVE REQUIRED but not runnable on %s: failure, not a pass.' % platform.system())
            return 1
        print('SKIP: native fixture needs Darwin (xcrun/clang ObjC+Foundation); not a pass.')
        return 77
    return run_native()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
