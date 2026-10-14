#!/usr/bin/env python3
"""Static mutations everywhere; real extracted UI + VDTShared Foundation on macOS.

Default: static checks then native (non-Darwin SKIP exit 77).
--static-only: explicitly source-level evidence, exit 0 on success.
--require-native: unsupported native is failure exit 1, never a passing skip.
No UIKit or system notifications: fake Preferences host, real plist storage.
"""
from pathlib import Path
import argparse
import platform
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DETAIL = ROOT / 'vedetteprefs/VDTProcessConfiguration.m'
SHARED = ROOT / 'VDTShared.mm'
BEGIN = '// BEGIN resource rule input validation'
END = '// END resource rule input validation.'
GET = 'readResourceRuleValue:'
SET = 'setResourceRuleValue:specifier:'
ROW_FIELDS = {
    'memoryEnabledSpec': ('memoryRules', 'enabled', 'PSSwitchCell'),
    'memoryActiveSpec': ('memoryRules', 'active', 'PSEditTextCell'),
    'memoryInactiveSpec': ('memoryRules', 'inactive', 'PSEditTextCell'),
    'jetsamEnabledSpec': ('jetsamRules', 'enabled', 'PSSwitchCell'),
    'jetsamBandSpec': ('jetsamRules', 'priority', 'PSEditTextCell'),
}
NICE_GUARD = '''        if ([self configurationType] == VDTConfigTypeApp || [self configurationType] == VDTConfigTypeDaemon ||
            [self configurationType] == VDTConfigTypeExtension) {
            [rootSpecifiers addObjectsFromArray:[[self vdtNicePreferences] specifiers]];
        }'''
ERROR_KEYS = (
    'Invalid resource rule',
    'Enter a whole number from -1 to 2147483647 for memory, or a signed 32-bit raw priority band. Switches require a Boolean value.',
    'Resource rule save failed',
    'The rule could not be saved. The previous saved value has been restored.',
)
METHOD_PREFIXES = (
    '- (NSString*)validIdentifier', '-(VDTConfigType)configurationType',
    '- (NSString *)vdtNiceIdentifier', '- (VDTConfigType)vdtNiceConfigurationType',
    '- (VDTNicePreferences *)vdtNicePreferences', '- (NSArray *)specifiers',
    '- (void)presentResourceRuleError:', '- (void)vdtReloadIndependentRules',
    '- (void)setResourceRuleValue:',
    '- (id)readResourceRuleValue:',
)


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


def parser_source(source):
    assert source.count(BEGIN) == source.count(END) == 1
    return source[source.index(BEGIN):source.index(END) + len(END)]


