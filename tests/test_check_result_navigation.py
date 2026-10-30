#!/usr/bin/env python3
"""Saved-result Preferences navigation contracts, NOT UIKit/runtime validation.

Runs source checks and targeted source mutations on any Python host. It never
compiles, installs, posts a notification, or performs a device/kernel operation.
source_contracts() is reusable from the existing native-model gate.
"""
from pathlib import Path
import unittest

from test_resource_preferences_native import function_source

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'
FOOTER = 'Tap a result for details. These are the latest recorded checks, not live monitoring.'


def adapter_contracts(source):
    rows = function_source(source, '- (NSArray<PSSpecifier *> *)specifiers {')
    assert 'for (NSUInteger index = 0; index < 3; index++)' in rows, 'exactly three compact results'
    assert rows.count('VDTCheckResultSpecifier(@{})') == 1
    assert '_resultRows = [results copy];' in rows and 'if (!_specifiers)' in rows
    assert 'VDTLoc(self.class, @"Recent check results")' in rows
    assert '@"Last apply result"' not in source
    assert FOOTER in rows and 'forKey:@"footerText"' in rows
    assert rows.count('cell:PSButtonCell') == 1, 'only the existing nice retry button'
    assert '@selector(requestNiceRetry)' in rows
    reload = function_source(source, '- (void)reloadModels {')
    for required in (
        'NSDictionary *context = [self checkContext];',
        'VDTReadCheckResultModels(context, _nicePending,',
        'PSSpecifier *row = _resultRows[index];',
        '[row setName:model[@"title"]];',
        '[row setProperty:model forKey:@"vdtCheckModel"];',
        '[row setProperty:context forKey:@"vdtCheckContext"];',
        '[row setProperty:@(index) forKey:@"vdtCheckIndex"];',
        '[_owner reloadSpecifier:row animated:NO]',
    ):
        assert required in reload, 'stale result/link context: ' + required
    context = function_source(source, '- (NSDictionary *)checkContext {')
    for required in ('[_owner vdtNiceIdentifier]', '[_owner vdtNiceConfigurationType]',
                     '@"identifier": identifier', '@"type": @(type)',
                     '[self verifiedHostForIdentifier:identifier]', 'context[@"host"] = host;'):
        assert required in context, 'missing current identity: ' + required
    host = function_source(source, '- (NSString *)verifiedHostForIdentifier:')
    assert '[metadata[@"extensionIdentifier"] isEqual:identifier]' in host
    assert 'metadata[@"containingAppIdentifier"]' in host
    assert '_specifiers =' not in reload and 'reloadSpecifiers' not in reload
    refresh = function_source(source, '- (void)refreshDisplay {')
    assert '[self reloadModels];' in refresh and 'requestRetry' not in refresh
    assert 'requestRetry' not in reload
    retry = function_source(source, '- (void)requestNiceRetry {')
    assert '[[_owner vdtNicePreferences] requestRetry]' in retry


