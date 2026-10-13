// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
// Generated method slots are filled ONLY by test_list_reentry.py with verbatim
// production slices. This template does not duplicate production method bodies.
// Foundation only: no UIKit, Preferences, real catalog, dispatch or device.
// MODEL ASSUMPTION: super reload clears indexes, then _specifiers, then rebuilds.
// The table keeps a non-owning identity + weak snapshot, NOT another strong array.
// Catalog/search/rule notifications below simulate entering production reload;
// they do not test real observer threading, scanning, search or rule algorithms.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>

static const char *activeClass = "fixture";
static unsigned assertions;
#define CHECK(condition, message) do { \
    ++assertions; \
    if (!(condition)) { \
        std::fprintf(stderr, "ASSERTION FAILED: %s line %d: %s\n", \
                     activeClass, __LINE__, message); \
        std::exit(86); \
    } \
} while (0)
// Drain ARC weak-read temporaries after each event, so the weak snapshot does not
// accidentally keep a released NSArray alive until the outer scenario pool ends.
#define EVENT(statement) do { @autoreleasepool { statement; } } while (0)

@interface VDTListHost : NSObject {
@protected
    NSArray *_specifiers;
    __weak NSArray *_weakSnapshot;
    uintptr_t _indexToken;
@public
    unsigned builds, reloads, willCalls, didCalls, disappearCalls;
    BOOL lastWillAnimated, lastDidAnimated, lastDisappearAnimated;
}
- (NSArray *)specifiers;
- (BOOL)snapshotIntact;
- (BOOL)fixtureVisible;
- (BOOL)fixtureDirty;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)reloadSpecifiers;
@end

@implementation VDTListHost
- (BOOL)fixtureVisible { return NO; }
- (BOOL)fixtureDirty { return NO; }
- (NSArray *)specifiers {
    if (!_specifiers) {
        CHECK(_indexToken == 0, "rebuild while old table indexes survive");
        ++builds;
        // A freshly allocated nonempty sentinel, never a shared empty NSArray.
        _specifiers = [[NSArray alloc] initWithObjects:[NSObject new], @(builds), nil];
        _weakSnapshot = _specifiers;
        _indexToken = reinterpret_cast<uintptr_t>((__bridge void *)_specifiers);
    }
    return _specifiers;
}
- (BOOL)snapshotIntact {
    return _specifiers != nil && _weakSnapshot == _specifiers &&
        _indexToken == reinterpret_cast<uintptr_t>((__bridge void *)_specifiers);
}
- (void)viewWillAppear:(BOOL)animated {
    ++willCalls; lastWillAnimated = animated;
    CHECK(!self.fixtureVisible && self.fixtureDirty, "willAppear state before super");
    CHECK(self.snapshotIntact, "willAppear released live snapshot before super");
}
- (void)viewDidAppear:(BOOL)animated {
    ++didCalls; lastDidAnimated = animated;
    CHECK(!self.fixtureVisible, "didAppear must forward super before setting visible");
    CHECK(self.snapshotIntact, "didAppear lost transition snapshot");
}
- (void)viewWillDisappear:(BOOL)animated {
    ++disappearCalls; lastDisappearAnimated = animated;
    CHECK(!self.fixtureVisible, "willDisappear must hide before super");
    CHECK(self.snapshotIntact, "willDisappear lost live snapshot");
}
- (void)reloadSpecifiers {
    CHECK(self.fixtureVisible, "hidden reload reached superclass");
    CHECK(!self.fixtureDirty, "dirty was not cleared before superclass reload");
    CHECK(self.snapshotIntact, "snapshot manually released before superclass index cleanup");
    ++reloads;
    // Assumed system-side ordering; this is the safe boundary under test.
    _indexToken = 0;
    _specifiers = nil;
    (void)[self specifiers];
    CHECK(self.snapshotIntact, "superclass failed to rebuild indexes and array");
}
@end

@interface VDTCatalog : NSObject
@property(nonatomic, weak) VDTListHost *target;
@property(nonatomic) BOOL loaded;
@property(nonatomic) unsigned ensures, loadStarts, publications, reentrantPublications;
- (void)resetWarm:(BOOL)warm target:(VDTListHost *)target;
- (void)ensureLoaded;
- (void)updateDaemonListIfNeeded;
- (void)deliver:(unsigned)count;
@end
@implementation VDTCatalog
- (void)resetWarm:(BOOL)warm target:(VDTListHost *)target {
    self.target = target; self.loaded = warm;
    self.ensures = 0; self.loadStarts = 0; self.publications = 0;
    self.reentrantPublications = 0;
}
- (void)ensureLoaded {
    ++_ensures;
    if (!self.loaded && self.loadStarts == 0) ++_loadStarts;
    unsigned count = self.reentrantPublications;
    self.reentrantPublications = 0;
    if (count) [self deliver:count]; // deliberately synchronous/reentrant
}
- (void)updateDaemonListIfNeeded { [self ensureLoaded]; }
- (void)deliver:(unsigned)count {
    self.loaded = YES;
    for (unsigned i = 0; i < count; ++i) {
        ++_publications;
        [self.target reloadSpecifiers];
    }
}
@end

