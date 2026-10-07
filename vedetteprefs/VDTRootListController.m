//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTRootListController.h"
#import "../VDTShared.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"
#import "VDTHeaderCell.h"
#import "VDTAboutListController.h"

@implementation VDTRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rootSpecifiers = [[NSMutableArray alloc] init];
        
        //Tweak
        PSSpecifier *tweakEnabledGroupSpec = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        //[tweakEnabledGroupSpec setProperty:@"Changing this requires a respring using the dedicated \"Apply\" button." forKey:@"footerText"];
        [tweakEnabledGroupSpec setProperty:VDTLoc(self.class, @"Only individually enabled rules are applied. Turning this off keeps your saved rules.") forKey:@"footerText"];
        [rootSpecifiers addObject:tweakEnabledGroupSpec];
        [rootSpecifiers addObject:VDTHeaderSpecifier(@"Vedette",
            VDTLoc(self.class, @"Simple, selective CPU control for apps and daemons."), @"vedette")];
        
        PSSpecifier *tweakEnabledSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Enable Vedette") target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [tweakEnabledSpec setProperty:VDTLoc(self.class, @"Enable Vedette") forKey:@"label"];
        [tweakEnabledSpec setProperty:@"enabled" forKey:@"key"];
        [tweakEnabledSpec setProperty:@YES forKey:@"default"];
        [tweakEnabledSpec setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [tweakEnabledSpec setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [rootSpecifiers addObject:tweakEnabledSpec];
        
        
        [tweakEnabledSpec setProperty:VDTSettingsSymbol(@"power") forKey:@"iconImage"];

        //Manage
        PSSpecifier *manageGroupSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Process rules") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [manageGroupSpec setProperty:VDTLoc(self.class, @"Enabled rules are pinned first. Status reflects your saved configuration, not live CPU activity.") forKey:@"footerText"];
        [rootSpecifiers addObject:manageGroupSpec];
        
        //Apps
        PSSpecifier *altListSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Applications") target:nil set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:NSClassFromString(@"VDTApplicationListSubcontrollerController") cell:PSLinkListCell edit:nil];
        [altListSpec setProperty:@"VDTProcessConfiguration" forKey:@"subcontrollerClass"];
        [altListSpec setProperty:VDTLoc(self.class, @"Applications") forKey:@"label"];
        [altListSpec setProperty:@[
            @{@"sectionType":@"All"},
        ] forKey:@"sections"];
        [altListSpec setProperty:@YES forKey:@"useSearchBar"];
        [altListSpec setProperty:@YES forKey:@"hideSearchBarWhileScrolling"];
        [altListSpec setProperty:@NO forKey:@"alphabeticIndexingEnabled"];
        [altListSpec setProperty:@NO forKey:@"showIdentifiersAsSubtitle"];
        [altListSpec setProperty:@(VDTConfigTypeApp) forKey:@"configurationType"];
        [altListSpec setProperty:VDTSettingsSymbol(@"square.grid.2x2") forKey:@"iconImage"];
        [rootSpecifiers addObject:altListSpec];

        //Daemons
        PSSpecifier *daemonListSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Daemons") target:nil set:nil get:nil detail:NSClassFromString(@"CHPDaemonListController") cell:PSLinkCell edit:nil];
        [daemonListSpec setProperty:VDTSettingsSymbol(@"gearshape.2") forKey:@"iconImage"];
        [rootSpecifiers addObject:daemonListSpec];
        
        //reset
        PSSpecifier *resetGroupSpec = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [resetGroupSpec setProperty:VDTLoc(self.class, @"Remove saved rules and request restoration of system CPU limits.") forKey:@"footerText"];
        [rootSpecifiers addObject:resetGroupSpec];
        
        PSSpecifier *resetSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Reset settings") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [resetSpec setProperty:VDTLoc(self.class, @"Reset settings") forKey:@"label"];
        [resetSpec setButtonAction:@selector(reset)];
        [resetSpec setProperty:VDTSettingsSymbol(@"arrow.counterclockwise") forKey:@"iconImage"];
        [rootSpecifiers addObject:resetSpec];
        
        PSSpecifier *aboutGroup = [PSSpecifier emptyGroupSpecifier];
        [aboutGroup setProperty:VDTLoc(self.class, @"Built on Vedette by udevs. Interface by doimty.") forKey:@"footerText"];
        [rootSpecifiers addObject:aboutGroup];
        PSSpecifier *about = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"About Vedette")
            target:nil set:nil get:nil detail:VDTAboutListController.class cell:PSLinkCell edit:nil];
        [about setProperty:VDTSettingsSymbol(@"info.circle") forKey:@"iconImage"];
        [rootSpecifiers addObject:about];

        _specifiers = rootSpecifiers;
    }
    
    return _specifiers;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vedette";
    self.view.tintColor = VDTAccentColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    VDTStyleTable(self.table);
    self.respringBtn = [[UIBarButtonItem alloc] initWithTitle:VDTLoc(self.class, @"Respring")
        style:UIBarButtonItemStylePlain target:self action:@selector(confirmRespring)];
    self.navigationItem.rightBarButtonItem = self.respringBtn;
}

- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }

// This controller supplies its own caption views; do not also populate
// UITableViewHeaderFooterView's built-in labels through inherited titles.
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil;
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


- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if ([[specifier propertyForKey:@"vdtHeader"] boolValue])
        return UITableViewAutomaticDimension;
    return VDTCompactRowHeight(tableView);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous && ![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self.table reloadData];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // PSListController may omit optional willDisplayCell on iOS 15.
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    VDTStyleCell(cell);
    return cell;
}

- (void)confirmRespring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:VDTLoc(self.class, @"Respring")
        message:VDTLoc(self.class, @"Restart the system interface? This is not required for ordinary rule changes.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"Respring") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self _reallyRespring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

-(void)_reallyRespring{
    NSURL *relaunchURL = [NSURL URLWithString:@"prefs:root=Vedette"];
    SBSRelaunchAction *restartAction = [NSClassFromString(@"SBSRelaunchAction") actionWithReason:@"RestartRenderServer" options:4 targetURL:relaunchURL];
    [[NSClassFromString(@"FBSSystemService") sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
}

- (id)readPreferenceValue:(PSSpecifier*)specifier {
    return valueForKey(specifier.properties[@"key"]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {
    setValueForKey(specifier.properties[@"key"], value);
}

-(void)reset{
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vedette" message:VDTLoc(self.class, @"Remove all saved rules and request restoration of system defaults?") preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *yesAction = [UIAlertAction actionWithTitle:VDTLoc(self.class, @"Reset settings") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];

        [[NSFileManager defaultManager] copyItemAtPath:PREFS_PATH toPath:PREFS_PATH_TMP error:&error];
        
        void (^errorAlert)(NSError *) = ^(NSError *err){
            UIAlertController *alertFailed = [UIAlertController alertControllerWithTitle:@"Vedette" message:[NSString stringWithFormat:VDTLoc(self.class, @"Failed to reset. %@"), err.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *okAction = [UIAlertAction actionWithTitle:VDTLoc(self.class, @"OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            }];
            [alertFailed addAction:okAction];
            
            [self presentViewController:alertFailed animated:YES completion:nil];
        };
        
        if (error){
            errorAlert(error);
            return;
        }
        
        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH error:&error];
        
        if (error){
            errorAlert(error);
            return;
        }else{
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (CFStringRef)PREFS_CHANGED_NN, NULL, NULL, YES);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (CFStringRef)RESTORE_ALL_MONITORS_NN, NULL, NULL, YES);
            [self reloadSpecifiers];
        }
    }];
    
    UIAlertAction *noAction = [UIAlertAction actionWithTitle:VDTLoc(self.class, @"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    }];
    
    [alert addAction:yesAction];
    [alert addAction:noAction];
    
    [self presentViewController:alert animated:YES completion:nil];
    
    
    
}
@end