def cell_contracts(source):
    factory = function_source(source, 'PSSpecifier *VDTCheckResultSpecifier(')
    assert 'detail:VDTCheckDetailsController.class cell:PSLinkCell' in factory
    assert 'target:nil set:nil get:nil' in factory
    assert 'VDTCheckResultCell.class forKey:@"cellClass"' in factory
    assert 'PSStaticTextCell' not in factory
    assert 'self.selectionStyle = UITableViewCellSelectionStyleDefault;' in source
    assert 'self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;' in source
    assert 'UITableViewCellSelectionStyleNone' not in source
    assert source.count('[UILabel new]') == 2, 'primary rows contain title and compact status only'
    for forbidden in ('checkSummary', 'checkTime', 'checkScope', 'model[@"state"]',
                      'model[@"summary"]', 'model[@"diagnosticFields"]', 'model[@"coreFields"]'):
        assert forbidden not in source, 'expanded primary row: ' + forbidden
    update = function_source(source, '- (void)updateCheck:')
    for required in ('model[@"title"]', 'model[@"compactState"]', 'model[@"compactTone"]',
                     'self.isAccessibilityElement = YES;',
                     'self.accessibilityLabel = self.checkTitle.text;',
                     'self.accessibilityValue = self.checkState.text;',
                     'self.accessibilityHint = VDTLoc(self.class, @"Check details");',
                     'self.accessibilityTraits = UIAccessibilityTraitButton;'):
        assert required in update, 'missing accessible native link: ' + required
    for required in ('label.numberOfLines = 0;', 'label.adjustsFontForContentSizeCategory = YES;',
                     'preferredFontForTextStyle:UIFontTextStyleBody',
                     'UIContentSizeCategoryIsAccessibilityCategory', 'UILayoutConstraintAxisVertical',
                     'self.contentView.layoutMarginsGuide', 'margins.leadingAnchor', 'margins.trailingAnchor',
                     'effectiveUserInterfaceLayoutDirection', 'NSTextAlignmentNatural',
                     'systemLayoutSizeFittingSize:', 'self.contentView.bounds.size.width'):
        assert required in source, 'native sizing/RTL behavior missing: ' + required


def details_contracts(source):
    selected = function_source(source, '- (NSUInteger)selectedIndexForModels:')
    for required in ('propertyForKey:@"vdtCheckIndex"', 'isKindOfClass:NSNumber.class',
                     'index < 0', '(NSUInteger)index >= models.count',
                     '[value doubleValue] != (double)index', 'return NSNotFound;', 'return (NSUInteger)index;'):
        assert required in selected, 'unsafe selected index: ' + required
    assert 'return 0;' not in selected, 'invalid index must not open nice instead'
    rows = function_source(source, '- (NSArray *)specifiers {')
    assert 'NSUInteger index = [self selectedIndexForModels:models];' in rows
    assert 'index == NSNotFound ? nil : models[index]' in rows
    assert 'VDTCheckPresentationSections(model, [self showsDiagnostics])' in rows
    assert 'for (NSDictionary *field in section[@"fields"])' in rows
    assert 'first = 0' not in rows and 'models.count;' not in rows, 'details must not fan out to all mechanisms'
    assert 'VDTCheckSectionTitle(self.class, sectionID)' in rows and 'cell:PSGroupCell' in rows
    nav = function_source(source, '- (void)viewDidLoad {')
    assert 'UIBarButtonSystemItemRefresh' in nav and '@selector(refreshDisplay)' in nav
    assert 'refresh.accessibilityLabel = VDTLoc(self.class, @"Refresh display");' in nav
    assert 'VDTLoc(self.class, @"Edit")' in nav and '@selector(editSettings)' in nav
    assert 'edit.accessibilityLabel = VDTLoc(self.class, @"Edit settings");' in nav
    assert 'self.navigationItem.rightBarButtonItems = @[edit, refresh];' in nav
    edit = function_source(source, '- (void)editSettings {')
    assert '[self.navigationController popViewControllerAnimated:YES];' in edit
    assert 'if (![self showsDiagnostics] && index != NSNotFound)' in rows
    assert 'detail:VDTCheckDiagnosticsController.class cell:PSLinkCell' in rows
    assert '[_diagnosticsRow setProperty:[self checkContext] forKey:@"vdtCheckContext"];' in rows
    assert '[_diagnosticsRow setProperty:@(index) forKey:@"vdtCheckIndex"];' in rows
    assert '[row setProperty:field[@"id"] forKey:@"vdtCheckFieldID"];' in rows
    assert 'if (!_specifiers)' in rows and '_fieldRows = [fields copy]; _specifiers = [rows copy];' in rows
    assert 'Historical receipt, not live monitoring. Refresh only reloads saved results.' in rows
    load = function_source(source, '- (NSArray<NSDictionary *> *)loadModels {')
    assert 'VDTReadCheckResultModels(context, pending,' in load and '[self checkContext]' in load
    context = function_source(source, '- (NSDictionary *)checkContext {')
    assert '[self.specifier propertyForKey:@"vdtCheckContext"]' in context
    assert '[incoming mutableCopy]' in context and 'return [context copy];' in context
    assert 'if (_ignoresNicePending) context[@"nicePending"] = @NO;' in context
    assert '[self.specifier setProperty:' not in source, 'refresh must not mutate the root pending snapshot'
    refresh = function_source(source, '- (void)refreshDisplay {')
    assert refresh.index('_ignoresNicePending = YES;') < refresh.index('[self loadModels]')
    assert '[_diagnosticsRow setProperty:context forKey:@"vdtCheckContext"];' in refresh
    assert '[_diagnosticsRow setProperty:[self.specifier propertyForKey:@"vdtCheckIndex"] forKey:@"vdtCheckIndex"];' in refresh
    assert 'NSUInteger index = [self selectedIndexForModels:models];' in refresh
    assert 'index == NSNotFound ? nil : models[index]' in refresh
    for required in ('VDTCheckPresentationFields(model, [self showsDiagnostics])',
                     'for (PSSpecifier *row in _fieldRows)', 'propertyForKey:@"vdtCheckFieldID"',
                     '[field[@"id"] isEqual:identifier]', 'VDTLoc(self.class, @"Not recorded")',
                     '[row setProperty:updated forKey:@"vdtCheckField"]', '[self reloadSpecifier:row animated:NO]'):
        assert required in refresh, 'cached field refresh missing: ' + required
    for forbidden in ('_specifiers =', '_fieldRows =', 'VDTCheckFieldSpecifier(', 'reloadSpecifiers', 'reloadData', 'requestRetry'):
        assert forbidden not in refresh, 'refresh must preserve specifier objects and remain read-only: ' + forbidden
    assert 'return UITableViewAutomaticDimension;' in source
    assert 'return [super tableView:tableView heightForRowAtIndexPath:indexPath];' in source
    assert 'VDTStyleTable(self.table)' in source and 'VDTStyleCell(cell)' in source
    assert 'UIBarButtonSystemItemRefresh' in source and '@"Refresh display"' in source
    assert '[self refreshDisplay];' in function_source(source, '- (void)viewWillAppear:')


