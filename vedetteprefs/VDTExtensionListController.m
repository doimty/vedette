// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import "VDTExtensionListController.h"
#import "VDTProcessConfiguration.h"
#import "VDTListPresentation.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"
#import "VDTExtensionCatalog.h"

@interface VDTExtensionListController ()
@property (nonatomic, strong) UISearchController *extensionSearch;
@property (nonatomic, copy) NSString *extensionQuery;
@property (nonatomic) BOOL catalogVisible;
@property (nonatomic) BOOL catalogNeedsReload;
@end

@implementation VDTExtensionListController
- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }

- (void)viewDidLoad {
    [super viewDidLoad];
    [[VDTExtensionCatalog sharedInstance] addObserver:self];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:VDTLoc(self.class, @"Refresh") style:UIBarButtonItemStylePlain
        target:self action:@selector(refreshExtensionRecords)];
    self.title = VDTLoc(self.class, @"App extensions");
    self.definesPresentationContext = YES;
    self.view.tintColor = VDTAccentColor();
    VDTStyleTable(self.table);
    self.extensionSearch = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.extensionSearch.obscuresBackgroundDuringPresentation = NO;
    self.extensionSearch.searchResultsUpdater = self;
    self.extensionSearch.searchBar.placeholder = VDTLoc(self.class, @"Search");
    self.navigationItem.searchController = self.extensionSearch;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
}

- (void)dealloc {
    [[VDTExtensionCatalog sharedInstance] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    self.catalogVisible = NO;
    _specifiers = nil; // Only rule grouping/search is rebuilt from the warm snapshot.
    self.catalogNeedsReload = YES;
    [super viewWillAppear:animated];
    [[VDTExtensionCatalog sharedInstance] ensureLoaded];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.catalogVisible = YES;
    if (self.catalogNeedsReload) [self reloadSpecifiers];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.catalogVisible = NO;
    [super viewWillDisappear:animated];
}

- (void)reloadSpecifiers {
    self.catalogNeedsReload = YES;
    if (!self.catalogVisible) return;
    self.catalogNeedsReload = NO;
    [super reloadSpecifiers];
}

- (void)extensionCatalogDidUpdate:(VDTExtensionCatalog *)catalog {
    (void)catalog;
    NSAssert(NSThread.isMainThread, @"Main only");
    [self reloadSpecifiers];
}

- (void)refreshExtensionRecords {
    [[VDTExtensionCatalog sharedInstance] refresh];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray new];
        VDTExtensionCatalog *catalog = [VDTExtensionCatalog sharedInstance];
        if (!catalog.loaded) {
            PSSpecifier *status = [PSSpecifier emptyGroupSpecifier];
            [status setProperty:VDTLoc(self.class, catalog.failed ? @"Unable to load App extensions." : @"Loading…") forKey:@"footerText"];
            [rows addObject:status];
            if (catalog.failed) [rows addObject:[self catalogRetrySpecifier]];
            _specifiers = rows;
            return _specifiers;
        }
        for (NSDictionary *record in catalog.records) {
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:record[@"displayName"]
                target:self set:nil get:@selector(previewStringForSpecifier:)
                detail:VDTProcessConfiguration.class cell:PSLinkListCell edit:nil];
            [row setProperty:record[@"extensionIdentifier"] forKey:@"extensionIdentifier"];
            [row setProperty:record[@"containingAppName"] forKey:@"containingAppName"];
            [row setProperty:record[@"containingAppIdentifier"] forKey:@"containingAppIdentifier"];
            [row setProperty:record forKey:@"vdtExtensionMetadata"];
            [row setProperty:@(VDTConfigTypeExtension) forKey:@"configurationType"];
            [row setProperty:VDTSettingsSymbol(@"puzzlepiece.extension") forKey:@"iconImage"];
            [rows addObject:row];
        }
        NSString *query = self.extensionQuery ?: @"";
        _specifiers = VDTGroupedListSpecifiers(rows, @"extensionIdentifier", VDTConfigTypeExtension,
            self.class, ^BOOL(PSSpecifier *row) {
                return query.length == 0 || [row.name localizedStandardContainsString:query] ||
                    [[row propertyForKey:@"extensionIdentifier"] localizedStandardContainsString:query] ||
                    [[row propertyForKey:@"containingAppName"] localizedStandardContainsString:query];
            }, query.length ? @"No Results" : @"No App extensions");
        if (catalog.failed) {
            NSMutableArray *withFailure = [_specifiers mutableCopy];
            PSSpecifier *status = [PSSpecifier emptyGroupSpecifier];
            [status setProperty:VDTLoc(self.class, @"Refresh failed. Showing the previous list.") forKey:@"footerText"];
            [withFailure addObject:status];
            [withFailure addObject:[self catalogRetrySpecifier]];
            _specifiers = withFailure;
        }
    }
    return _specifiers;
}

- (PSSpecifier *)catalogRetrySpecifier {
    PSSpecifier *retry = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Retry")
        target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [retry setButtonAction:@selector(refreshExtensionRecords)];
    return retry;
}

- (id)previewStringForSpecifier:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"extensionIdentifier"];
    NSDictionary *prefs = [specifier propertyForKey:@"vdtListPrefsSnapshot"] ?: getPrefs();
    return VDTLoc(self.class, VDTListExtensionSubtitleKey(identifier, prefs));
}

- (void)reloadExtensionRule:(NSString *)identifier {
    (void)identifier;
    [self reloadSpecifiers];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text copy] ?: @"";
    if ([self.extensionQuery isEqualToString:query]) return;
    self.extensionQuery = query;
    [self reloadSpecifiers];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    VDTStyleCell(cell);
    return cell;
}
@end
