// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#import "VDTExtensionCatalog.h"
#import "../PrivateHeaders.h"
#import "../VDTBundleIdentity.h"

// Match AltList 9db09f9's workspace observer selectors, not its instance cache.
@interface LSApplicationWorkspace (VDTCatalogObservation)
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
@end

// Read-only one-level PlugIns enumeration; never a recursive filesystem scan.
// nil means failure, @[] is a successfully enumerated empty catalog.
static NSArray *VDTScanExtensions(void) {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return nil;
    LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
    if (![workspace respondsToSelector:@selector(allApplications)]) return nil;
    id applications = [workspace allApplications];
    if (![applications isKindOfClass:[NSArray class]]) return nil;
    NSMutableDictionary *byIdentifier = [NSMutableDictionary new];
    for (LSApplicationProxy *proxy in applications) {
        @autoreleasepool {
            if (![proxy respondsToSelector:@selector(bundleURL)]) continue;
            NSURL *appURL = proxy.bundleURL;
            if (![appURL isKindOfClass:[NSURL class]] || !appURL.isFileURL ||
                [appURL.path.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) continue;
            NSString *pluginsPath = [appURL.path stringByAppendingPathComponent:@"PlugIns"];
            NSError *error = nil;
            NSArray *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath error:&error];
            if (!children) {
                // Applications without PlugIns are normal; other IO errors are not empty success.
                if ([error.domain isEqualToString:NSCocoaErrorDomain] &&
                    (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) continue;
                return nil;
            }
            for (NSString *child in [children sortedArrayUsingSelector:@selector(compare:)]) {
                if ([child.pathExtension caseInsensitiveCompare:@"appex"] != NSOrderedSame) continue;
                NSString *path = [pluginsPath stringByAppendingPathComponent:child];
                NSString *plist = [path stringByAppendingPathComponent:@"Info.plist"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:plist] &&
                    ![[NSFileManager defaultManager] isReadableFileAtPath:plist]) return nil;
                NSDictionary *info = VDTReadExtensionBundleInfo(path, nil);
                NSString *identifier = info[@"extensionIdentifier"];
                if (!identifier || byIdentifier[identifier]) continue;
                NSMutableDictionary *record = [NSMutableDictionary new];
                // Freeze strings too; never keep LS proxies or mutable plist values.
                for (NSString *key in info) {
                    id value = info[key];
                    if ([value isKindOfClass:NSString.class]) record[[key copy]] = [value copy];
                }
                record[@"containingAppName"] = [appURL.path.lastPathComponent.stringByDeletingPathExtension copy] ?: @"";
                if ([proxy respondsToSelector:@selector(bundleIdentifier)] &&
                    [proxy.bundleIdentifier isKindOfClass:NSString.class])
                    record[@"containingAppIdentifier"] = [proxy.bundleIdentifier copy];
                byIdentifier[identifier] = [record copy];
            }
        }
    }
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *identifier in [[byIdentifier allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [result addObject:byIdentifier[identifier]];
    return [result copy];
}

@implementation VDTExtensionCatalog
+ (instancetype)sharedInstance {
    NSAssert(NSThread.isMainThread, @"Catalog access must be on main");
    static VDTExtensionCatalog *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (instancetype)init {
    NSAssert(NSThread.isMainThread, @"Catalog state must be on main");
    if ((self = [super init])) {
        VDTListCatalogInit(&_state);
        _observers = [NSHashTable weakObjectsHashTable];
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        LSApplicationWorkspace *workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)]
            ? [workspaceClass defaultWorkspace] : nil;
        if ([workspace respondsToSelector:@selector(addObserver:)]) [workspace addObserver:self];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationBecameActive:)
            name:@"UIApplicationDidBecomeActiveNotification" object:nil];
    }
    return self;
}
- (BOOL)loaded { NSAssert(NSThread.isMainThread, @"Main only"); return _state.loaded; }
- (BOOL)loading { NSAssert(NSThread.isMainThread, @"Main only"); return _state.loading; }
- (BOOL)failed { NSAssert(NSThread.isMainThread, @"Main only"); return _state.failed; }
- (NSArray *)records { NSAssert(NSThread.isMainThread, @"Main only"); return _records; }
- (void)ensureLoaded {
    NSAssert(NSThread.isMainThread, @"Main only");
    [self beginScanWithFallback:YES];
}
- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    VDTListCatalogInvalidate(&_state);
    [self beginScanWithFallback:NO];
}
- (void)beginScanWithFallback:(BOOL)fallback {
    NSAssert(NSThread.isMainThread, @"Main only");
    if (!VDTListCatalogEnsure(&_state, NSProcessInfo.processInfo.systemUptime, fallback)) return;
    uint64_t generation = _state.activeGeneration;
    [self notifyObservers];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSArray *records = nil;
            @try { records = VDTScanExtensions(); }
            @catch (NSException *exception) { (void)exception; }
            dispatch_async(dispatch_get_main_queue(), ^{
                VDTListCatalogCompletion completion = VDTListCatalogComplete(&self->_state, generation, records != nil);
                if (completion == VDTListCatalogIgnored) return;
                if (completion == VDTListCatalogPublish) self->_records = [records copy];
                if (completion != VDTListCatalogSuperseded) [self notifyObservers];
                // Complete stale work first; one follow-up for every merged invalidation.
                [self beginScanWithFallback:NO];
            });
        }
    });
}
- (void)addObserver:(id<VDTExtensionCatalogObserver>)observer {
    NSAssert(NSThread.isMainThread, @"Main only");
    [_observers addObject:observer];
}
- (void)removeObserver:(id<VDTExtensionCatalogObserver>)observer {
    NSAssert(NSThread.isMainThread, @"Main only");
    [_observers removeObject:observer];
}
- (void)notifyObservers {
    NSAssert(NSThread.isMainThread, @"Main only");
    for (id<VDTExtensionCatalogObserver> observer in _observers.allObjects)
        [observer extensionCatalogDidUpdate:self];
}
- (void)applicationsDidInstall:(id)applications { (void)applications; [self refresh]; }
- (void)applicationsDidUninstall:(id)applications { (void)applications; [self refresh]; }
- (void)applicationsDidUpdate:(id)applications { (void)applications; [self refresh]; }
- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self ensureLoaded]; }); return; }
    [self ensureLoaded];
}
@end
