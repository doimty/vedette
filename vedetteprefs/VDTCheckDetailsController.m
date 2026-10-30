// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckDetailsController.h"
#import "VDTCheckFieldCell.h"
#import "VDTCheckResultReader.h"
#import "VDTCheckPresentation.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"

static NSString *VDTCheckSectionTitle(Class owner, NSString *identifier) {
    NSDictionary *keys = @{@"result": @"Check result", @"check": @"Check summary",
        @"history": @"Check history", @"identity": @"Evidence and process",
        @"execution": @"Execution and readback", @"coverage": @"Coverage and diagnostics"};
    return VDTLoc(owner, keys[identifier] ?: @"Check details");
}

@interface VDTCheckDetailsController () {
    NSArray<PSSpecifier *> *_fieldRows;
    BOOL _ignoresNicePending;
}
- (BOOL)showsDiagnostics;
- (void)editSettings;
- (void)refreshDisplay;
@end
@implementation VDTCheckDetailsController
- (BOOL)showsDiagnostics { return NO; }
- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }
- (NSDictionary *)checkContext {
    id incoming = [self.specifier propertyForKey:@"vdtCheckContext"];
    if (![incoming isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *context = [incoming mutableCopy];
    // Pending belongs to the primary view's transient retry display, not to a
    // saved receipt. Do not mutate the presenting link's cached context.
    if (_ignoresNicePending) context[@"nicePending"] = @NO;
    return [context copy];
}
- (NSArray<NSDictionary *> *)loadModels {
    NSDictionary *context = [self checkContext];
    BOOL pending = [context[@"nicePending"] boolValue];
    return VDTReadCheckResultModels(context, pending,
        ^NSString *(NSString *key) { return VDTLoc(self.class, key); });
}
- (NSUInteger)selectedIndexForModels:(NSArray *)models {
    id value = [self.specifier propertyForKey:@"vdtCheckIndex"];
    if (![value isKindOfClass:NSNumber.class]) return NSNotFound;
    NSInteger index = [value integerValue];
    if (index < 0 || (NSUInteger)index >= models.count || [value doubleValue] != (double)index) return NSNotFound;
    return (NSUInteger)index; // An invalid link never falls back to another mechanism.
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.specifier.name.length ? self.specifier.name : VDTLoc(self.class, @"Check details");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.tintColor = VDTAccentColor();
    VDTStyleTable(self.table);
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(refreshDisplay)];
    refresh.accessibilityLabel = VDTLoc(self.class, @"Refresh display");
    UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithTitle:VDTLoc(self.class, @"Edit")
        style:UIBarButtonItemStylePlain target:self action:@selector(editSettings)];
    edit.accessibilityLabel = VDTLoc(self.class, @"Edit settings");
    self.navigationItem.rightBarButtonItems = @[edit, refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDisplay]; // Re-read saved files, never replace live specifier objects.
}
- (void)updateTitleForModel:(NSDictionary *)model {
    NSString *title = [model[@"title"] isKindOfClass:NSString.class] ? model[@"title"] : nil;
    if (!title.length) title = VDTLoc(self.class, @"Check details");
    self.title = title;
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *models = [self loadModels];
        NSUInteger index = [self selectedIndexForModels:models];
        NSDictionary *model = index == NSNotFound ? nil : models[index];
        NSMutableArray *rows = [NSMutableArray array], *fields = [NSMutableArray array];
        for (NSDictionary *section in VDTCheckPresentationSections(model, NO)) {
            NSString *sectionID = section[@"id"];
            PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:VDTCheckSectionTitle(self.class, sectionID)
                target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            if ([sectionID isEqual:@"result"])
                [header setProperty:VDTLoc(self.class, @"Historical receipt, not live monitoring. Refresh only reloads saved results.") forKey:@"footerText"];
            [rows addObject:header];
            for (NSDictionary *field in section[@"fields"]) {
                PSSpecifier *row = VDTCheckFieldSpecifier(field);
                [row setProperty:@(index) forKey:@"vdtCheckIndex"];
                [row setProperty:field[@"id"] forKey:@"vdtCheckFieldID"];
                [fields addObject:row]; [rows addObject:row];
            }
        }
        _fieldRows = [fields copy]; _specifiers = [rows copy];
        [self updateTitleForModel:model];
    }
    return _specifiers;
}
- (void)editSettings {
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)refreshDisplay {
    // Read saved files only. Clearing this local presentation flag neither
    // requests a retry nor changes the primary view's current pending state.
    _ignoresNicePending = YES;
    NSArray *models = [self loadModels];
    if (!_specifiers) return;
    NSUInteger index = [self selectedIndexForModels:models];
    NSDictionary *model = index == NSNotFound ? nil : models[index];
    [self updateTitleForModel:model];
    NSArray *visibleFields = VDTCheckPresentationFields(model, NO);
    for (PSSpecifier *row in _fieldRows) {
        NSString *identifier = [row propertyForKey:@"vdtCheckFieldID"];
        NSDictionary *previous = [row propertyForKey:@"vdtCheckField"];
        NSDictionary *updated = @{@"id": identifier ?: @"", @"label": previous[@"label"] ?: @"",
            @"value": VDTLoc(self.class, @"Not recorded"), @"tone": @"plain"};
        for (NSDictionary *field in visibleFields) {
            if (![field[@"id"] isEqual:identifier]) continue;
            updated = field;
            break;
        }
        // Preserve every cached specifier. If a field is absent, replace its
        // value with unknown rather than retaining stale evidence on screen.
        [row setProperty:updated forKey:@"vdtCheckField"];
        if (self.isViewLoaded) [self reloadSpecifier:row animated:NO];
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