@interface VDTDaemonList : VDTCatalog
+ (instancetype)sharedInstance;
@end
@implementation VDTDaemonList
+ (instancetype)sharedInstance {
    static VDTDaemonList *catalog; if (!catalog) catalog = [self new]; return catalog;
}
@end
@interface VDTExtensionCatalog : VDTCatalog
+ (instancetype)sharedInstance;
@end
@implementation VDTExtensionCatalog
+ (instancetype)sharedInstance {
    static VDTExtensionCatalog *catalog; if (!catalog) catalog = [self new]; return catalog;
}
@end

@interface VDTDaemonListController : VDTListHost {
    BOOL _vdtVisible, _vdtNeedsReload;
}
@end
@implementation VDTDaemonListController
- (BOOL)fixtureVisible { return _vdtVisible; }
- (BOOL)fixtureDirty { return _vdtNeedsReload; }
/* VDT_EXTRACTED_DAEMON_METHODS */
@end

@interface VDTExtensionListController : VDTListHost
@property(nonatomic) BOOL catalogVisible;
@property(nonatomic) BOOL catalogNeedsReload;
@end
@implementation VDTExtensionListController
- (BOOL)fixtureVisible { return self.catalogVisible; }
- (BOOL)fixtureDirty { return self.catalogNeedsReload; }
/* VDT_EXTRACTED_EXTENSION_METHODS */
@end

static void prime(VDTListHost *host) {
    EVENT((void)[host specifiers]);
    CHECK(host->builds == 1 && host.snapshotIntact, "initial table snapshot missing");
}
static void will(VDTListHost *host, VDTCatalog *catalog, BOOL animated) {
    unsigned calls = host->willCalls, reloads = host->reloads;
    unsigned builds = host->builds, ensures = catalog.ensures;
    EVENT([host viewWillAppear:animated]);
    CHECK(host->willCalls == calls + 1 && host->lastWillAnimated == animated,
          "willAppear super not forwarded exactly once with animation");
    CHECK(catalog.ensures == ensures + 1, "catalog ensure not called exactly once");
    CHECK(!host.fixtureVisible && host.fixtureDirty, "appearing state not hidden/dirty");
    CHECK(host->reloads == reloads && host->builds == builds && host.snapshotIntact,
          "appearing transition invalidated table snapshot");
}
static void did(VDTListHost *host, BOOL animated) {
    unsigned calls = host->didCalls, reloads = host->reloads, builds = host->builds;
    __weak NSArray *retired;
    EVENT(retired = [host specifiers]);
    EVENT([host viewDidAppear:animated]);
    CHECK(host->didCalls == calls + 1 && host->lastDidAnimated == animated,
          "didAppear super not forwarded exactly once with animation");
    CHECK(host.fixtureVisible && !host.fixtureDirty, "visible reload did not clean dirty");
    CHECK(host->reloads == reloads + 1 && host->builds == builds + 1,
          "didAppear did not perform exactly one complete rebuild");
    CHECK(retired == nil && host.snapshotIntact, "complete reload retained old/stale snapshot");
}
static void disappear(VDTListHost *host, BOOL animated) {
    unsigned calls = host->disappearCalls, reloads = host->reloads, builds = host->builds;
    BOOL dirty = host.fixtureDirty;
    EVENT([host viewWillDisappear:animated]);
    CHECK(host->disappearCalls == calls + 1 && host->lastDisappearAnimated == animated,
          "willDisappear super not forwarded exactly once with animation");
    CHECK(!host.fixtureVisible && host.fixtureDirty == dirty,
          "disappearing changed unrelated dirty state");
    CHECK(host->reloads == reloads && host->builds == builds && host.snapshotIntact,
          "disappearing transition invalidated table snapshot");
}
static void hiddenFill(VDTListHost *host, VDTCatalog *catalog, unsigned count) {
    unsigned reloads = host->reloads, builds = host->builds, publications = catalog.publications;
    EVENT([catalog deliver:count]);
    CHECK(catalog.publications == publications + count, "catalog signal count incorrect");
    CHECK(!host.fixtureVisible && host.fixtureDirty, "hidden callback did not set dirty");
    CHECK(host->reloads == reloads && host->builds == builds && host.snapshotIntact,
          "hidden callback released or rebuilt transition snapshot");
}

