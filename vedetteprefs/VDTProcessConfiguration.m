//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessConfiguration.h"
#import "VDTApplicationListSubcontrollerController.h"
#import "../VDTShared.h"
#import "ChoicyPreferences/CHPDaemonListController.h"
#import "VDTLocalization.h"
#import "VDTStyle.h"
#import "VDTHeaderCell.h"

@implementation VDTProcessConfiguration

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VDTLoc(self.class, @"Process rule");
    self.view.tintColor = VDTAccentColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    VDTStyleTable(self.table);
}

- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if ([[specifier propertyForKey:@"vdtHeader"] boolValue])
        return UITableViewAutomaticDimension;
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
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


-(void)presentConsentPromptForProcess:(NSString *)process block:(void (^)())understoodBlock{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:VDTLoc(self.class, @"Essential process") message:[NSString stringWithFormat:VDTLoc(self.class, @"%@ is one of the essential processes for iOS to function properly, if it were to be throttled or terminated, your system might crash. Proceed?"), process] preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *yesAction = [UIAlertAction actionWithTitle:VDTLoc(self.class, @"I Understand") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        understoodBlock();
    }];
    
    UIAlertAction *noAction = [UIAlertAction actionWithTitle:VDTLoc(self.class, @"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
        [self reloadSpecifier:_enabledSpecifier animated:YES];
    }];
    
    [alert addAction:yesAction];
    [alert addAction:noAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

-(BOOL)shouldAskForConsent:(NSString *)process{
    NSArray *consensualProcess = @[
        @"xpcproxy",
        @"backboardd",
        @"SpringBoard",
        @"launchd",
        @"sshd"
    ];
    return [consensualProcess containsObject:process];
}

- (NSString*)validIdentifier{
    return  [self configurationType] == VDTConfigTypeApp ? [[self specifier] propertyForKey:@"applicationIdentifier"] : [[self specifier] propertyForKey:@"daemonName"];
}

-(VDTConfigType)configurationType{
    return [[[self specifier] propertyForKey:@"configurationType"] unsignedLongValue];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rootSpecifiers = [[NSMutableArray alloc] init];
        
        NSString *validIdentifier = [self validIdentifier];
        BOOL isPreferencesApp = [validIdentifier isEqualToString:@"com.apple.Preferences"];
        
        //Enabled
        PSSpecifier *monitorEnabledGroupSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Rule") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [monitorEnabledGroupSpec setProperty:VDTLoc(self.class, @"Enable this saved rule and pin it in the process list. The global switch and valid parameters are also required.") forKey:@"footerText"];
        [rootSpecifiers addObject:monitorEnabledGroupSpec];
        [rootSpecifiers addObject:VDTHeaderSpecifier(self.specifier.name ?: validIdentifier,
            validIdentifier, [self configurationType] == VDTConfigTypeApp ? @"app" : @"gearshape.2")];
    
        PSSpecifier *monitorEnabledSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Enable this rule") target:self set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:) detail:nil cell:PSSwitchCell edit:nil];
        [monitorEnabledSpec setProperty:VDTLoc(self.class, @"Enable this rule") forKey:@"label"];
        [monitorEnabledSpec setProperty:@"enabled" forKey:@"key"];
        [monitorEnabledSpec setProperty:@NO forKey:@"default"];
        [monitorEnabledSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [monitorEnabledSpec setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [monitorEnabledSpec setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        _enabledSpecifier = monitorEnabledSpec;
        [rootSpecifiers addObject:monitorEnabledSpec];
        
        
        //Violation Policy
        PSSpecifier *violationPolicyGroupSpec = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [violationPolicyGroupSpec setProperty:VDTLoc(self.class, @"Terminate ends the process when its CPU limit is exceeded. Throttle limits CPU time; setting it too low can cause timeouts.") forKey:@"footerText"];
        [rootSpecifiers addObject:violationPolicyGroupSpec];
        
        PSSpecifier *violationPolicySelectionSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Action") target:self set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:) detail:nil cell:PSSegmentCell edit:nil];
        [violationPolicySelectionSpec setValues:@[@(VDTViolationPolicyMonitorAndTerminate), @(VDTViolationPolicyThrottle)] titles:@[VDTLoc(self.class, @"Terminate"), VDTLoc(self.class, @"Throttle")]];
        [violationPolicySelectionSpec setProperty:@(VDTViolationPolicyMonitorAndTerminate) forKey:@"default"];
        [violationPolicySelectionSpec setProperty:@"violationPolicy" forKey:@"key"];
        [violationPolicySelectionSpec setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [violationPolicySelectionSpec setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [rootSpecifiers addObject:violationPolicySelectionSpec];
        
        //CPU Usage Percentage
        PSSpecifier *maxCPUUsageGroupSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Limits") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [maxCPUUsageGroupSpec setProperty:VDTLoc(self.class, @"Terminate: 1–100%. Throttle: 1–255%. The interval must be a positive number of seconds and is used only by Terminate. Invalid or empty values disable enforcement.") forKey:@"footerText"];
        [rootSpecifiers addObject:maxCPUUsageGroupSpec];
        
        PSTextFieldSpecifier* maxCPUUsageSpec = [PSTextFieldSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"CPU limit (%)") target:self set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:) detail:nil cell:PSEditTextCell edit:nil];
        [maxCPUUsageSpec setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [maxCPUUsageSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [maxCPUUsageSpec setPlaceholder:@"80"];
        [maxCPUUsageSpec setProperty:@"percentage" forKey:@"key"];
        [maxCPUUsageSpec setProperty:VDTLoc(self.class, @"CPU limit (%)") forKey:@"label"];
        [maxCPUUsageSpec setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [maxCPUUsageSpec setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [rootSpecifiers addObject:maxCPUUsageSpec];
        
        //Interval
        PSTextFieldSpecifier* intervalSpec = [PSTextFieldSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Interval (seconds)") target:self set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:) detail:nil cell:PSEditTextCell edit:nil];
        [intervalSpec setKeyboardType:UIKeyboardTypeNumberPad autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [intervalSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [intervalSpec setPlaceholder:@"120"];
        [intervalSpec setProperty:@"interval" forKey:@"key"];
        [intervalSpec setProperty:VDTLoc(self.class, @"Interval (seconds)") forKey:@"label"];
        [intervalSpec setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [intervalSpec setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        _intervalSpecifier = intervalSpec;
        [rootSpecifiers addObject:intervalSpec];
        
        _specifiers = rootSpecifiers;
    }
    
    return _specifiers;
}

- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier*)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    
    void (^setValueBlock)() = ^{
        setValueForProcessConfigKey([self validIdentifier], key, value, [self configurationType]);
        
        UIViewController *parentController = (UIViewController *)[self valueForKey:@"_parentController"];
        
        switch ([self configurationType]) {
            case VDTConfigTypeApp:{
                [(VDTApplicationListSubcontrollerController *)parentController reloadSpecifier:[(VDTApplicationListSubcontrollerController *)parentController specifierForApplicationWithIdentifier:[self validIdentifier]] animated:NO];
                break;
            }
            case VDTConfigTypeDaemon:{
                [(CHPDaemonListController *)parentController reloadValueOfSelectedSpecifier];
                break;
            }
            default:
                break;
        }
    };
    
    if ([key isEqualToString:@"enabled"]){
        if ([self shouldAskForConsent:[self validIdentifier]] && [value boolValue]){
            [self presentConsentPromptForProcess:[self validIdentifier] block:setValueBlock];
            return;
        }else{
            setValueBlock();
            return;
        }
    }else if ([key isEqualToString:@"violationPolicy"]){
        switch ([value unsignedLongValue]) {
            case VDTViolationPolicyMonitorAndTerminate:
                [_intervalSpecifier setProperty:@YES forKey:@"enabled"];
                break;
            case VDTViolationPolicyThrottle:
                [_intervalSpecifier setProperty:@NO forKey:@"enabled"];
                break;
            default:
                break;
        }
        [self reloadSpecifier:_intervalSpecifier animated:YES];
    }
    setValueBlock();
}

- (id)readProcessConfigValue:(PSSpecifier*)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    id value = valueForProcessConfigKey([self validIdentifier], key, [specifier propertyForKey:@"default"], [self configurationType]);
    if ([key isEqualToString:@"violationPolicy"]){
        switch ([value unsignedLongValue]) {
            case VDTViolationPolicyMonitorAndTerminate:
                [_intervalSpecifier setProperty:@YES forKey:@"enabled"];
                break;
            case VDTViolationPolicyThrottle:
                [_intervalSpecifier setProperty:@NO forKey:@"enabled"];
                break;
            default:
                break;
        }
        [self reloadSpecifier:_intervalSpecifier animated:YES];
    }
    return value;
}

@end
