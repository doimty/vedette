// Host integration tests: real Foundation + bounded local files, fake kernel.
#import "../VDTNiceRuntime.h"
#import "../VDTNiceShared.h"
#import "../VDTNiceStore.h"
#include <sys/resource.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <notify.h>
#include <stdint.h>
// The production CPU resolver is intentionally not linked into these tests.
NSString * const VDTConfigTypeKey = @"type";
NSString * const VDTTargetPidKey = @"pid";
NSString * const VDTTargetNameKey = @"name";
NSString * const VDTTargetExecutablePathKey = @"executablePath";
NSString * const VDTTargetProcCommKey = @"procComm";
NSString * const VDTTargetStartSecondsKey = @"startSeconds";
NSString * const VDTTargetStartMicrosecondsKey = @"startMicroseconds";
static NSString *testRoot;
extern "C" NSString *VDTTestJbroot(NSString *path) { return [testRoot stringByAppendingString:path]; }
static int niceNow, writeError, readError, writeCount, readCount;
static BOOL missing, unavailable, reused, ignoreWrite;
static int fakeGet(int which, id_t pid) {
    (void)which; (void)pid; ++readCount; errno = readError;
    return readError ? -1 : niceNow;
}
static int fakeSet(int which, id_t pid, int value) {
    (void)which; (void)pid; ++writeCount; errno = writeError;
    if (writeError) return -1;
    if (!ignoreWrite) niceNow = value;
    return 0;
}
static int fakeInfo(int pid, int flavor, uint64_t arg, void *buffer, int capacity) {
    (void)flavor; (void)arg;
    if (missing || unavailable) { errno = missing ? ESRCH : EPERM; return 0; }
    struct vdt_proc_bsdinfo info = {};
    info.pbi_pid = (uint32_t)pid; info.pbi_start_tvsec = reused ? 999 : 100; info.pbi_start_tvusec = 1;
    if (capacity != sizeof(info)) return 0;
    memcpy(buffer, &info, sizeof(info)); return sizeof(info);
}
static BOOL fakeCurrent(NSDictionary *target) { (void)target; return !missing && !unavailable && !reused; }
#define getpriority fakeGet
#define setpriority fakeSet
#define proc_pidinfo fakeInfo
#define vdt_target_is_current fakeCurrent
// Status-receipt interception, scoped to this translation unit only. The real
// declarations are included above so the shared headers are never rewritten by
// a macro, both wrappers call the real C functions, and the separately compiled
// VDTNiceShared.mm keeps its own unredirected calls.
static int statusWriteCalls, statusWriteFail, statusNotifyCount;
static __typeof__(&notify_post) const vdtRealNotifyPost = &notify_post;
static uint32_t vdtTestNotifyPost(const char *name) {
    if (name && !strcmp(name, VDT_NICE_RESULTS_NOTIFICATION)) ++statusNotifyCount;
    return vdtRealNotifyPost(name);
}
static int (*const vdtRealStoreWrite)(VDTNiceStore *, const char *, const void *, size_t) = &VDTNiceStoreWrite;
static int vdtTestStoreWrite(VDTNiceStore *store, const char *name, const void *bytes, size_t length) {
    if (name && !strcmp(name, VDT_NICE_STATUS)) {
        ++statusWriteCalls;
        if (statusWriteFail) return EIO;
    }
    return vdtRealStoreWrite(store, name, bytes, length);
}
#define notify_post(name) vdtTestNotifyPost(name)
#define VDTNiceStoreWrite(store, name, bytes, length) vdtTestStoreWrite(store, name, bytes, length)
#import "../VDTNiceRuntime.mm"
#undef getpriority
#undef setpriority
#undef proc_pidinfo
#undef vdt_target_is_current
#undef notify_post
#undef VDTNiceStoreWrite

static NSTimeInterval testRetryNow = 10;
static int fixtureStoreError, fixtureStoreCalls;
@interface VDTNiceFixtureClockCoordinator : VDTNiceCoordinator
@end
@implementation VDTNiceFixtureClockCoordinator
- (NSTimeInterval)retryClock { return testRetryNow; }
- (int)save:(const VDTNiceRecord *)r target:(NSDictionary *)t {
    ++fixtureStoreCalls;
    return fixtureStoreError ?: [super save:r target:t];
}
@end

