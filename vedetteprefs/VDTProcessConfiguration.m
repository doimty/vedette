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
#import "VDTActionListController.h"
#import "VDTNicePreferences.h"
#import "VDTExtensionListController.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <string.h>

// BEGIN resource rule input validation (also executed by the Foundation fixture).
static BOOL VDTResourceRuleFieldIsValid(id key, id section) {
    if (![key isKindOfClass:NSString.class] || ![section isKindOfClass:NSString.class]) return NO;
    BOOL memory = [section isEqualToString:@"memoryRules"];
    BOOL jetsam = [section isEqualToString:@"jetsamRules"];
    return ((memory || jetsam) && [key isEqualToString:@"enabled"])
        || (memory && ([key isEqualToString:@"active"] || [key isEqualToString:@"inactive"]))
        || (jetsam && [key isEqualToString:@"priority"]);
}

// Complete ASCII integer, with overflow checked BEFORE multiplication/addition.
// No trimming, intValue coercion, floating-point NSNumber, or Boolean-as-integer.
static NSNumber *VDTResourceRuleInteger(id value, int32_t minimum) {
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) {
        text = value;
    } else if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
        const char *type = [value objCType];
        if (!type || strlen(type) != 1 || !strchr("cCsSiIlLqQ", type[0])) return nil;
        text = [value stringValue];
    } else {
        return nil;
    }
    if (text.length == 0) return nil;
    NSUInteger index = 0;
    unichar first = [text characterAtIndex:0];
    BOOL negative = first == '-';
    if (negative || first == '+') index++;
    if (index == text.length) return nil;
    uint64_t magnitude = 0;
    uint64_t limit = negative ? (uint64_t)(-(int64_t)minimum) : (uint64_t)INT32_MAX;
    for (; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character < '0' || character > '9') return nil;
        uint64_t digit = character - '0';
        if (digit > limit || magnitude > (limit - digit) / 10) return nil;
        magnitude = magnitude * 10 + digit;
    }
    int64_t parsed = negative ? -(int64_t)magnitude : (int64_t)magnitude;
    if (parsed < minimum || parsed > INT32_MAX) return nil;
    return @((NSInteger)parsed);
}

static NSNumber *VDTResourceRuleInput(id value, id key, id section) {
    if (!VDTResourceRuleFieldIsValid(key, section)) return nil;
    if ([key isEqualToString:@"enabled"]) {
        if (![value isKindOfClass:NSNumber.class]
            || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return nil;
        return @([value boolValue]);
    }
    // Keep the advanced Jetsam raw int32 save domain. Version-specific band
    // validity remains in VDTJetsamPolicy; saving is NOT applying or remapping.
    int32_t minimum = [section isEqualToString:@"memoryRules"] ? -1 : INT32_MIN;
    return VDTResourceRuleInteger(value, minimum);
}
// END resource rule input validation.

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
    switch ([self configurationType]) {
        case VDTConfigTypeApp: return [[self specifier] propertyForKey:@"applicationIdentifier"];
        case VDTConfigTypeDaemon: return [[self specifier] propertyForKey:@"daemonName"];
        case VDTConfigTypeExtension: return [[self specifier] propertyForKey:@"extensionIdentifier"];
        default: return nil;
    }
}

-(VDTConfigType)configurationType{
    return [[[self specifier] propertyForKey:@"configurationType"] unsignedLongValue];
}

- (NSString *)vdtNiceIdentifier { return [self validIdentifier]; }
- (VDTConfigType)vdtNiceConfigurationType { return [self configurationType]; }