static void visibleSignal(VDTListHost *host, const char *reason) {
    unsigned reloads = host->reloads, builds = host->builds;
    __weak NSArray *retired;
    EVENT(retired = [host specifiers]);
    EVENT([host reloadSpecifiers]); // search/rule caller's real lifecycle entry
    CHECK(host->reloads == reloads + 1 && host->builds == builds + 1, reason);
    CHECK(host.fixtureVisible && !host.fixtureDirty && host.snapshotIntact && retired == nil,
          "visible search/rule refresh did not replace snapshot and clean dirty");
}
static void scenarios(Class type, VDTCatalog *catalog) {
    activeClass = class_getName(type);
    @autoreleasepool {
        // Cold NEW instance: loading snapshot survives callbacks during entrance.
        VDTListHost *host = [type new];
        [catalog resetWarm:NO target:host]; prime(host);
        will(host, catalog, YES);
        CHECK(catalog.loadStarts == 1 && !catalog.loaded, "cold ensure did not start once");
        hiddenFill(host, catalog, 4); // multiple loading completions coalesce
        did(host, YES);
        CHECK(catalog.ensures == 1 && catalog.publications == 4, "cold catalog counts");
        disappear(host, YES);
        hiddenFill(host, catalog, 3); // dirty was previously NO; disappearance backfill
        will(host, catalog, NO); did(host, NO); // SAME-instance warm return
        CHECK(catalog.loadStarts == 1 && catalog.ensures == 2, "warm reentry rescanned");
        disappear(host, NO);
        will(host, catalog, YES); did(host, YES); // no callbacks: still fresh grouping
        CHECK(host->reloads == 3, "same-instance clean reentry did not rebuild once");
        visibleSignal(host, "visible search refresh skipped complete super reload");
        visibleSignal(host, "visible rule refresh skipped complete super reload");
        unsigned reloads = host->reloads;
        EVENT([catalog deliver:2]);
        CHECK(host->reloads == reloads + 2 && !host.fixtureDirty && host.snapshotIntact,
              "visible catalog backfill was incorrectly deferred/coalesced");
    }
    @autoreleasepool {
        // Warm NEW instance: ensure can synchronously reenter reload three times.
        VDTListHost *host = [type new];
        [catalog resetWarm:YES target:host]; prime(host);
        catalog.reentrantPublications = 3;
        will(host, catalog, NO);
        CHECK(catalog.loadStarts == 0 && catalog.publications == 3,
              "warm ensure did not deliver reentrant signals without scanning");
        did(host, NO);
        // Interactive outgoing transition cancellation: callback while hidden,
        // then will/did appearance of the same instance, not a fresh allocation.
        disappear(host, YES); hiddenFill(host, catalog, 5);
        will(host, catalog, YES); did(host, YES);
        CHECK(host->reloads == 2, "cancelled outgoing transition reloaded more than once");
        // Incoming transition cancellation has NO didAppear: keep the prior
        // array/index snapshot until a later successful entrance completes.
        disappear(host, NO); will(host, catalog, YES);
        hiddenFill(host, catalog, 2); disappear(host, YES);
        CHECK(host->reloads == 2 && host.fixtureDirty, "cancelled incoming reload was premature");
        hiddenFill(host, catalog, 3); will(host, catalog, NO); did(host, NO);
        CHECK(host->reloads == 3 && catalog.loadStarts == 0,
              "cancelled incoming backfills were not merged at next didAppear");
        // Search and rule changes while hidden use the same dirty/reload entry.
        disappear(host, NO);
        EVENT([host reloadSpecifiers]); EVENT([host reloadSpecifiers]);
        CHECK(host.fixtureDirty && host->reloads == 3 && host.snapshotIntact,
              "hidden search/rule signal damaged snapshot");
        will(host, catalog, YES); did(host, YES);
        CHECK(host->reloads == 4 && catalog.ensures == 5, "hidden signals not merged once");
    }
    std::printf("PASS %s: cold/warm new, same-instance reentry, reentrant/coalesced "
                "backfill, search/rules, both cancellations, super lifecycle\n", activeClass);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(NSThread.isMainThread, "fixture must run on main thread");
        BOOL daemon = argc == 1 || (argc == 2 && !std::strcmp(argv[1], "VDTDaemonListController"));
        BOOL extension = argc == 1 || (argc == 2 && !std::strcmp(argv[1], "VDTExtensionListController"));
        CHECK(daemon || extension, "invalid class selection");
        if (daemon) scenarios(VDTDaemonListController.class, [VDTDaemonList sharedInstance]);
        if (extension) scenarios(VDTExtensionListController.class, [VDTExtensionCatalog sharedInstance]);
        std::printf("PASS Foundation fixture: %u assertions; simulated parent/catalog only; "
                    "NOT UIKit/Preferences/device\n", assertions);
    }
    return 0;
}
