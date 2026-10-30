#!/usr/bin/env python3
"""Field layout production C + read-only UIKit wiring; NOT UIKit/device tests."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import test_pid_snapshot as compiler

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'


def cell_contracts(source):
    for token in ('self.contentView.layoutMarginsGuide', 'directionalLayoutMargins',
                  'VDTCheckFieldNeedsVertical(available, labelWidth, valueWidth, iconWidth, hasLineBreak,',
                  'UIContentSizeCategoryIsAccessibilityCategory', 'UILayoutConstraintAxisVertical',
                  'UILayoutConstraintAxisHorizontal', 'self.fieldValue.textAlignment = vertical ? NSTextAlignmentNatural',
                  'effectiveUserInterfaceLayoutDirection', 'label.numberOfLines = 0;',
                  'label.adjustsFontForContentSizeCategory = YES;',
                  'monospacedSystemFontOfSize:14', 'NSLineBreakByCharWrapping',
                  'self.accessibilityLabel = self.fieldLabel.text;', 'self.accessibilityValue = self.fieldValue.text;',
                  'self.stateIcon.hidden = !self.stateIcon.image;', 'iconWidth.priority = 999;',
                  'if ([self.fieldIdentifier isEqual:@"state"] && [tone isEqual:@"warning"])',
                  'symbol = @"exclamationmark.triangle.fill";',
                  'self.stateIcon.image = nil;', 'self.stateIcon.hidden = YES;', '[super prepareForReuse];'):
        assert token in source, 'missing field presentation contract: '+token
    assert 'checkmark.circle.fill' not in source, 'scope-limited results must not gain a success icon'
    assert 'numberOfLines = 1' not in source and 'adjustsFontSizeToFitWidth = YES' not in source
    for forbidden in ('notify_post(', 'memorystatus_control(', 'writeToFile:', 'setpriority(', 'NSTimer'):
        assert forbidden not in source


def result_contracts(source):
    for token in ('[tone isEqual:@"warning"] ? @"exclamationmark.triangle.fill" : nil',
                  'self.statusIcon.hidden = !self.statusIcon.image;', 'iconWidth.priority = 999;',
                  '@[self.statusSpacer, self.statusIcon, self.checkState]', 'self.statusSpacer.hidden = large;',
                  'self.statusIcon.image = nil; self.statusIcon.hidden = YES;',
                  'self.accessibilityLabel = self.checkTitle.text;', 'self.accessibilityValue = self.checkState.text;'):
        assert token in source, 'missing result presentation contract: '+token
    assert 'checkmark.circle.fill' not in source, 'identified-only checks are not an all-process success claim'


class CheckFieldWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cell = (PREFS/'VDTCheckFieldCell.m').read_text(encoding='utf-8')
        cls.result = (PREFS/'VDTCheckResultCell.m').read_text(encoding='utf-8')

    def test_production_wiring(self):
        cell_contracts(self.cell)
        result_contracts(self.result)

    def test_unknown_must_not_gain_success_icon(self):
        mutated = self.result.replace('[tone isEqual:@"warning"] ? @"exclamationmark.triangle.fill" : nil',
                                      'YES ? @"checkmark.circle.fill" : nil', 1)
        self.assertNotEqual(mutated, self.result)
        with self.assertRaises(AssertionError): result_contracts(mutated)

    def test_historical_field_must_not_gain_success_icon(self):
        mutated = self.cell.replace('symbol = @"exclamationmark.triangle.fill";',
                                    'symbol = @"checkmark.circle.fill";', 1)
        self.assertNotEqual(mutated, self.cell)
        with self.assertRaises(AssertionError): cell_contracts(mutated)

    def test_reuse_must_clear_icon(self):
        mutated = self.cell.replace('self.stateIcon.image = nil;', '', 1)
        self.assertNotEqual(mutated, self.cell)
        with self.assertRaises(AssertionError): cell_contracts(mutated)

    def test_dynamic_type_must_be_respected(self):
        mutated = self.cell.replace('UIContentSizeCategoryIsAccessibilityCategory', 'NO /* removed */', 1)
        self.assertNotEqual(mutated, self.cell)
        with self.assertRaises(AssertionError): cell_contracts(mutated)

    def test_status_icon_hidden_width_constraint_must_yield(self):
        mutated = self.cell.replace('iconWidth.priority = 999;', 'iconWidth.priority = 1000;', 1)
        self.assertNotEqual(mutated, self.cell)
        with self.assertRaises(AssertionError): cell_contracts(mutated)


class CheckFieldLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cc = compiler.compiler_command('CC', ('cc', 'clang', 'gcc'))
        if cls.cc is None:
            if compiler.REQUIRE_COMPILER:
                raise AssertionError('C compiler required but unavailable')
            raise unittest.SkipTest('C compiler unavailable; layout not executed')
        cls.header = (PREFS/'VDTCheckFieldLayout.h').read_text(encoding='utf-8')
        cls.fixture = (ROOT/'tests/test_check_field_layout.c').read_bytes()

    def execute(self, header, baseline):
        with tempfile.TemporaryDirectory(prefix='vdt-field-layout-') as tmp:
            directory = Path(tmp)
            (directory/'VDTCheckFieldLayout.h').write_text(header, encoding='utf-8')
            (directory/'test.c').write_bytes(self.fixture)
            output = directory/('field.exe' if os.name == 'nt' else 'field')
            result = subprocess.run(self.cc + compiler.FLAGS + ['-I', str(directory), str(directory/'test.c'), '-o', str(output)],
                                    cwd=directory, capture_output=True, text=True, errors='replace', timeout=120)
            self.assertEqual(result.returncode, 0, 'COMPILE FAILURE, not a mutant kill:\n'+result.stderr)
            result = subprocess.run([str(output)], cwd=directory, capture_output=True, text=True, errors='replace', timeout=30)
            if baseline:
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('PASS field layout', result.stdout)
            else:
                self.assertNotEqual(result.returncode, 0, 'layout mutant survived')
                self.assertIn('assert', result.stderr.lower(), result.stderr)

    def test_actual_layout(self):
        self.execute(self.header, True)

    def test_compiled_layout_mutants(self):
        changes = [
            ('ignore-newline', 'accessibilitySize || containsNewline ||', 'accessibilitySize || (containsNewline && available < 0) ||'),
            ('ignore-large-type', 'accessibilitySize || containsNewline ||', '(accessibilitySize && available < 0) || containsNewline ||'),
            ('ignore-icon', 'label + value + icon + 12 > available', 'label + value + 0 * icon + 12 > available'),
            ('always-horizontal', 'label + value + icon + 12 > available', 'label + value + icon + 12 > available * 10000'),
        ]
        for name, old, new in changes:
            with self.subTest(mutant=name):
                self.assertEqual(self.header.count(old), 1)
                self.execute(self.header.replace(old,new,1), False)
                print('KILLED compiled field-layout mutant:', name, flush=True)


if __name__ == '__main__': unittest.main(verbosity=2)