// Byte-level and deep-plist views of the store used by the receipt tests.
static NSDictionary *statusFile(VDTNiceCoordinator *c) {
    int error = 0;
    NSDictionary *plist = readPlist(&c->store, VDT_NICE_STATUS, &error);
    return error ? nil : plist;
}
static NSData *stateBytes(const char *name) {
    return [NSData dataWithContentsOfFile:[VDTNiceStateDirectory()
        stringByAppendingPathComponent:[NSString stringWithUTF8String:name]]];
}
static NSData *statusBytes(void) { return stateBytes(VDT_NICE_STATUS); }
static NSData *journalBytes(void) { return stateBytes(VDT_NICE_JOURNAL); }
// Deep immutable copy of an in-memory snapshot: a receipt publish must not
// rewrite the journal-backed state it is only reading.
static id plistSnapshot(id object) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return nil;
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
}
static NSArray *setSnapshot(NSSet *set) {
    return [set.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static unsigned assertions;
#define REQUIRE(x) do { ++assertions; if (!(x)) { fprintf(stderr,"native line %d: %s\n",__LINE__,#x); abort(); } } while (0)
static NSDictionary *target(void) {
    return @{VDTTargetPidKey: @424242, VDTConfigTypeKey: @(VDTConfigTypeDaemon),
        VDTTargetNameKey: @"test-worker", VDTTargetStartSecondsKey: @100,
        VDTTargetStartMicrosecondsKey: @1, VDTTargetExecutablePathKey: @"/usr/libexec/test-worker"};
}
static NSDictionary *prefs(BOOL enabled, int value, NSString *revision) {
    return @{@"enabled": @YES, @"daemonConfigs": @[@{@"daemonName": @"test-worker", @"enabled": @NO,
        VDT_NICE_ENABLED_KEY: @(enabled), VDT_NICE_VALUE_KEY: @(value), VDT_NICE_REVISION_KEY: revision}]};
}
static void clearFixture(void) {
    [[NSFileManager defaultManager] removeItemAtPath:VDTNiceStateDirectory() error:nil];
    niceNow = -1; writeCount = readCount = writeError = readError = 0;
    fixtureStoreError = fixtureStoreCalls = 0;
    statusWriteFail = 0;
    missing = unavailable = reused = ignoreWrite = NO;
}
static void cycle(VDTNiceCoordinator *c, NSDictionary *p) {
    [c reload:p]; [c reconcile]; [c apply:target()]; [c publish];
}
static NSDictionary *storedEntry(VDTNiceCoordinator *c) {
    return c->records[instanceKey(target())][@"record"];
}
int main(void) {
    @autoreleasepool {
        if (geteuid() != 0) { fputs("native tests require root for isolated root-owned fixtures\n",stderr); return 77; }
        char path[] = "/tmp/vedette-nice-native.XXXXXX";
        REQUIRE(mkdtemp(path) != NULL); testRoot = @(path);
        NSFileManager *fm = NSFileManager.defaultManager;
        REQUIRE([fm createDirectoryAtPath:VDTTestJbroot(@"/var/tmp") withIntermediateDirectories:YES attributes:nil error:nil]);
        REQUIRE([fm createDirectoryAtPath:VDTTestJbroot(@"/var/mobile/Library/Preferences") withIntermediateDirectories:YES attributes:nil error:nil]);
        int number = 0;
        for (id bad in @[@YES, @1.5, @21, @(-21), @"", @"+", @"2x", @" 2", @[], @{}, NSNull.null])
            REQUIRE(!VDTNiceParseValue(bad, &number));
        for (id good in @[@(-20), @(-1), @0, @20, @"-20", @"+20", @"0"]) REQUIRE(VDTNiceParseValue(good, &number));
        NSDictionary *legacy = @{@"daemonConfigs": @[@{@"daemonName": @"test-worker", @"enabled": @YES}]};
        REQUIRE(![VDTNiceRulesFromPrefs(legacy)[@"1:test-worker"][@"enabled"] boolValue]);
        REQUIRE([VDTNiceRulesFromPrefs(prefs(YES,5,@"a"))[@"1:test-worker"][@"enabled"] boolValue]);

        clearFixture();
        VDTNiceCoordinator *c = [VDTNiceCoordinator new];
        cycle(c, prefs(YES,5,@"a"));
        REQUIRE(c->loadError == 0 && niceNow == 5 && writeCount == 1);
        REQUIRE([storedEntry(c)[@"original"] isEqual:@(-1)]);
        [c apply:target()]; REQUIRE(writeCount == 1);
        // New manager reads the original from disk, not the modified kernel value.
        c = [VDTNiceCoordinator new]; cycle(c, prefs(YES,10,@"b"));
        REQUIRE(niceNow == 10 && [storedEntry(c)[@"original"] isEqual:@(-1)]);
        cycle(c, prefs(NO,10,@"c")); REQUIRE(niceNow == -1 && c->records.count == 0);
        REQUIRE([VDTNiceMatchingStatus(@"test-worker",VDTConfigTypeDaemon,prefs(NO,10,@"c"))[@"state"] isEqual:@"restored"]);
        REQUIRE(VDTNiceMatchingStatus(@"test-worker",VDTConfigTypeDaemon,prefs(NO,10,@"stale")) == nil);
        REQUIRE(VDTNiceMatchingStatus(@"test-worker",VDTConfigTypeDaemon,prefs(NO,9,@"c")) == nil);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        NSMutableDictionary *globalOff = [prefs(YES,5,@"a") mutableCopy]; globalOff[@"enabled"] = @NO;
        cycle(c,globalOff); REQUIRE(niceNow == -1 && c->records.count == 0);
        REQUIRE(VDTNiceMatchingStatus(@"test-worker",VDTConfigTypeDaemon,prefs(YES,5,@"a")) == nil);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        REQUIRE([fm removeItemAtPath:VDTNiceStateDirectory() error:nil]);
        cycle(c,@{}); REQUIRE(c->loadError != 0 && c->records.count == 1 && writeCount == 1);

        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        unavailable = YES; cycle(c,prefs(NO,5,@"b"));
        REQUIRE(c->records.count == 1 && niceNow == 5 && writeCount == 1);
        unavailable = NO; cycle(c,prefs(NO,5,@"b")); REQUIRE(niceNow == -1 && c->records.count == 0);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        reused = YES; cycle(c,@{}); REQUIRE(writeCount == 1 && c->records.count == 0);
        clearFixture(); c = [VDTNiceCoordinator new]; writeError = EPERM;
        cycle(c,prefs(YES,5,@"a")); REQUIRE(niceNow == -1 && c->records.count == 1);
        [c apply:target()]; REQUIRE(writeCount == 1);
        writeError = 0; cycle(c,prefs(YES,5,@"a")); REQUIRE(niceNow == 5 && writeCount == 2);
        niceNow = 12; cycle(c,prefs(NO,5,@"b")); REQUIRE(writeCount == 2 && c->records.count == 1);
        niceNow = 5; cycle(c,prefs(NO,5,@"b")); REQUIRE(niceNow == -1 && c->records.count == 0);

        clearFixture(); c = [VDTNiceCoordinator new]; ignoreWrite = YES;
        cycle(c,prefs(YES,5,@"a"));
        REQUIRE([c->outcomes[instanceKey(target())][@"state"] isEqual:@"verify-failed"] && c->records.count == 1);
        ignoreWrite = NO; cycle(c,prefs(YES,5,@"a")); REQUIRE(niceNow == 5);
        // Deletion, not just an explicit switch off, restores retained records.
        cycle(c,@{}); REQUIRE(niceNow == -1 && c->records.count == 0);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        REQUIRE(VDTNiceStoreRemove(&c->store,VDT_NICE_JOURNAL) == 0);
        cycle(c,prefs(YES,9,@"b")); REQUIRE(c->loadError != 0 && niceNow == 5 && writeCount == 1);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        REQUIRE(VDTNiceStoreWrite(&c->store,VDT_NICE_JOURNAL,"broken",6) == 0);
        c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,9,@"b")); REQUIRE(c->loadError != 0 && writeCount == 1);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        REQUIRE(writePlist(&c->store,VDT_NICE_JOURNAL,@{@"version":@1,@"boot":@"previous-boot",@"records":c->records}) == 0);
        c = [VDTNiceCoordinator new]; cycle(c,@{}); REQUIRE(writeCount == 1 && c->records.count == 0);
        // Stale-boot junk is discarded before entry validation: a record an
        // older version wrote must never dead-lock the store it cannot join.
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        NSDictionary *legacyAppex = @{VDTTargetPidKey: @424243, VDTConfigTypeKey: @(VDTConfigTypeApp),
            VDTTargetNameKey: @"com.example.host", VDTTargetStartSecondsKey: @100, VDTTargetStartMicrosecondsKey: @1,
            VDTTargetExecutablePathKey: @"/private/var/containers/Bundle/Application/UUID/Host.app/PlugIns/HostService.appex/HostService"};
        NSString *legacyKey = instanceKey(legacyAppex);
        NSDictionary *legacyRecord = @{@"captured": @YES, @"original": @0, @"owns": @NO,
            @"owned": @0, @"hasIntent": @NO, @"intent": @0};
        NSMutableDictionary *junk = [c->records mutableCopy];
        junk[legacyKey] = @{@"target": legacyAppex, @"record": legacyRecord};
        REQUIRE(writePlist(&c->store,VDT_NICE_JOURNAL,@{@"version":@1,@"boot":@"previous-boot",@"records":junk}) == 0);
        c = [VDTNiceCoordinator new]; cycle(c,@{}); REQUIRE(c->loadError == 0 && c->records.count == 0 && writeCount == 1);
        int junkError = 0; NSDictionary *junkFile = readPlist(&c->store,VDT_NICE_JOURNAL,&junkError);
        REQUIRE(!junkError && [junkFile[@"boot"] isEqual:VDTNiceBootToken()] && [junkFile[@"records"] count] == 0);
        // Format drift on a current-boot journal: unreadable entries are
        // dropped, readable records kept, and the store stays usable.
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        NSMutableDictionary *mixed = [c->records mutableCopy];
        mixed[legacyKey] = @{@"target": legacyAppex, @"record": legacyRecord};
        REQUIRE(writePlist(&c->store,VDT_NICE_JOURNAL,@{@"version":@1,@"boot":VDTNiceBootToken(),@"records":mixed}) == 0);
        c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        REQUIRE(c->loadError == 0 && c->records.count == 1 && c->records[legacyKey] == nil && niceNow == 5);
        int mixedError = 0; NSDictionary *mixedFile = readPlist(&c->store,VDT_NICE_JOURNAL,&mixedError);
        REQUIRE(!mixedError && [mixedFile[@"records"] count] == 1);
        // While this coordinator still owns in-memory records, an alien file
        // keeps the strict guarded form instead of being merged or dropped.
        mixed[legacyKey] = @{@"target": @{}, @"record": @{}};
        REQUIRE(writePlist(&c->store,VDT_NICE_JOURNAL,@{@"version":@1,@"boot":VDTNiceBootToken(),@"records":mixed}) == 0);
        cycle(c,prefs(YES,5,@"a")); REQUIRE(c->loadError != 0);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c,prefs(YES,5,@"a"));
        REQUIRE(writePlist(&c->store,VDT_NICE_REQUEST,@{@"version":@1,@"boot":VDTNiceBootToken(),@"nonce":@"test-removal"}) == 0);
        cycle(c,prefs(YES,5,@"a"));
        REQUIRE(c->paused && niceNow == -1 && c->records.count == 0);
        int error = 0; NSDictionary *receipt = readPlist(&c->store,VDT_NICE_STATUS,&error);
        REQUIRE(!error && [receipt[@"restoreNonce"] isEqual:@"test-removal"] && [receipt[@"recordCount"] isEqual:@0]);

        // No reload between a transient failure and its automatic retry.
        clearFixture(); testRetryNow = 10; c = [VDTNiceFixtureClockCoordinator new];
        readError = EAGAIN; cycle(c,prefs(YES,5,@"retry-read"));
        REQUIRE(c->records.count == 0 && writeCount == 0 && [c nextRetryDelay] == 0.5);
        int failedReads = readCount; readError = 0;
        [c reconcile]; [c apply:target()]; REQUIRE(readCount == failedReads);
        testRetryNow = 10.5; [c reconcile]; [c publish];
        REQUIRE(niceNow == 5 && writeCount == 1 && [c nextRetryDelay] < 0);
        REQUIRE([storedEntry(c)[@"original"] isEqual:@(-1)]);

        // Disabled restoration retries independently, preserving the journal.
        unavailable = YES; [c reload:prefs(NO,5,@"retry-restore")]; [c reconcile];
        REQUIRE(niceNow == 5 && c->records.count == 1 && [c nextRetryDelay] == 0.5);
        unavailable = NO; testRetryNow = 11; [c reconcile];
        REQUIRE(niceNow == -1 && c->records.count == 0 && [c nextRetryDelay] < 0);

        // No retry storm: exactly initial + 2 attempts, then explicit reload resets.
        clearFixture(); testRetryNow = 20; c = [VDTNiceFixtureClockCoordinator new]; readError = EIO;
        cycle(c,prefs(YES,5,@"retry-bound")); REQUIRE(readCount == 1);
        testRetryNow = 20.5; [c reconcile]; REQUIRE(readCount == 2);
        testRetryNow = 22.5; [c reconcile]; REQUIRE(readCount == 3 && [c nextRetryDelay] < 0);
        testRetryNow = 200; [c reconcile]; [c apply:target()]; REQUIRE(readCount == 3);
        readError = 0; cycle(c,prefs(YES,5,@"retry-bound")); REQUIRE(niceNow == 5 && writeCount == 1);

        // Publish must keep the actual last check time, even if another event
        // causes a new receipt. The UI labels this historical, never live.
        NSMutableDictionary *historical = [c->outcomes[instanceKey(target())] mutableCopy];
        historical[@"checkedAt"] = @123; c->outcomes[instanceKey(target())] = historical;
        c->receiptDirty = YES; [c publish];
        NSDictionary *oldStatus = VDTNiceMatchingStatus(@"test-worker",VDTConfigTypeDaemon,prefs(YES,5,@"retry-bound"));
        REQUIRE([oldStatus[@"checkedAt"] isEqual:@123] && [oldStatus[@"oldestCheckedAt"] isEqual:@123]);
        int oldReads = readCount; niceNow = 17; [c reconcile]; [c apply:target()];
        c->receiptDirty = YES; [c publish];
        REQUIRE(readCount == oldReads && [VDTNiceMatchingStatus(@"test-worker",VDTConfigTypeDaemon,prefs(YES,5,@"retry-bound"))[@"checkedAt"] isEqual:@123]);
        cycle(c,prefs(YES,5,@"retry-bound"));
        REQUIRE([c->outcomes[instanceKey(target())][@"state"] isEqual:@"conflict"] && niceNow == 17);
        REQUIRE([c nextRetryDelay] < 0);

        // Gone cleanup has a bounded STORE retry too, even while the saved
        // rule is enabled; repeated reconcile must not reset its budget.
        clearFixture(); testRetryNow = 30; c = [VDTNiceFixtureClockCoordinator new];
        cycle(c,prefs(YES,5,@"gone-store")); missing = YES; fixtureStoreError = EIO;
        int oldStoreCalls = fixtureStoreCalls; [c reconcile];
        REQUIRE(fixtureStoreCalls == oldStoreCalls + 1 && [c nextRetryDelay] == 0.5);
        testRetryNow = 30.5; [c reconcile]; REQUIRE(fixtureStoreCalls == oldStoreCalls + 2);
        testRetryNow = 32.5; [c reconcile]; REQUIRE(fixtureStoreCalls == oldStoreCalls + 3 && [c nextRetryDelay] < 0);
        testRetryNow = 300; [c reconcile]; REQUIRE(fixtureStoreCalls == oldStoreCalls + 3 && writeCount == 1);
        fixtureStoreError = 0; cycle(c,prefs(YES,5,@"gone-store"));
        REQUIRE(c->records.count == 0 && writeCount == 1);

        // Strict independent save preserves CPU configuration and updates only nice.
        NSDictionary *cpu = @{@"enabled":@YES,@"daemonConfigs":@[@{@"daemonName":@"test-worker",@"enabled":@YES,
            @"percentage":@80,@"violationPolicy":@3,@"interval":@120}]};
        REQUIRE([cpu writeToFile:PREFS_PATH atomically:YES]);
        NSError *saveError = nil;
        REQUIRE(VDTNiceSavePreference(@"test-worker",VDTConfigTypeDaemon,VDT_NICE_ENABLED_KEY,@YES,&saveError));
        NSDictionary *saved = getPrefs()[@"daemonConfigs"][0];
        REQUIRE([saved[@"enabled"] isEqual:@YES] && [saved[@"percentage"] isEqual:@80] && [saved[@"violationPolicy"] isEqual:@3]);
        REQUIRE([saved[VDT_NICE_VALUE_KEY] isEqual:@0] && [saved[VDT_NICE_ENABLED_KEY] isEqual:@YES]);
        REQUIRE(!VDTNiceSavePreference(@"test-worker",VDTConfigTypeDaemon,@"percentage",@5,&saveError));
        NSData *broken = [@"not a plist" dataUsingEncoding:NSUTF8StringEncoding];
        REQUIRE([broken writeToFile:PREFS_PATH atomically:YES]);
        REQUIRE(!VDTNiceSavePreference(@"test-worker",VDTConfigTypeDaemon,VDT_NICE_VALUE_KEY,@5,&saveError));
        REQUIRE([[NSData dataWithContentsOfFile:PREFS_PATH] isEqual:broken]);
        // ---- nice status receipt degradation (compact downgrade) -------------
        // The status file is a rebuildable display cache: the generic writer
        // stays fail-closed, the receipt writer degrades an oversized cache to a
        // small boot-bound EFBIG envelope, and the reader never repairs an
        // unreadable cache with an older success row.
        clearFixture(); c = [VDTNiceCoordinator new];
        NSMutableArray *daemons = [prefs(YES,5,@"compact-a")[@"daemonConfigs"] mutableCopy];
        [daemons addObject:@{@"daemonName": @"idle-worker", @"enabled": @NO,
            VDT_NICE_ENABLED_KEY: @NO, VDT_NICE_VALUE_KEY: @3, VDT_NICE_REVISION_KEY: @"compact-idle"}];
        [daemons addObject:@{@"daemonName": @"idle-worker-2", @"enabled": @NO,
            VDT_NICE_ENABLED_KEY: @YES, VDT_NICE_VALUE_KEY: @4, VDT_NICE_REVISION_KEY: @"compact-idle-2"}];
        [daemons addObject:@{@"daemonName": @"broken-worker", @"enabled": @NO,
            VDT_NICE_ENABLED_KEY: @YES, VDT_NICE_VALUE_KEY: @YES, VDT_NICE_REVISION_KEY: @"compact-bad"}];
        [daemons addObject:@{@"daemonName": @"launchd", @"enabled": @NO,
            VDT_NICE_ENABLED_KEY: @YES, VDT_NICE_VALUE_KEY: @0, VDT_NICE_REVISION_KEY: @"compact-guard"}];
        NSDictionary *compactPrefs = @{@"enabled": @YES, @"daemonConfigs": daemons};
        cycle(c, compactPrefs);
        REQUIRE(niceNow == 5 && writeCount == 1 && c->records.count == 1);
        // Positive control: an executed rule still produces a full receipt row.
        NSDictionary *liveRow = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, compactPrefs);
        REQUIRE([liveRow[@"state"] isEqual:@"applied"] && [liveRow[@"observed"] isEqual:@5]);
        REQUIRE([liveRow[@"checkedAt"] doubleValue] > 0 && [liveRow[@"error"] isEqual:@0]);
        REQUIRE(VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,5,@"compact-z")) == nil);
        // Rules that never executed and left no recovery record are ordinary:
        // an empty "nothing to do" row would be a lie, so both the disabled and
        // the enabled-but-never-attempted variants are dropped from the receipt.
        REQUIRE(VDTNiceMatchingStatus(@"idle-worker", VDTConfigTypeDaemon, compactPrefs) == nil);
        REQUIRE(VDTNiceMatchingStatus(@"idle-worker-2", VDTConfigTypeDaemon, compactPrefs) == nil);
        int compactError = 0; NSDictionary *compactReceipt = readPlist(&c->store, VDT_NICE_STATUS, &compactError);
        NSString *liveKey = ruleKey(target());
        REQUIRE(!compactError && [compactReceipt[@"rules"][liveKey][@"state"] isEqual:@"applied"]);
        REQUIRE(compactReceipt[@"rules"][@"1:idle-worker"] == nil);
        REQUIRE(compactReceipt[@"rules"][@"1:idle-worker-2"] == nil);
        // Invalid authority and protected daemons keep their diagnostic rows.
        NSDictionary *invalidRow = VDTNiceMatchingStatus(@"broken-worker", VDTConfigTypeDaemon, compactPrefs);
        REQUIRE([invalidRow[@"valid"] isEqual:@NO] && [invalidRow[@"state"] isEqual:@"invalid"]);
        REQUIRE([VDTNiceMatchingStatus(@"launchd", VDTConfigTypeDaemon, compactPrefs)[@"state"] isEqual:@"protected"]);
        // A store error and a pause are diagnostic too: un-executed rules keep a
        // row instead of looking like a clean, empty cache.
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c, compactPrefs);
        REQUIRE([fm removeItemAtPath:VDTNiceStateDirectory() error:nil]);
        cycle(c, compactPrefs);
        REQUIRE(c->loadError != 0 && c->records.count == 1);
        REQUIRE([VDTNiceMatchingStatus(@"idle-worker", VDTConfigTypeDaemon, compactPrefs)[@"state"]
            isEqual:@"state-unavailable"]);
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c, compactPrefs);
        REQUIRE(writePlist(&c->store, VDT_NICE_REQUEST,
            @{@"version": @1, @"boot": VDTNiceBootToken(), @"nonce": @"compact-pause"}) == 0);
        cycle(c, compactPrefs);
        REQUIRE(c->paused && niceNow == -1 && c->records.count == 0);
        REQUIRE([VDTNiceMatchingStatus(@"idle-worker", VDTConfigTypeDaemon, compactPrefs)[@"state"] isEqual:@"paused"]);
        // A recovery record without any execution outcome in this generation is
        // still journal authority and must keep its row.
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c, prefs(YES,7,@"pending-a"));
        REQUIRE(c->records.count == 1 && niceNow == 7);
        VDTNiceCoordinator *carry = [VDTNiceCoordinator new];
        [carry reload:prefs(NO,7,@"pending-b")];
        REQUIRE(carry->records.count == 1 && carry->outcomes.count == 0);
        [carry publish];
        NSDictionary *pendingRow = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(NO,7,@"pending-b"));
        REQUIRE([pendingRow[@"state"] isEqual:@"pending"] && [pendingRow[@"pendingCount"] isEqual:@1]);

        // Oversized receipt: one real outcome is polluted with a test-only
        // payload so the real publish path has to degrade. The blob exists only
        // in this coordinator's memory; the journal snapshots below prove none
        // of it is ever handed to the journal.
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c, prefs(YES,5,@"degrade-a"));
        REQUIRE(niceNow == 5 && writeCount == 1);
        NSDictionary *priorRow = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,5,@"degrade-a"));
        REQUIRE([priorRow[@"state"] isEqual:@"applied"] && [priorRow[@"observed"] isEqual:@5]);
        NSData *priorBytes = statusBytes();
        id priorSession = statusFile(c)[@"bootSession"];
        REQUIRE(priorBytes.length > 0 && priorBytes.length < VDT_NICE_STORE_LIMIT);
        NSString *liveInstance = instanceKey(target());
        REQUIRE([c->outcomes[liveInstance][@"state"] isEqual:@"applied"]);
        NSDictionary *cleanOutcome = c->outcomes[liveInstance];
        NSMutableDictionary *fat = [cleanOutcome mutableCopy];
        fat[@"observed"] = [NSMutableData dataWithLength:3 * 1024 * 1024];
        c->outcomes[liveInstance] = fat;
        NSDictionary *recordsBefore = plistSnapshot(c->records);
        NSDictionary *outcomesBefore = plistSnapshot(c->outcomes);
        NSDictionary *attemptsBefore = plistSnapshot(c->attemptStates);
        NSArray *attemptedBefore = plistSnapshot(setSnapshot(c->attempted));
        NSArray *goneBefore = plistSnapshot(setSnapshot(c->goneCleanupStarted));
        REQUIRE(recordsBefore && outcomesBefore && attemptsBefore && attemptedBefore && goneBefore);
        NSData *journalBefore = journalBytes();
        REQUIRE(journalBefore.length > 0 && journalBefore.length < VDT_NICE_STORE_LIMIT);
        int readsBefore = readCount, writesBefore = writeCount, storesBefore = fixtureStoreCalls;
        int notifyMark = statusNotifyCount;
        c->receiptDirty = YES;
        // Even the compact error envelope may fail to commit. A pre-write
        // failure must not clear dirty, notify, or leave a partial new receipt.
        statusWriteFail = 1;
        int envelopeWriteMark = statusWriteCalls;
        [c publish];
        REQUIRE(c->receiptDirty == YES && statusNotifyCount == notifyMark && statusWriteCalls == envelopeWriteMark + 1);
        REQUIRE([statusBytes() isEqual:priorBytes] && [journalBytes() isEqual:journalBefore]);
        statusWriteFail = 0;
        NSTimeInterval publishStart = NSDate.date.timeIntervalSince1970;
        [c publish];
        NSTimeInterval publishEnd = NSDate.date.timeIntervalSince1970;
        // Saving the degraded envelope IS a successful receipt write, so it
        // clears the dirty bit and posts exactly one change notification.
        REQUIRE(statusNotifyCount == notifyMark + 1 && c->receiptDirty == NO);
        NSDictionary *degradedReceipt = statusFile(c);
        NSData *degradedBytes = statusBytes();
        REQUIRE(degradedReceipt && degradedBytes.length < VDT_NICE_STORE_LIMIT && degradedBytes.length < 8192);
        REQUIRE(![degradedBytes isEqual:priorBytes]);
        REQUIRE([degradedReceipt[@"version"] isEqual:@1] && [degradedReceipt[@"boot"] isEqual:VDTNiceBootToken()]);
        REQUIRE([(degradedReceipt[@"bootSession"] ?: NSNull.null) isEqual:(priorSession ?: NSNull.null)]);
        REQUIRE(VDTNiceReceiptBootMatches(degradedReceipt));
        REQUIRE([degradedReceipt[@"statusError"] isEqual:@(EFBIG)] && [degradedReceipt[@"rules"] count] == 0);
        NSTimeInterval degradedAt = [degradedReceipt[@"updatedAt"] doubleValue];
        REQUIRE(degradedAt >= publishStart && degradedAt <= publishEnd);
        for (NSString *dropped in @[@"observed", @"checkedAt", @"oldestCheckedAt", @"recordCount",
            @"pendingRestoreCount", @"paused", @"restoreNonce", @"storeError"])
            REQUIRE(degradedReceipt[dropped] == nil);
        // The reader reports one global cache failure instead of the deleted
        // success row, and the envelope time is never a check time.
        NSDictionary *unavailable = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,5,@"degrade-a"));
        REQUIRE([unavailable[@"state"] isEqual:@"receipt-unavailable"] && [unavailable[@"error"] isEqual:@(EFBIG)]);
        REQUIRE([unavailable[@"receiptUpdatedAt"] doubleValue] == degradedAt);
        REQUIRE(unavailable[@"observed"] == nil && unavailable[@"checkedAt"] == nil &&
            unavailable[@"pid"] == nil && unavailable[@"original"] == nil);
        // Global means global: neither another settings revision nor another
        // rule may revive the old success row.
        REQUIRE([VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(NO,3,@"degrade-other"))[@"state"]
            isEqual:@"receipt-unavailable"]);
        REQUIRE([VDTNiceMatchingStatus(@"idle-worker", VDTConfigTypeDaemon, compactPrefs)[@"state"]
            isEqual:@"receipt-unavailable"]);
        REQUIRE([VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, @{})[@"state"] isEqual:@"receipt-unavailable"]);
        // Degrading the cache must not touch the kernel, the journal or any
        // in-memory recovery/attempt state.
        REQUIRE(readCount == readsBefore && writeCount == writesBefore && fixtureStoreCalls == storesBefore);
        REQUIRE([plistSnapshot(c->records) isEqual:recordsBefore] && c->records.count == 1);
        REQUIRE([plistSnapshot(c->outcomes) isEqual:outcomesBefore]);
        REQUIRE([plistSnapshot(c->attemptStates) isEqual:attemptsBefore]);
        REQUIRE([plistSnapshot(setSnapshot(c->attempted)) isEqual:attemptedBefore]);
        REQUIRE([plistSnapshot(setSnapshot(c->goneCleanupStarted)) isEqual:goneBefore]);
        REQUIRE([journalBytes() isEqual:journalBefore]);
        // The generic writer stays fail-closed: an oversized journal is refused
        // whole and keeps its previous bytes, so no record is lost. The filler is
        // only an argument here and is rejected before any write.
        NSDictionary *oversized = @{@"version": @1, @"boot": VDTNiceBootToken(),
            @"records": c->records, @"filler": [NSMutableData dataWithLength:3 * 1024 * 1024]};
        REQUIRE(writePlist(&c->store, VDT_NICE_JOURNAL, oversized) == EFBIG);
        REQUIRE([journalBytes() isEqual:journalBefore] && c->records.count == 1);
        // The same refusal holds for the status name through the generic writer:
        // only writeStatusReceipt is allowed to degrade.
        REQUIRE(writePlist(&c->store, VDT_NICE_STATUS, oversized) == EFBIG);
        REQUIRE([statusBytes() isEqual:degradedBytes]);
        // The journal that refused that write is still the recovery source.
        c->outcomes[liveInstance] = cleanOutcome;
        cycle(c, prefs(NO,5,@"degrade-b"));
        REQUIRE(niceNow == -1 && c->records.count == 0 && writeCount == writesBefore + 1);
        REQUIRE(statusFile(c)[@"statusError"] == nil);
        // writeStatusReceipt keeps the boot and the publication time of the
        // receipt it could not store, and no success-only fields.
        NSDictionary *crafted = @{@"version": @1, @"boot": @"fixture-boot-before-degrade", @"rules": @{},
            @"bootSession": @"00000000-0000-4000-8000-000000000001",
            @"updatedAt": @1234567.5, @"checkedAt": @999.0, @"recordCount": @3, @"paused": @NO,
            @"restoreNonce": @"fix", @"observed": @(-9), @"filler": [NSMutableData dataWithLength:3 * 1024 * 1024]};
        REQUIRE(writeStatusReceipt(&c->store, crafted) == 0);
        NSDictionary *envelope = statusFile(c);
        REQUIRE([envelope[@"version"] isEqual:@1] && [envelope[@"boot"] isEqual:@"fixture-boot-before-degrade"]);
        REQUIRE([envelope[@"bootSession"] isEqual:crafted[@"bootSession"]]);
        REQUIRE(!VDTNiceReceiptBootMatches(envelope));
        REQUIRE([envelope[@"statusError"] isEqual:@(EFBIG)] && [envelope[@"updatedAt"] isEqual:@1234567.5]);
        REQUIRE([envelope[@"rules"] isKindOfClass:NSDictionary.class] && [envelope[@"rules"] count] == 0);
        for (NSString *dropped in @[@"checkedAt", @"recordCount", @"paused", @"restoreNonce", @"observed", @"filler"])
            REQUIRE(envelope[dropped] == nil);
        REQUIRE(statusBytes().length < 8192);
        // Serialization or a pre-write disk failure must return non-zero instead
        // of faking a successful publication.
        NSData *envelopeBytes = statusBytes();
        REQUIRE(writeStatusReceipt(&c->store, @{@"version": @1, @"boot": VDTNiceBootToken(),
            @"updatedAt": @1.5, @"rules": @{}, @"illegal": [NSObject new]}) != 0);
        REQUIRE([statusBytes() isEqual:envelopeBytes]);
        statusWriteFail = 1;
        int failedStatusWrites = statusWriteCalls;
        REQUIRE(writeStatusReceipt(&c->store, @{@"version": @1, @"boot": VDTNiceBootToken(),
            @"updatedAt": @2.5, @"rules": @{}}) != 0);
        REQUIRE(statusWriteCalls == failedStatusWrites + 1 && [statusBytes() isEqual:envelopeBytes]);
        statusWriteFail = 0;
        // A failed publish keeps the dirty bit and posts nothing. The injection
        // fails before any IO, so the previous receipt is provably untouched;
        // this is a pre-write failure only, not a claim about every store error.
        clearFixture(); c = [VDTNiceCoordinator new]; cycle(c, prefs(YES,6,@"fail-a"));
        REQUIRE(niceNow == 6 && writeCount == 1);
        NSData *successBytes = statusBytes();
        NSDictionary *successRow = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,6,@"fail-a"));
        REQUIRE([successRow[@"state"] isEqual:@"applied"] && [successRow[@"observed"] isEqual:@6]);
        statusWriteFail = 1;
        int notifyFailMark = statusNotifyCount;
        c->receiptDirty = YES;
        [c publish];
        REQUIRE(c->receiptDirty == YES && statusNotifyCount == notifyFailMark && [statusBytes() isEqual:successBytes]);
        // Clearing the fault is enough: the same receipt is stored again and the
        // real applied result becomes visible.
        statusWriteFail = 0;
        [c publish];
        REQUIRE(c->receiptDirty == NO && statusNotifyCount == notifyFailMark + 1);
        NSDictionary *repaired = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,6,@"fail-a"));
        REQUIRE([repaired[@"state"] isEqual:@"applied"] && [repaired[@"observed"] isEqual:@6]);
        REQUIRE(repaired[@"statusError"] == nil && repaired[@"receiptUpdatedAt"] == nil);
        // Envelope acceptance is strict: any malformed field makes the whole
        // cache unreadable rather than reviving an older success row.
        NSDictionary *goodEnvelope = @{@"version": @1, @"boot": VDTNiceBootToken(), @"rules": @{},
            @"statusError": @(EFBIG), @"updatedAt": @(1234.5)};
        REQUIRE(writePlist(&c->store, VDT_NICE_STATUS, goodEnvelope) == 0);
        NSDictionary *envelopeRow = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, @{});
        REQUIRE([envelopeRow[@"state"] isEqual:@"receipt-unavailable"] &&
            [envelopeRow[@"error"] isEqual:@(EFBIG)] && [envelopeRow[@"receiptUpdatedAt"] isEqual:@1234.5]);
        REQUIRE(envelopeRow[@"observed"] == nil && envelopeRow[@"checkedAt"] == nil &&
            envelopeRow[@"pid"] == nil && envelopeRow[@"targetCount"] == nil);
        // A stale success row smuggled into an envelope must not be reused.
        NSMutableDictionary *smuggled = [goodEnvelope mutableCopy];
        smuggled[@"rules"] = @{liveKey: @{@"state": @"applied", @"observed": @5, @"checkedAt": @7.0}};
        REQUIRE(writePlist(&c->store, VDT_NICE_STATUS, smuggled) == 0);
        NSDictionary *smuggledRow = VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,5,@"strict-a"));
        REQUIRE([smuggledRow[@"state"] isEqual:@"receipt-unavailable"] && smuggledRow[@"observed"] == nil);
        NSMutableDictionary *variant = nil;
        NSMutableArray *malformed = [NSMutableArray array];
        variant = [goodEnvelope mutableCopy]; variant[@"statusError"] = @YES; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"statusError"] = @"27"; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"statusError"] = @[@(EFBIG)]; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"statusError"] = @27.5; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"statusError"] = @(EFBIG + 1); [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; [variant removeObjectForKey:@"statusError"]; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; [variant removeObjectForKey:@"updatedAt"]; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @0; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @(-1); [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @"1234.5"; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @YES; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @(NAN); [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @(INFINITY); [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"updatedAt"] = @253402300800.0; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"boot"] = @"previous-boot"; [malformed addObject:variant];
        variant = [goodEnvelope mutableCopy]; variant[@"version"] = @2; [malformed addObject:variant];
        for (NSDictionary *fixture in malformed) {
            REQUIRE(writePlist(&c->store, VDT_NICE_STATUS, fixture) == 0);
            REQUIRE(VDTNiceMatchingStatus(@"test-worker", VDTConfigTypeDaemon, prefs(YES,5,@"strict-a")) == nil);
        }
        [fm removeItemAtPath:testRoot error:nil];
        printf("nice Foundation integration: %u assertions passed (fake kernel)\n",assertions);
    }
    return 0;
}
