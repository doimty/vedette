// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import "VDTExtensionListController.h"
#import "VDTProcessConfiguration.h"
#import "VDTListPresentation.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"
#import "../PrivateHeaders.h"
#import "../VDTBundleIdentity.h"

@interface VDTExtensionListController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *extensionRecords;
@property (nonatomic, strong) UISearchController *extensionSearch;
@property (nonatomic, copy) NSString *extensionQuery;
@property (nonatomic) NSUInteger enumerationGeneration;
@property (nonatomic) BOOL enumerating;
@end

// Read-only one-level PlugIns enumeration, never a recursive filesystem scan.
static NSArray<NSDictionary *> *extension_records(void) {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return @[];
    LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
    if (![workspace respondsToSelector:@selector(allApplications)]) return @[];
    id rawApplications = [workspace allApplications];
    if (![rawApplications isKindOfClass:[NSArray class]]) return @[];
    NSMutableDictionary<NSString *, NSDictionary *> *byIdentifier = [NSMutableDictionary new];
    for (LSApplicationProxy *proxy in rawApplications) {
        @autoreleasepool {
            if (![proxy respondsToSelector:@selector(bundleURL)]) continue;
            NSURL *appURL = proxy.bundleURL;
            if (![appURL isKindOfClass:[NSURL class]] || !appURL.isFileURL ||
                [appURL.path.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) continue;
            NSString *pluginsPath = [appURL.path stringByAppendingPathComponent:@"PlugIns"];
            NSArray *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath error:nil];
            for (NSString *child in [children sortedArrayUsingSelector:@selector(compare:)]) {
                if ([child.pathExtension caseInsensitiveCompare:@"appex"] != NSOrderedSame) continue;
                NSString *path = [pluginsPath stringByAppendingPathComponent:child];
                NSDictionary *info = VDTReadExtensionBundleInfo(path, nil);
                NSString *identifier = info[@"extensionIdentifier"];
                if (!identifier || byIdentifier[identifier]) continue;
                NSMutableDictionary *record = [info mutableCopy];
                NSString *appName = appURL.path.lastPathComponent.stringByDeletingPathExtension;
                record[@"containingAppName"] = appName ?: @"";
                if ([proxy respondsToSelector:@selector(bundleIdentifier)] &&
                    [proxy.bundleIdentifier isKindOfClass:[NSString class]]) {
                    record[@"containingAppIdentifier"] = proxy.bundleIdentifier;
                }
                byIdentifier[identifier] = [record copy];
            }
        }
    }
    // Fixed order before localized list sorting also makes duplicate handling stable.
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *identifier in [[byIdentifier allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [result addObject:byIdentifier[identifier]];
    return [result copy];
}

@implementation VDTExtensionListController
- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }

- (void)viewDidLoad {
    [super viewDidLoad];
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
    [self refreshExtensionRecords];
}

- (void)refreshExtensionRecords {
    if (self.enumerating) return;
    self.enumerating = YES;
    NSUInteger generation = ++self.enumerationGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSArray *records = extension_records();
            dispatch_async(dispatch_get_main_queue(), ^{
                VDTExtensionListController *owner = weakSelf;
                if (!owner || generation != owner.enumerationGeneration) return;
                owner.enumerating = NO;
                owner.extensionRecords = records;
                [owner reloadSpecifiers];
            });
        }
    });
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray new];
        if (!self.extensionRecords) {
            PSSpecifier *loading = [PSSpecifier emptyGroupSpecifier];
            [loading setProperty:VDTLoc(self.class, @"Loading…") forKey:@"footerText"];
            [rows addObject:loading];
            _specifiers = rows;
            return _specifiers;
        }
        for (NSDictionary *record in self.extensionRecords) {
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
    }
    return _specifiers;
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