def detail_contract(source):
    assert not re.search(r'^(<<<<<<<|=======|>>>>>>>)', source, re.M), 'unresolved UI conflict'
    selectors = re.findall(r'set:@selector\((setResourceRuleValue[^)]*)\)\s+get:@selector\(([^)]*)\)', source)
    assert selectors == [(SET, GET)] * 5, 'five resource rows: setter 2 args, getter 1 arg'
    reader = function_source(source, '- (id)readResourceRuleValue:')
    assert reader.split('{', 1)[0].count(':') == 1, 'actual getter arity'
    setter = function_source(source, '- (void)setResourceRuleValue:')
    assert setter.split('{', 1)[0].count(':') == 2, 'actual setter arity'
    assert 'valueForProcessResourceRuleKey([self validIdentifier], key, [specifier propertyForKey:@"default"], [self configurationType], section);' in reader
    assert 'VDTResourceRuleFieldIsValid(key, section)' in reader
    for name, (section, key, cell) in ROW_FIELDS.items():
        declaration = re.search(r'\b' + name + r'\s*=\s*\[[^\n]+', source)
        assert declaration and 'cell:' + cell in declaration[0], name + ' cell type'
        for prop, value in (('key', key), ('vdtRuleSection', section)):
            assert f'[{name} setProperty:@"{value}" forKey:@"{prop}"];' in source
        assert not re.search(r'\[' + name + r' setProperty:.*forKey:@"PostNotification"', source), 'no automatic success notification'
        if key == 'enabled':
            assert f'[{name} setProperty:@NO forKey:@"default"];' in source
    assert 'NSNumber *parsed = VDTResourceRuleInput(value, key, section);' in setter
    assert 'setValueForProcessResourceRuleKey([self validIdentifier], key, parsed, [self configurationType], section);' in setter
    assert 'VDTResourceSavePriority([self validIdentifier], [self configurationType], parsed)' in setter
    assert 'setValueForProcessConfigKey(' not in setter, 'must not write CPU/nice records'
    invalid = function_source(setter, 'if (!parsed)')
    assert '[self reloadSpecifier:specifier animated:NO];' in invalid
    assert 'presentResourceRuleError:' in invalid and 'return;' in invalid
    save_pos = setter.index('BOOL saved =')
    reload_pos = setter.find('[self reloadSpecifier:specifier animated:NO];', save_pos)
    assert reload_pos >= 0, 'missing saved-value readback after storage result'
    failure_pos = setter.find('if (!saved)', save_pos)
    assert failure_pos >= 0, 'missing save-failure feedback branch'
    assert save_pos < reload_pos < failure_pos, 'save outcome always reread'
    failure = function_source(setter, 'if (!saved)')
    assert 'Resource rule save failed' in failure
    assert 'previous saved value' in failure
    assert 'Notification' not in re.sub(r'//[^\n]*', '', setter)
    helper = parser_source(source)
    for text in ('VDTResourceRuleFieldIsValid', 'VDTResourceRuleInteger', 'VDTResourceRuleInput',
                 'CFBooleanGetTypeID()', 'strchr("cCsSiIlLqQ", type[0])',
                 "character < '0' || character > '9'", 'index == text.length',
                 'digit > limit || magnitude > (limit - digit) / 10',
                 'parsed < minimum || parsed > INT32_MAX', 'return @((NSInteger)parsed);',
                 '[section isEqualToString:@"memoryRules"] ? -1 : INT32_MIN'):
        assert text in helper, 'missing strict parser contract: ' + text
    boolean = function_source(helper, 'if ([key isEqualToString:@"enabled"])')
    assert '!= CFBooleanGetTypeID()' in boolean, 'numeric 0/1 must not become switches'
    assert source.count(NICE_GUARD) == 1, 'only App/Daemon/Extension may instantiate nice editor'
    assert source.count('set:@selector(setProcessConfigValue:specifier:)') == 4
    assert source.count('get:@selector(readProcessConfigValue:)') == 4


def storage_contract(source):
    save = function_source(source, 'static BOOL VDTSavePrefsReportingResult')
    assert 'BOOL saved = [candidate writeToFile:PREFS_PATH atomically:YES];' in save
    assert 'if (!saved) return NO;' in save
    assert save.index('if (!saved) return NO;') < save.index('CFNotificationCenterPostNotification')
    setter = function_source(source, 'BOOL setValueForProcessResourceRuleKeyWithPrefs')
    assert 'return VDTSavePrefsReportingResult(newPrefs);' in setter
    assert 'config[@"schema"] = VDT_RESOURCE_RULE_SCHEMA_VERSION;' in setter


def native_source(source):
    """All behavior under test is copied verbatim from production, not reimplemented."""
    return ('#import "PreferencesHost.h"\n#import "VDTResourceShared.h"\n' + parser_source(source) +
            '\n@implementation VDTProcessConfiguration\n' +
            '\n\n'.join(function_source(source, prefix) for prefix in METHOD_PREFIXES) +
            '\n@end\n')


class SourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.detail = DETAIL.read_text()
        cls.shared = SHARED.read_text()

    def reject_detail_mutation(self, old, new, count=1, reason=None):
        assert self.detail.count(old) >= count
        mutated = self.detail.replace(old, new, count)
        self.assertNotEqual(mutated, self.detail)
        rejection = (self.assertRaisesRegex(AssertionError, reason) if reason
                     else self.assertRaises(AssertionError))
        with rejection:
            detail_contract(mutated)

    def test_correct_selectors_typed_setter_and_save_contract(self):
        detail_contract(self.detail)
        storage_contract(self.shared)

    def test_old_five_wrong_getters_rejected(self):
        self.reject_detail_mutation('get:@selector(readResourceRuleValue:)',
                                    'get:@selector(readResourceRuleValue:specifier:)', 5)

    def test_one_wrong_getter_also_rejected(self):
        self.reject_detail_mutation('get:@selector(readResourceRuleValue:)',
                                    'get:@selector(readResourceRuleValue:specifier:)')

    def test_wrong_setter_selector_rejected(self):
        self.reject_detail_mutation('set:@selector(setResourceRuleValue:specifier:)',
                                    'set:@selector(setResourceRuleValue:)')

    def test_actual_method_wrong_arity_rejected(self):
        self.reject_detail_mutation('- (id)readResourceRuleValue:(PSSpecifier*)specifier{',
                                    '- (id)readResourceRuleValue:(id)unused specifier:(PSSpecifier*)specifier{')

    def test_old_untyped_setter_rejected(self):
        self.reject_detail_mutation('NSNumber *parsed = VDTResourceRuleInput(value, key, section);',
                                    'id parsed = value;')

    def test_cpu_store_reroute_rejected(self):
        self.reject_detail_mutation('setValueForProcessResourceRuleKey([self validIdentifier], key, parsed, [self configurationType], section);',
                                    '(setValueForProcessConfigKey([self validIdentifier], key, parsed, [self configurationType]), YES);')

    def test_failed_save_without_readback_rejected(self):
        self.reject_detail_mutation('    [self reloadSpecifier:specifier animated:NO];\n    if (!saved)',
                                    '    if (!saved)', reason='missing saved-value readback after storage result')

    def test_failed_save_without_feedback_rejected(self):
        self.reject_detail_mutation(
            'if (!saved) {\n        [self presentResourceRuleError:VDTLoc(self.class, @"Resource rule save failed")',
            'if (saved) {', reason='missing save-failure feedback branch')

    def test_numeric_switch_coercion_rejected(self):
        self.reject_detail_mutation('!= CFBooleanGetTypeID()', '== CFBooleanGetTypeID()')

    def test_overflow_guard_removed_rejected(self):
        self.reject_detail_mutation('        if (digit > limit || magnitude > (limit - digit) / 10) return nil;\n', '')

    def test_unknown_type_nice_editor_rejected(self):
        self.reject_detail_mutation(NICE_GUARD,
                                    '        [rootSpecifiers addObjectsFromArray:[[self vdtNicePreferences] specifiers]];')

    def test_numeric_switch_default_rejected(self):
        self.reject_detail_mutation('[memoryEnabledSpec setProperty:@NO forKey:@"default"];',
                                    '[memoryEnabledSpec setProperty:@0 forKey:@"default"];')

    def test_automatic_row_notification_rejected(self):
        self.reject_detail_mutation('[rootSpecifiers addObject:memoryEnabledSpec];',
            '[memoryEnabledSpec setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];\n        [rootSpecifiers addObject:memoryEnabledSpec];')

    def test_storage_unconditional_notification_rejected(self):
        mutated = self.shared.replace('    if (!saved) return NO;\n', '', 1)
        self.assertNotEqual(mutated, self.shared)
        with self.assertRaises(AssertionError):
            storage_contract(mutated)

    def test_extracted_methods_are_verbatim_production(self):
        generated = native_source(self.detail)
        self.assertIn(parser_source(self.detail), generated)
        for prefix in METHOD_PREFIXES:
            self.assertIn(function_source(self.detail, prefix), generated)
        self.assertNotIn('UIKit', generated)

    def test_localization_parity_no_duplicates_and_new_feedback(self):
        import json
        values = []
        for language in ('en', 'zh-Hans'):
            strings = (ROOT / f'vedetteprefs/Resources/{language}.lproj/Localizable.strings').read_text()
            keys = set()
            for line in strings.splitlines():
                if not line.strip():
                    continue
                match = re.fullmatch(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");', line)
                self.assertIsNotNone(match, 'invalid strings line: ' + line)
                key, value = (json.loads(item) for item in match.groups())
                self.assertNotIn(key, keys, 'duplicate key: ' + key)
                self.assertTrue(value, 'empty localization: ' + key)
                keys.add(key)
            self.assertTrue(set(ERROR_KEYS) <= keys)
            values.append(keys)
        self.assertEqual(*values)


def run_native():
    source = DETAIL.read_text()
    with tempfile.TemporaryDirectory(prefix='vdt-resource-ui-native-') as temporary:
        directory = Path(temporary)

        def compile_fixture(label, detail):
            extracted = directory / (label + '.m')
            executable = directory / label
            extracted.write_text(native_source(detail))
            common = ['-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                      '-I' + str(ROOT), '-I' + str(ROOT / 'tests/resource_preferences_stubs'),
                      '-DCFNotificationCenterPostNotification=VDTTestPostNotification']
            objects = []
            # Match the production language per file: the real .m UI is
            # Objective-C, the shared store and fixture are Objective-C++.
            for index, (path, language) in enumerate([
                    (extracted, 'objective-c'), (SHARED, 'objective-c++'),
                    (ROOT / 'VDTResourceShared.mm', 'objective-c++'),
                    (ROOT / 'VDTNiceShared.mm', 'objective-c++'),
                    (ROOT / 'VDTNiceStore.c', 'c'),
                    (ROOT / 'tests/test_resource_preferences_native.mm', 'objective-c++')]):
                target = directory / (label + '-' + str(index) + '.o')
                compiler = 'clang' if language in ('objective-c', 'c') else 'clang++'
                standard = ['-std=c11'] if language == 'c' else ([] if language == 'objective-c' else ['-std=c++17'])
                flags = [flag for flag in common if language != 'c' or flag not in ('-fobjc-arc', '-fblocks')]
                subprocess.run(['xcrun', compiler, *standard, *flags, '-x', language,
                                '-c', str(path), '-o', str(target)], check=True)
                objects.append(str(target))
            subprocess.run(['xcrun', 'clang++', *objects, '-framework', 'Foundation',
                            '-o', str(executable)], check=True)
            return executable

        positive = compile_fixture('resource-ui', source)
        subprocess.run([str(positive)], check=True)
        # Original bug in actual generated rows, real getter remains single-arg.
        mutated = source.replace('get:@selector(readResourceRuleValue:)',
                                 'get:@selector(readResourceRuleValue:specifier:)')
        assert mutated != source
        negative = compile_fixture('old-wrong-getter', mutated)
        result = subprocess.run([str(negative)], capture_output=True, text=True)
        if result.returncode == 0:
            raise AssertionError('old getter mutation passed native host')
        assert 'NATIVE_MUTATION_REJECTED: getter selector/arity/response' in result.stderr, \
            'negative fixture failed before the actual selector gate: ' + result.stderr
        print('PASS: native old-getter mutation rejected by actual host selector/arity/response gate')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--static-only', action='store_true')
    mode.add_argument('--require-native', action='store_true')
    options = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SourceContracts)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        return 1
    print('PASS: source contracts and negative mutations (not UIKit / not native execution)', flush=True)
    if options.static_only:
        return 0
    if platform.system() != 'Darwin':
        print('SKIP: real Foundation execution requires macOS; Linux/iSH is source-only', flush=True)
        return 1 if options.require_native else 77
    run_native()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
