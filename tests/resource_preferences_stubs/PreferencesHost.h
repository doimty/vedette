#import <Foundation/Foundation.h>
#import "VDTShared.h"
#import "vedetteprefs/VDTLocalization.h"

// Test-only Preferences/UIKit-shaped API. No UIKit is linked or executed.
typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell, PSSwitchCell, PSLinkListCell, PSEditTextCell, PSButtonCell
};
typedef NS_ENUM(NSInteger, UIKeyboardType) {
    UIKeyboardTypeNumberPad, UIKeyboardTypeNumbersAndPunctuation
};
typedef NS_ENUM(NSInteger, UITextAutocapitalizationType) { UITextAutocapitalizationTypeNone };
typedef NS_ENUM(NSInteger, UITextAutocorrectionType) { UITextAutocorrectionTypeNo };
typedef NS_ENUM(NSInteger, UIAlertControllerStyle) { UIAlertControllerStyleAlert };
typedef NS_ENUM(NSInteger, UIAlertActionStyle) { UIAlertActionStyleDefault };

@interface PSSpecifier : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL getter;
@property(nonatomic) SEL setter;
@property(nonatomic) SEL buttonAction;
@property(nonatomic) PSCellType cellType;
@property(nonatomic, strong) NSMutableDictionary *properties;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target
    set:(SEL)setter get:(SEL)getter detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit;
+ (instancetype)emptyGroupSpecifier;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
- (void)setButtonAction:(SEL)action;
@end

@interface PSTextFieldSpecifier : PSSpecifier
- (void)setKeyboardType:(UIKeyboardType)type autoCaps:(UITextAutocapitalizationType)caps
    autoCorrection:(UITextAutocorrectionType)correction;
- (void)setPlaceholder:(NSString *)placeholder;
@end

@interface UIAlertAction : NSObject
@property(nonatomic, copy) NSString *title;
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style
    handler:(void (^)(UIAlertAction *))handler;
@end

@interface UIAlertController : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSMutableArray *actions;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message
    preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end

@interface PSListController : NSObject {
@protected
    NSArray *_specifiers;
}
@property(nonatomic, strong) PSSpecifier *specifier;
@property(nonatomic, strong) PSListController *parentController;
- (void)reloadSpecifiers;
@property(nonatomic, strong) id displayedValue;
@property(nonatomic, strong) UIAlertController *lastAlert;
@property(nonatomic) NSUInteger reloadCount;
@property(nonatomic) NSUInteger alertCount;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)presentViewController:(UIAlertController *)controller animated:(BOOL)animated
    completion:(void (^)(void))completion;
@end

@class VDTNicePreferences;
@interface VDTProcessConfiguration : PSListController {
    PSSpecifier *_intervalSpecifier;
    PSSpecifier *_enabledSpecifier;
    VDTNicePreferences *_nicePreferences;
}
- (NSString *)validIdentifier;
- (VDTConfigType)configurationType;
- (NSString *)vdtNiceIdentifier;
- (VDTConfigType)vdtNiceConfigurationType;
- (VDTNicePreferences *)vdtNicePreferences;
- (NSArray *)specifiers;
- (void)presentResourceRuleError:(NSString *)title message:(NSString *)message;
- (void)vdtReloadIndependentRules;
- (void)setResourceRuleValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readResourceRuleValue:(PSSpecifier *)specifier;
@end

@interface VDTProcessConfiguration (CheckDisplaySentinel)
- (NSArray *)vdtCheckResultSpecifiers;
- (void)vdtRefreshCheckResults;
@end

// Selector declarations for untouched CPU / inheritance rows. Those behaviors
// are NOT exercised here; their own released/extension gates remain required.
// The old getter is DECLARED only so its negative control compiles, never implemented.
@interface VDTProcessConfiguration (UnexecutedSelectors)
- (void)setProcessConfigValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readProcessConfigValue:(PSSpecifier *)specifier;
- (void)confirmFollowContainingApp;
- (void)vdtFollowMemoryApp;
- (void)vdtFollowJetsamApp;
- (id)readResourceRuleValue:(id)unused specifier:(PSSpecifier *)specifier;
@end

@interface VDTActionListController : NSObject
@end

// Sentinel nice provider: assert all three supported types retain insertion;
// unknown types never instantiate it. Nice storage/runtime are tested separately.
@interface VDTNicePreferences : NSObject
- (instancetype)initWithOwner:(VDTProcessConfiguration *)owner;
- (NSArray *)specifiers;
@end

static inline PSSpecifier *VDTHeaderSpecifier(NSString *name, NSString *identifier, NSString *symbol) {
    PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:name target:nil
        set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
    [header setProperty:identifier forKey:@"headerIdentifier"];
    [header setProperty:symbol forKey:@"symbol"];
    return header;
}