- (VDTNicePreferences *)vdtNicePreferences {
    if (!_nicePreferences) _nicePreferences = [[VDTNicePreferences alloc] initWithOwner:self];
    return _nicePreferences;
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
            validIdentifier, [self configurationType] == VDTConfigTypeExtension ? @"puzzlepiece.extension" :
                ([self configurationType] == VDTConfigTypeApp ? @"app" : @"gearshape.2"))];
    
        PSSpecifier *monitorEnabledSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Enable CPU limits") target:self set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:) detail:nil cell:PSSwitchCell edit:nil];
        [monitorEnabledSpec setProperty:VDTLoc(self.class, @"Enable CPU limits") forKey:@"label"];
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

        PSSpecifier *violationPolicySelectionSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Action") target:self set:@selector(setProcessConfigValue:specifier:) get:@selector(readProcessConfigValue:) detail:[VDTActionListController class] cell:PSLinkListCell edit:nil];
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

        // Keep the nice controls independent from the legacy CPU rule editor.
        if ([self configurationType] == VDTConfigTypeApp || [self configurationType] == VDTConfigTypeDaemon ||
            [self configurationType] == VDTConfigTypeExtension) {
            [rootSpecifiers addObjectsFromArray:[[self vdtNicePreferences] specifiers]];
        }
        if ([self configurationType] == VDTConfigTypeExtension) {
            PSSpecifier *inheritanceGroup = [PSSpecifier emptyGroupSpecifier];
            [inheritanceGroup setProperty:VDTLoc(self.class,
                @"Without its own CPU fields, this extension follows its app's CPU rule. Saving CPU settings creates a CPU override; a disabled CPU override removes Vedette CPU limits. Nice and resource rules stay independent.") forKey:@"footerText"];
            [rootSpecifiers addObject:inheritanceGroup];
            PSSpecifier *inheritance = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Follow containing app CPU")
                target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            [inheritance setButtonAction:@selector(confirmFollowContainingApp)];
            [rootSpecifiers addObject:inheritance];
        }

        //Memory rule
        PSSpecifier *memoryGroupSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Memory") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [memoryGroupSpec setProperty:VDTLoc(self.class, @"Saved memory rules and applied state stay separate: this build only saves. 0 = system default, -1 = unlimited, a positive number = MiB.") forKey:@"footerText"];
        [rootSpecifiers addObject:memoryGroupSpec];

        PSSpecifier *memoryEnabledSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Enable memory rule") target:self set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:) detail:nil cell:PSSwitchCell edit:nil];
        [memoryEnabledSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [memoryEnabledSpec setProperty:@NO forKey:@"default"];
        [memoryEnabledSpec setProperty:@"enabled" forKey:@"key"];
        [memoryEnabledSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];
        [rootSpecifiers addObject:memoryEnabledSpec];

        PSTextFieldSpecifier* memoryActiveSpec = [PSTextFieldSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Active limit (MiB)") target:self set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:) detail:nil cell:PSEditTextCell edit:nil];
        [memoryActiveSpec setKeyboardType:UIKeyboardTypeNumbersAndPunctuation autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [memoryActiveSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [memoryActiveSpec setPlaceholder:@"0"];
        [memoryActiveSpec setProperty:@"active" forKey:@"key"];
        [memoryActiveSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];
        [memoryActiveSpec setProperty:VDTLoc(self.class, @"Active limit (MiB)") forKey:@"label"];
        [rootSpecifiers addObject:memoryActiveSpec];

        PSTextFieldSpecifier* memoryInactiveSpec = [PSTextFieldSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Inactive limit (MiB)") target:self set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:) detail:nil cell:PSEditTextCell edit:nil];
        [memoryInactiveSpec setKeyboardType:UIKeyboardTypeNumbersAndPunctuation autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [memoryInactiveSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [memoryInactiveSpec setPlaceholder:@"0"];
        [memoryInactiveSpec setProperty:@"inactive" forKey:@"key"];
        [memoryInactiveSpec setProperty:@"memoryRules" forKey:@"vdtRuleSection"];
        [memoryInactiveSpec setProperty:VDTLoc(self.class, @"Inactive limit (MiB)") forKey:@"label"];
        [rootSpecifiers addObject:memoryInactiveSpec];

        //Reclaim priority rule
        PSSpecifier *jetsamGroupSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Reclaim priority") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [jetsamGroupSpec setProperty:VDTLoc(self.class, @"Saved reclaim-priority rules and applied state stay separate: this build only saves. Bands are device-version specific; 0 = idle, -1 writes the default band.") forKey:@"footerText"];
        [rootSpecifiers addObject:jetsamGroupSpec];

        PSSpecifier *jetsamEnabledSpec = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Enable reclaim priority rule") target:self set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:) detail:nil cell:PSSwitchCell edit:nil];
        [jetsamEnabledSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [jetsamEnabledSpec setProperty:@NO forKey:@"default"];
        [jetsamEnabledSpec setProperty:@"enabled" forKey:@"key"];
        [jetsamEnabledSpec setProperty:@"jetsamRules" forKey:@"vdtRuleSection"];
        [rootSpecifiers addObject:jetsamEnabledSpec];

        PSTextFieldSpecifier* jetsamBandSpec = [PSTextFieldSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Priority band") target:self set:@selector(setResourceRuleValue:specifier:) get:@selector(readResourceRuleValue:) detail:nil cell:PSEditTextCell edit:nil];
        [jetsamBandSpec setKeyboardType:UIKeyboardTypeNumbersAndPunctuation autoCaps:UITextAutocapitalizationTypeNone autoCorrection:UITextAutocorrectionTypeNo];
        [jetsamBandSpec setProperty:(isPreferencesApp?@NO:@YES) forKey:@"enabled"];
        [jetsamBandSpec setPlaceholder:@"16"];
        [jetsamBandSpec setProperty:@"priority" forKey:@"key"];
        [jetsamBandSpec setProperty:@"jetsamRules" forKey:@"vdtRuleSection"];
        [jetsamBandSpec setProperty:VDTLoc(self.class, @"Priority band") forKey:@"label"];
        [rootSpecifiers addObject:jetsamBandSpec];

        _specifiers = rootSpecifiers;
    }
    
    return _specifiers;
}

- (void)confirmFollowContainingApp {
    if ([self configurationType] != VDTConfigTypeExtension) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:VDTLoc(self.class, @"Follow containing app CPU")
        message:VDTLoc(self.class, @"Remove only this extension's CPU settings and follow its app? Nice, memory and Jetsam rules will be kept.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"Follow containing app CPU")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            VDTProcessConfiguration *owner = weakSelf;
            if (!owner) return;
            BOOL saved = VDTRemoveExtensionCPUConfigReportingResult([owner validIdentifier]);
            if (!saved) {
                [owner reloadSpecifiers];
                [owner presentResourceRuleError:VDTLoc(owner.class, @"CPU rule save failed")
                    message:VDTLoc(owner.class, @"The rule could not be saved. The previous saved value has been restored.")];
                return;
            }
            UIViewController *parent = (UIViewController *)[owner valueForKey:@"_parentController"];
            if ([parent isKindOfClass:VDTExtensionListController.class])
                [(VDTExtensionListController *)parent reloadExtensionRule:[owner validIdentifier]];
            [owner reloadSpecifiers];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentResourceRuleError:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VDTLoc(self.class, @"OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)vdtReloadIndependentRules {
    // Every list rebuilds from a fresh saved snapshot; do not reuse a selected
    // index path after a switch moves the row between enabled/other groups.
    id parent = [self valueForKey:@"_parentController"];
    if ([parent respondsToSelector:@selector(reloadSpecifiers)])
        [(PSListController *)parent reloadSpecifiers];
}

- (void)setResourceRuleValue:(id)value specifier:(PSSpecifier*)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *section = [specifier propertyForKey:@"vdtRuleSection"];
    NSNumber *parsed = VDTResourceRuleInput(value, key, section);
    if (!parsed) {
        [self reloadSpecifier:specifier animated:NO];
        [self presentResourceRuleError:VDTLoc(self.class, @"Invalid resource rule")
            message:VDTLoc(self.class, @"Enter a whole number from -1 to 2147483647 for memory, or a signed 32-bit raw priority band. Switches require a Boolean value.")];
        return;
    }
    BOOL saved = setValueForProcessResourceRuleKey([self validIdentifier], key, parsed, [self configurationType], section);
    // Reload through the getter even on failure; never leave an optimistic edit
    // displayed, post our own notification, or claim the saved rule was applied.
    [self reloadSpecifier:specifier animated:NO];
    if (!saved) {
        [self presentResourceRuleError:VDTLoc(self.class, @"Resource rule save failed")
            message:VDTLoc(self.class, @"The rule could not be saved. The previous saved value has been restored.")];
    } else {
        [self vdtReloadIndependentRules];
    }
}

- (id)readResourceRuleValue:(PSSpecifier*)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *section = [specifier propertyForKey:@"vdtRuleSection"];
    if (!VDTResourceRuleFieldIsValid(key, section)) return [specifier propertyForKey:@"default"];
    return valueForProcessResourceRuleKey([self validIdentifier], key, [specifier propertyForKey:@"default"], [self configurationType], section);
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
            case VDTConfigTypeExtension:{
                if ([parentController isKindOfClass:VDTExtensionListController.class])
                    [(VDTExtensionListController *)parentController reloadExtensionRule:[self validIdentifier]];
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
