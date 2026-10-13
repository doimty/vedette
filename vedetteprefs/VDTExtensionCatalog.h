// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import "VDTListCatalog.h"

@class VDTExtensionCatalog;
@protocol VDTExtensionCatalogObserver <NSObject>
- (void)extensionCatalogDidUpdate:(VDTExtensionCatalog *)catalog;
@end

/* Process-local metadata only. All API/state/observers are main-thread confined.
 * Records and their string values are immutable; no controller, proxy or PID is
 * retained in the snapshot. Settings restart still requires its first scan.
 */
@interface VDTExtensionCatalog : NSObject {
    VDTListCatalogState _state;
    NSHashTable *_observers;
    NSArray<NSDictionary<NSString *, NSString *> *> *_records;
}
@property (nonatomic, readonly) BOOL loaded;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL failed;
@property (nonatomic, readonly, copy) NSArray<NSDictionary<NSString *, NSString *> *> *records;
+ (instancetype)sharedInstance;
- (void)ensureLoaded;
- (void)refresh;
- (void)addObserver:(id<VDTExtensionCatalogObserver>)observer;
- (void)removeObserver:(id<VDTExtensionCatalogObserver>)observer;
@end
