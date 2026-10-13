#pragma once
// Test-only Preferences/UIKit-shaped API for the independent-rules native
// fixture. Nothing here is a production implementation: only presentation
// host behavior (specifier objects, reload receipts, alert capture) is faked.
// Storage, policy, effective rules and the UI under test are real production.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#import "VDTShared.h"
#import "vedetteprefs/VDTLocalization.h"

typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell, PSSwitchCell, PSLinkListCell, PSEditTextCell, PSButtonCell
};
typedef NS_ENUM(NSInteger, UIKeyboardType) {
    UIKeyboardTypeNumberPad, UIKeyboardTypeNumbersAndPunctuation
};
typedef NS_ENUM(NSInteger, UITextAutocapitalizationType) { UITextAutocapitalizationTypeNone };
typedef NS_ENUM(NSInteger, UITextAutocorrectionType) { UITextAutocorrectionTypeNo };
typedef NS_ENUM(NSInteger, UIAlertControllerStyle) { UIAlertControllerStyleAlert };
typedef NS_ENUM(NSInteger, UIAlertActionStyle) {
    UIAlertActionStyleDefault, UIAlertActionStyleCancel, UIAlertActionStyleDestructive
};

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
@property(nonatomic, copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style
    handler:(void (^)(UIAlertAction *))handler;
@end

@interface UIAlertController : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSMutableArray<UIAlertAction *> *actions;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message
    preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end

@interface PSListController : NSObject {
@protected
    NSArray *_specifiers;
    id _parentController;
}
@property(nonatomic, strong) PSSpecifier *specifier;
@property(nonatomic, strong) id displayedValue;
@property(nonatomic, strong) UIAlertController *lastAlert;
@property(nonatomic, strong) NSMutableArray<PSSpecifier *> *reloadLog;
@property(nonatomic) NSUInteger reloadCount;
@property(nonatomic) NSUInteger alertCount;
@property(nonatomic) NSUInteger reloadSpecifiersCount;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)reloadSpecifiers;
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
- (void)vdtReloadIndependentRules;
@end

@interface VDTActionListController : NSObject
@end

@interface VDTNiceValueListController : NSObject
@end

static inline PSSpecifier *VDTHeaderSpecifier(NSString *name, NSString *identifier, NSString *symbol) {
    PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:name target:nil
        set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
    [header setProperty:identifier forKey:@"headerIdentifier"];
    [header setProperty:symbol forKey:@"symbol"];
    return header;
}
