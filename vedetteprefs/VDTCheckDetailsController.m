// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckDetailsController.h"
#import "VDTCheckFieldCell.h"
#import "VDTCheckResultReader.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"

@interface VDTCheckDetailsController () {
    NSArray<PSSpecifier *> *_fieldRows;
}
- (BOOL)showsDiagnostics;
- (void)refreshDisplay;
@end
@implementation VDTCheckDetailsController
- (BOOL)showsDiagnostics { return NO; }
- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }
- (NSArray<NSDictionary *> *)loadModels {
    NSDictionary *context = [self.specifier propertyForKey:@"vdtCheckContext"];
    BOOL pending = [context[@"nicePending"] boolValue];
    return VDTReadCheckResultModels(context, pending,
        ^NSString *(NSString *key) { return VDTLoc(self.class, key); });
}
- (NSString *)fieldCollection { return [self showsDiagnostics] ? @"diagnosticFields" : @"coreFields"; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VDTLoc(self.class, [self showsDiagnostics] ? @"Diagnostic details" : @"Check details");
    self.view.tintColor = VDTAccentColor();
    VDTStyleTable(self.table);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:VDTLoc(self.class, @"Refresh display")
        style:UIBarButtonItemStylePlain target:self action:@selector(refreshDisplay)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDisplay]; // Re-read saved files, never replace live specifier objects.
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *models = [self loadModels];
        NSMutableArray *rows = [NSMutableArray array], *fields = [NSMutableArray array];
        NSUInteger first = [self showsDiagnostics] ? [[self.specifier propertyForKey:@"vdtCheckIndex"] unsignedIntegerValue] : 0;
        if (first >= models.count) first = 0;
        NSUInteger end = [self showsDiagnostics] ? first + 1 : models.count;
        for (NSUInteger index = first; index < end; index++) {
            NSDictionary *model = models[index];
            PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:model[@"title"]
                target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            if (index + 1 == end)
                [group setProperty:VDTLoc(self.class, @"Historical receipt, not live monitoring. Refresh only reloads saved results.") forKey:@"footerText"];
            [rows addObject:group];
            for (NSDictionary *field in model[[self fieldCollection]]) {
                PSSpecifier *row = VDTCheckFieldSpecifier(field);
                [row setProperty:@(index) forKey:@"vdtCheckIndex"];
                [row setProperty:field[@"id"] forKey:@"vdtCheckFieldID"];
                [fields addObject:row]; [rows addObject:row];
            }
            if (![self showsDiagnostics]) {
                PSSpecifier *diagnostics = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Diagnostic details")
                    target:nil set:nil get:nil detail:VDTCheckDiagnosticsController.class cell:PSLinkCell edit:nil];
                [diagnostics setProperty:[self.specifier propertyForKey:@"vdtCheckContext"] forKey:@"vdtCheckContext"];
                [diagnostics setProperty:@(index) forKey:@"vdtCheckIndex"];
                [rows addObject:diagnostics];
            }
        }
        _fieldRows = [fields copy]; _specifiers = [rows copy];
    }
    return _specifiers;
}
- (void)refreshDisplay {
    if (!_specifiers || !_fieldRows.count) return;
    NSArray *models = [self loadModels];
    for (PSSpecifier *row in _fieldRows) {
        NSUInteger index = [[row propertyForKey:@"vdtCheckIndex"] unsignedIntegerValue];
        if (index >= models.count) continue;
        NSString *identifier = [row propertyForKey:@"vdtCheckFieldID"];
        for (NSDictionary *field in models[index][[self fieldCollection]]) {
            if (![field[@"id"] isEqual:identifier]) continue;
            [row setProperty:field forKey:@"vdtCheckField"];
            if (self.isViewLoaded) [self reloadSpecifier:row animated:NO];
            break;
        }
    }
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([[[self specifierAtIndexPath:indexPath] propertyForKey:@"vdtCheckFieldRow"] boolValue]) return UITableViewAutomaticDimension;
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    VDTStyleCell(cell); return cell;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous && ![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory])
        [self.table reloadData];
}
@end
@implementation VDTCheckDiagnosticsController
- (BOOL)showsDiagnostics { return YES; }
@end