def read_only_contracts(adapter, cell, details):
    sources = adapter + cell + details
    for forbidden in ('notify_post(', 'memorystatus_control(', 'setpriority(', 'writeToFile:',
                      'CFNotificationCenterPostNotification', 'VDTResourceSetWriteEnabled',
                      'VDTResourceSave', 'setValueForProcess', '_specifiers = nil',
                      'scheduledTimer', 'NSTimer', 'dispatch_source_create', 'dispatch_after',
                      'NSURLSession'):
        assert forbidden not in sources, 'read-only navigation violated: ' + forbidden
    assert adapter.count('notify_register_dispatch(') == 1, 'keep only the existing saved-status observer'
    assert 'notify_cancel(_resourceToken)' in adapter and '__weak VDTCheckResultsPreferences' in adapter
    assert 'notify_register' not in cell + details, 'no new detail polling/observers'


def source_contracts():
    adapter = (PREFS / 'VDTCheckResultsPreferences.m').read_text(encoding='utf-8')
    cell = (PREFS / 'VDTCheckResultCell.m').read_text(encoding='utf-8')
    details = (PREFS / 'VDTCheckDetailsController.m').read_text(encoding='utf-8')
    adapter_contracts(adapter)
    cell_contracts(cell)
    details_contracts(details)
    read_only_contracts(adapter, cell, details)


class CheckResultNavigationContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adapter = (PREFS / 'VDTCheckResultsPreferences.m').read_text(encoding='utf-8')
        cls.cell = (PREFS / 'VDTCheckResultCell.m').read_text(encoding='utf-8')
        cls.details = (PREFS / 'VDTCheckDetailsController.m').read_text(encoding='utf-8')

    def test_production_navigation_contracts(self):
        source_contracts()

    def reject_mutation(self, source, old, new, contract):
        self.assertIn(old, source, 'mutation anchor missing')
        mutant = source.replace(old, new, 1)
        self.assertNotEqual(mutant, source)
        with self.assertRaises(AssertionError):
            contract(mutant)

    def test_four_primary_rows_are_rejected(self):
        self.reject_mutation(self.adapter, 'index < 3', 'index < 4', adapter_contracts)

    def test_stale_link_context_is_rejected(self):
        self.reject_mutation(self.adapter, '[row setProperty:context forKey:@"vdtCheckContext"];', '', adapter_contracts)

    def test_edit_entry_must_return_to_editor(self):
        self.reject_mutation(self.details, '[self.navigationController popViewControllerAnimated:YES];', '', details_contracts)

    def test_missing_selected_index_is_rejected(self):
        self.reject_mutation(self.adapter, '[row setProperty:@(index) forKey:@"vdtCheckIndex"];', '', adapter_contracts)

    def test_static_primary_rows_are_rejected(self):
        self.reject_mutation(self.cell, 'cell:PSLinkCell', 'cell:PSStaticTextCell', cell_contracts)

    def test_hidden_disclosure_is_rejected(self):
        self.reject_mutation(self.cell, 'UITableViewCellAccessoryDisclosureIndicator', 'UITableViewCellAccessoryNone', cell_contracts)

    def test_static_accessibility_trait_is_rejected(self):
        self.reject_mutation(self.cell, 'UIAccessibilityTraitButton', 'UIAccessibilityTraitStaticText', cell_contracts)

    def test_expanded_primary_row_is_rejected(self):
        self.reject_mutation(self.cell, 'self.checkTitle = [UILabel new];', 'self.checkTitle = [UILabel new]; [UILabel new];', cell_contracts)

    def test_unselected_core_details_are_rejected(self):
        self.reject_mutation(self.details, 'NSUInteger index = [self selectedIndexForModels:models];', 'NSUInteger index = 0;', details_contracts)

    def test_invalid_index_fallback_is_rejected(self):
        self.reject_mutation(self.details, 'return NSNotFound;', 'return 0;', details_contracts)

    def test_recursive_diagnostics_link_is_rejected(self):
        self.reject_mutation(self.details, 'if (![self showsDiagnostics] && index != NSNotFound)', 'if (index != NSNotFound)', details_contracts)

    def test_permanently_pending_details_are_rejected(self):
        self.reject_mutation(self.details, 'if (_ignoresNicePending) context[@"nicePending"] = @NO;', '', details_contracts)

    def test_stale_diagnostics_context_is_rejected(self):
        self.reject_mutation(self.details, '[_diagnosticsRow setProperty:context forKey:@"vdtCheckContext"];', '', details_contracts)

    def test_naked_specifier_reset_is_rejected(self):
        self.reject_mutation(self.details, '_ignoresNicePending = YES;', '_ignoresNicePending = YES; _specifiers = nil;', details_contracts)

    def test_missing_field_keeps_stale_evidence_is_rejected(self):
        self.reject_mutation(self.details, 'VDTLoc(self.class, @"Not recorded")', 'previous[@"value"]', details_contracts)

    def test_refresh_triggering_retry_is_rejected(self):
        self.reject_mutation(self.adapter, '_nicePending = NO;', '_nicePending = NO; [[_owner vdtNicePreferences] requestRetry];', adapter_contracts)

    def test_resource_write_is_rejected(self):
        self.reject_mutation(self.details, '_ignoresNicePending = YES;', '_ignoresNicePending = YES; VDTResourceSetWriteEnabled(YES);',
                             lambda source: read_only_contracts(self.adapter, self.cell, source))

    def test_new_detail_observer_is_rejected(self):
        self.reject_mutation(self.details, '_ignoresNicePending = YES;', '_ignoresNicePending = YES; notify_register_dispatch();',
                             lambda source: read_only_contracts(self.adapter, self.cell, source))


if __name__ == '__main__':
    unittest.main(verbosity=2)
