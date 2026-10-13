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
#import "../VDTNiceRuntime.mm"
#undef getpriority
#undef setpriority
#undef proc_pidinfo
#undef vdt_target_is_current

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
        [fm removeItemAtPath:testRoot error:nil];
        printf("nice Foundation integration: %u assertions passed (fake kernel)\n",assertions);
    }
    return 0;
}
