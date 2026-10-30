// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "VDTExtensionCatalog.h"
#import "ChoicyPreferences/CHPDaemonList.h"

@interface VDTListPrefetch : NSObject
+ (void)vdtWarmCatalogsOnce;
@end

// One-shot warm-up for the two directory-backed lists. Scanning happens as soon
// as the Vedette preference bundle loads, so opening a list normally reuses the
// catalog instead of paying for the first filesystem scan on push.
// No timer, polling, retry, or repeated scan is created here.
@implementation VDTListPrefetch
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                [self vdtWarmCatalogsOnce];
            }];
        [self vdtWarmCatalogsOnce];
    });
}
+ (void)vdtWarmCatalogsOnce {
    static BOOL warmed = NO;
    if (warmed) return;
    warmed = YES;
    @try {
        [[VDTExtensionCatalog sharedInstance] ensureLoaded];
    } @catch (NSException *exception) {
        (void)exception;
    }
    @try {
        [[VDTDaemonList sharedInstance] updateDaemonListIfNeeded];
    } @catch (NSException *exception) {
        (void)exception;
    }
}
@end
