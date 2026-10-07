//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTApplicationListSubcontrollerController.h"
#import "VDTListPresentation.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"

@implementation VDTApplicationListSubcontrollerController

- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return VDTCompactRowHeight(tableView);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous && ![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self.table reloadData];
    }
}


// Small local section spacing; optional delegates are implemented without super.
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return VDTCompactSectionHeight(self, section, NO);
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return VDTCompactSectionHeight(self, section, YES);
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return VDTCompactSectionView(self, tableView, section, NO);
}
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return VDTCompactSectionView(self, tableView, section, YES);
}


- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VDTLoc(self.class, @"Applications");
    self.definesPresentationContext = YES;
    self.view.tintColor = VDTAccentColor();
    VDTStyleTable(self.table);
    _searchController.searchBar.placeholder = VDTLoc(self.class, @"Search");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    VDTStyleCell(cell);
    return cell;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Rebuild ordering from disk after a detail change, without resetting the
    // search controller/query or enumerating installed apps again.
    [self reloadSpecifiers];
}

- (void)prepareForPopulatingSections {
    [super prepareForPopulatingSections];
    // AltList 9db09f9 indexes one flat alphabetic list, not enabled/other groups.
    self.alphabeticIndexingEnabled = NO;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    // Pinned AltList dispatches this through a concurrent queue. Keep UIKit
    // reads and the query/cache update on main to avoid stale query races.
    NSString *query = [searchController.searchBar.text copy] ?: @"";
    if ([_searchKey isEqualToString:query]) return;
    _searchKey = query;
    [self reloadSpecifiers];
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        // Super owns installation observers, icon loading, identity properties
        // and search filtering. Never mutate its unfiltered _allSpecifiers cache.
        NSArray *filtered = [super specifiers];
        _specifiers = VDTGroupedListSpecifiers(filtered, @"applicationIdentifier",
            VDTConfigTypeApp, self.class, nil,
            _searchKey.length ? @"No Results" : @"No Applications");
    }
    return _specifiers;
}

- (PSSpecifier *)createSpecifierForApplicationProxy:(LSApplicationProxy *)applicationProxy {
    PSSpecifier *specifier = [super createSpecifierForApplicationProxy:applicationProxy];
    [specifier setProperty:@(VDTConfigTypeApp) forKey:@"configurationType"];
    return specifier;
}

- (NSString *)previewStringForApplicationWithIdentifier:(NSString *)applicationID {
    return VDTListConfigurationEnabled(applicationID, VDTConfigTypeApp, nil)
        ? VDTLoc(self.class, @"Configuration enabled") : @"";
}
@end
