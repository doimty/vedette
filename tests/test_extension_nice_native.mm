// Production Foundation files + existing fake-kernel technique; no policy model.
#import "VDTNiceRuntime.h"
#import "VDTNiceShared.h"
#import "VDTResourceShared.h"
#import "VDTNiceStore.h"
#import "PrivateHeaders.h"
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
static NSString *testRoot;
extern "C" NSString *VDTTestJbroot(NSString *path) { return [testRoot stringByAppendingString:path]; }
static NSString *hostID = @"example.host", *extID = @"example.host.widget";
static NSString *hostPath, *extPath, *appExe, *extExe;
static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *kernel;
static int writes, reads, cpuCalls, cpuDispatches, posts, resourcePosts, writeError, readError;
static BOOL ignoreWrite;
static BOOL deferAfter;
static NSMutableArray *deferredTasks;
static NSTimeInterval retryTestNow;
static NSTimeInterval VDTTestRetryClock(id owner, SEL command) { (void)owner; (void)command; return retryTestNow; }
static long bootSeconds = 1000;
static unsigned assertions;
#define REQUIRE(...) do { ++assertions; if (!(__VA_ARGS__)) { fprintf(stderr, "ASSERTION FAILED: native line %d: %s\n", __LINE__, #__VA_ARGS__); abort(); } } while (0)
static NSMutableDictionary *process(int pid) { return kernel[@(pid)]; }
static int copyString(int pid, void *buffer, uint32_t size, NSString *key) {
    NSDictionary *p = process(pid);
    if (!p || [p[@"missing"] boolValue] || [p[@"unavailable"] boolValue]) { errno = p ? EPERM : ESRCH; return 0; }
    const char *text = [p[key] UTF8String];
    if (!text || strlen(text) + 1 > size) return 0;
    memcpy(buffer, text, strlen(text) + 1); return (int)strlen(text);
}
extern "C" int VDTTestGetPriority(int which, id_t pid) {
    (void)which; ++reads; errno = readError;
    return readError ? -1 : [process((int)pid)[@"nice"] intValue];
}
extern "C" int VDTTestSetPriority(int which, id_t pid, int value) {
    (void)which; ++writes; errno = writeError;
    if (writeError) return -1;
    if (!ignoreWrite) process((int)pid)[@"nice"] = @(value);
    return 0;
}
extern "C" int VDTTestPidPath(int pid, void *buf, uint32_t size) { return copyString(pid,buf,size,@"path"); }
extern "C" int VDTTestProcName(int pid, void *buf, uint32_t size) { return copyString(pid,buf,size,@"comm"); }
extern "C" int VDTTestPidInfo(int pid, int flavor, uint64_t arg, void *buf, int size) {
    (void)flavor; (void)arg; NSDictionary *p = process(pid);
    if (!p || [p[@"missing"] boolValue] || [p[@"unavailable"] boolValue]) { errno = p && ![p[@"missing"] boolValue] ? EPERM : ESRCH; return 0; }
    if (size != sizeof(struct vdt_proc_bsdinfo)) return 0;
    struct vdt_proc_bsdinfo info = {};
    info.pbi_pid = (uint32_t)pid; info.pbi_start_tvsec = [p[@"start"] unsignedLongLongValue]; info.pbi_start_tvusec = 1;
    memcpy(buf,&info,sizeof(info)); return sizeof(info);
}
extern "C" int VDTTestListPids(uint32_t type, uint32_t typeinfo, void *buf, int size) {
    (void)type; (void)typeinfo;
    NSArray *ids = [kernel.allKeys sortedArrayUsingSelector:@selector(compare:)];
    int bytes = (int)ids.count * (int)sizeof(pid_t);
    if (!buf) return bytes;
    int count = MIN(size / (int)sizeof(pid_t), (int)ids.count);
    for (int i=0;i<count;++i) ((pid_t *)buf)[i] = [ids[i] intValue];
    return count * (int)sizeof(pid_t);
}
extern "C" int VDTTestCPUOne(int pid) { (void)pid; ++cpuCalls; return 0; }
extern "C" int VDTTestCPUThree(int pid, int a, int b) { (void)a; (void)b; return VDTTestCPUOne(pid); }
extern "C" int VDTTestSysctl(const char *name, void *buf, size_t *size, void *input, size_t inputSize) {
    (void)input; (void)inputSize;
    if (!strcmp(name,"kern.osrelease")) {
        const char release[]="21.1.0";
        if (!buf || !size || *size < sizeof(release)) { errno=EINVAL; return -1; }
        memcpy(buf,release,sizeof(release)); *size=sizeof(release); return 0;
    }
    if (strcmp(name,"kern.boottime") || *size != sizeof(struct timeval)) { errno = EINVAL; return -1; }
    struct timeval boot = {}; boot.tv_sec = bootSeconds; memcpy(buf,&boot,sizeof(boot)); return 0;
}
extern "C" uint32_t VDTTestNotifyPost(const char *name) {
    // A resource status publication is not a nice write/retry side effect.
    // Keep every pre-existing nice/other notification assertion unchanged.
    if (name && !strcmp(name, VDT_RESOURCE_STATUS_NN)) ++resourcePosts;
    else ++posts;
    return 0;
}
extern "C" uint32_t VDTTestNotifyRegister(const char *name, int *token) { (void)name; *token = 1; return 0; }
extern "C" uint32_t VDTTestNotifySet(int token, uint64_t pid) { (void)token; (void)pid; return 0; }
extern "C" uint32_t VDTTestNotifyGet(int token, uint64_t *pid) { (void)token; *pid=0; return 0; }
extern "C" uint32_t VDTTestNotifyCancel(int token) { (void)token; return 0; }
extern "C" uint32_t VDTTestNotifyDispatch(const char *name, int *token, dispatch_queue_t queue, void (^block)(int)) {
    (void)name; (void)queue; (void)block; *token=1; return 0;
}
extern "C" void VDTTestCFPost(CFNotificationCenterRef center, CFStringRef name, const void *object, CFDictionaryRef info, Boolean now) {
    (void)center; (void)name; (void)object; (void)info; (void)now; ++posts;
}
extern "C" void VDTTestCFObserve(CFNotificationCenterRef center, const void *observer, CFNotificationCallback callback, CFStringRef name, const void *object, CFNotificationSuspensionBehavior behavior) {
    (void)center; (void)observer; (void)callback; (void)name; (void)object; (void)behavior;
}
extern "C" void VDTTestAsync(dispatch_queue_t queue, dispatch_block_t block) { (void)queue; block(); }
extern "C" void VDTTestAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when; (void)queue;
    if (deferAfter) [deferredTasks addObject:[block copy]]; else block();
}
// Only the private LaunchServices boundary is replaced. Identity metadata is
// read from the REAL fixture Info.plist; production BundleIdentity stays linked.
@implementation _LSQueryResult @end
@implementation LSResourceProxy @end
@implementation LSBundleProxy
- (NSURL *)bundleURL { return objc_getAssociatedObject(self, @selector(bundleURL)); }
- (NSString *)bundleIdentifier { return [NSDictionary dictionaryWithContentsOfFile:[self.bundleURL.path stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"]; }
- (NSString *)bundleExecutable { return @"Host"; }
- (NSURL *)bundleContainerURL { return self.bundleURL; }
- (NSURL *)dataContainerURL { return self.bundleURL; }
@end
@implementation LSApplicationProxy
+ (id)applicationProxyForBundleURL:(NSURL *)url {
    LSApplicationProxy *proxy = [self new]; objc_setAssociatedObject(proxy, @selector(bundleURL), url, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return proxy;
}
@end
#import "VDTNiceRuntime.mm"
// Observe the real CPU entry boundary even if its no-policy target causes no
// kernel call. The production implementation still executes unchanged.
static BOOL VDTFixtureCPUApplyTarget(NSDictionary *target) {
    ++cpuDispatches;
    return vdt_apply_target(target);
}
#define vdt_apply_target VDTFixtureCPUApplyTarget
#import "Vedette.fixture.mm"
#undef vdt_apply_target

static NSDictionary *metadata(void) {
    return @{@"CFBundleIdentifier":extID,@"CFBundleExecutable":@"Widget",@"NSExtension":@{@"NSExtensionPointIdentifier":@"com.apple.widgetkit-extension"}};
}
static void addProcess(int pid, NSString *path) {
    kernel[@(pid)] = [@{@"path":path,@"comm":path.lastPathComponent,@"start":@100,@"nice":@(-1)} mutableCopy];
}
static NSDictionary *niceRule(NSString *identifier, NSString *key, BOOL enabled, id value) {
    return @{key:identifier,VDT_NICE_ENABLED_KEY:@(enabled),VDT_NICE_VALUE_KEY:value,VDT_NICE_REVISION_KEY:@"rev-a"};
}
static NSDictionary *cpuHost(void) { return @{@"bundleIdentifier":hostID,@"enabled":@YES,@"percentage":@80,@"interval":@120,@"violationPolicy":@(VDTViolationPolicyThrottle)}; }
static NSDictionary *preferences(NSDictionary *own, NSDictionary *host) {
    NSMutableDictionary *p = [@{@"enabled":@YES,@"extensionConfigs":own ? @[own] : @[],@"appConfigs":host ? @[host] : @[],@"sentinel":@"preserved"} mutableCopy];
    p[@"memoryRules"] = @[@{@"extensionIdentifier":extID,@"schema":@1,@"enabled":@YES,@"active":@300,@"inactive":@200}];
    p[@"jetsamRules"] = @[@{@"extensionIdentifier":extID,@"schema":@1,@"enabled":@NO,@"priority":@3}];
    return p;
}
static void reset(void) {
    [[NSFileManager defaultManager] removeItemAtPath:VDTNiceStateDirectory() error:nil];
    kernel = [NSMutableDictionary dictionary]; addProcess(424242,extExe);
    writes=reads=cpuCalls=cpuDispatches=posts=resourcePosts=writeError=readError=0; ignoreWrite=NO; bootSeconds=1000;
    normalized_configs_snapshot=nil; normalized_resource_rules_snapshot=nil; normalized_nice_rules_snapshot=nil;
    [tracked_process_instances() removeAllObjects]; [managed_process_targets() removeAllObjects];
    launch_catch_up_scheduled=nice_refresh_scheduled=NO;
    invalidate_nice_retry_sync(); deferAfter = NO; deferredTasks = [NSMutableArray array];
    REQUIRE([metadata() writeToFile:[extPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
}
static NSArray *niceTargets(NSDictionary *p) { return vdt_nice_resolve_targets(p); }
static NSDictionary *extensionTarget(NSDictionary *p) {
    for (NSDictionary *t in niceTargets(p)) if ([t[VDTTargetPidKey] isEqual:@424242]) return t;
    return nil;
}
static void cycle(VDTNiceCoordinator *c, NSDictionary *p) {
    [c reload:p]; [c reconcile]; for (NSDictionary *t in niceTargets(p)) [c apply:t]; [c publish];
}
static NSDictionary *receipt(NSDictionary *p) { return VDTNiceMatchingStatusWithHost(extID,VDTConfigTypeExtension,hostID,p); }
static int extensionNice(void) { return [process(424242)[@"nice"] intValue]; }
static void savePrefs(NSDictionary *p) { REQUIRE([p writeToFile:PREFS_PATH atomically:YES]); }

int main(void) {
 @autoreleasepool {
    if (geteuid()!=0) { fputs("native tests require explicitly authorized root-owned temporary fixtures\n",stderr); return 77; }
    (void)&VDTFixtureCtor; // compiled production ctor; not injected/executed
    char root[] = "/tmp/vdt-extension-nice.XXXXXX";
    REQUIRE(mkdtemp(root)!=NULL); testRoot=@(root);
    NSFileManager *fm=NSFileManager.defaultManager;
    REQUIRE([fm createDirectoryAtPath:VDTTestJbroot(@"/var/tmp") withIntermediateDirectories:YES attributes:nil error:nil]);
    REQUIRE([fm createDirectoryAtPath:VDTTestJbroot(@"/var/mobile/Library/Preferences") withIntermediateDirectories:YES attributes:nil error:nil]);
    hostPath=[testRoot stringByAppendingPathComponent:@"Host.app"];
    extPath=[hostPath stringByAppendingPathComponent:@"PlugIns/Widget.appex"];
    appExe=[hostPath stringByAppendingPathComponent:@"Host"]; extExe=[extPath stringByAppendingPathComponent:@"Widget"];
    REQUIRE([fm createDirectoryAtPath:extPath withIntermediateDirectories:YES attributes:nil error:nil]);
    REQUIRE([[NSData data] writeToFile:extExe atomically:YES]); REQUIRE([[NSData data] writeToFile:appExe atomically:YES]);
    REQUIRE([@{@"CFBundleIdentifier":hostID,@"CFBundleExecutable":@"Host"} writeToFile:[hostPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    NSDictionary *own=niceRule(extID,@"extensionIdentifier",YES,@5);
    NSDictionary *host=niceRule(hostID,@"bundleIdentifier",YES,@9);
    NSDictionary *p=preferences(own,nil);
    reset(); VDTNiceCoordinator *c=[VDTNiceCoordinator new];
    NSDictionary *t=extensionTarget(p);
    REQUIRE(t && [t[VDTConfigTypeKey] isEqual:@(VDTConfigTypeExtension)]);
    REQUIRE([t[VDTTargetExecutablePathKey] isEqual:extExe]);
    REQUIRE([t[VDTTargetNiceSourceIdentifierKey] isEqual:extID]);
    REQUIRE(vdt_nice_targets_for_pid(424242,p).count==1);
    cycle(c,p); REQUIRE(c->loadError==0 && extensionNice()==5 && writes==1 && reads>=2 && cpuCalls==0);
    REQUIRE([c->records.allValues[0][@"target"][@"niceSourceIdentifier"] isEqual:extID]);
    REQUIRE([receipt(p)[@"state"] isEqual:@"applied"] && [receipt(p)[@"appliedCount"] isEqual:@1]);
    [c apply:t]; [c publish]; REQUIRE(writes==1);
    p=preferences(niceRule(extID,@"extensionIdentifier",NO,@5),nil);
    cycle(c,p); REQUIRE(extensionNice()==-1 && c->records.count==0 && writes==2);
    REQUIRE([receipt(p)[@"state"] isEqual:@"restored"]);

    // CPU disabled own record must not disable independent host nice inheritance.
    reset(); c=[VDTNiceCoordinator new];
    NSDictionary *disabledCPU=@{@"extensionIdentifier":extID,@"enabled":@NO,@"percentage":@30};
    p=preferences(disabledCPU,host); cycle(c,p);
    REQUIRE(extensionNice()==9 && writes==1);
    REQUIRE([c->records.allValues[0][@"target"][VDTConfigTypeKey] isEqual:@(VDTConfigTypeExtension)]);
    REQUIRE([c->records.allValues[0][@"target"][@"niceSourceType"] isEqual:@(VDTConfigTypeApp)]);
    REQUIRE([receipt(p)[@"inherited"] boolValue] && [receipt(p)[@"sourceIdentifier"] isEqual:hostID]);
    NSMutableDictionary *changedHost=[host mutableCopy]; changedHost[VDT_NICE_VALUE_KEY]=@11; changedHost[VDT_NICE_REVISION_KEY]=@"rev-b";
    NSDictionary *changed=preferences(disabledCPU,changedHost);
    REQUIRE(receipt(changed)==nil); cycle(c,changed); REQUIRE(extensionNice()==11 && writes==2 && receipt(changed)!=nil);
    p=preferences(niceRule(extID,@"extensionIdentifier",NO,@4),host); cycle(c,p);
    REQUIRE(extensionNice()==-1 && c->records.count==0 && ![receipt(p)[@"inherited"] boolValue]);
    for (id bad in @[@YES,@21,@1.5,@"junk",NSNull.null]) {
        p=preferences(niceRule(extID,@"extensionIdentifier",YES,bad),host);
        cycle(c,p); REQUIRE(extensionNice()==-1 && c->records.count==0 && receipt(p)!=nil && ![receipt(p)[@"inherited"] boolValue]);
        REQUIRE([receipt(p)[@"state"] isEqual:@"invalid"] && [receipt(p)[@"containingAppIdentifier"] isEqual:hostID]);
    }
    // Nice-only own row leaves the CPU host record and resource intents intact.
    reset(); c=[VDTNiceCoordinator new]; p=preferences(own,cpuHost());
    NSArray *cpuTargets=vdt_targets_for_pid(424242,vdt_configs_from_prefs(p),vdt_resource_rules_from_prefs(p));
    REQUIRE(cpuTargets.count==1 && [cpuTargets[0][VDTConfigPercentageKey] isEqual:@80]);
    REQUIRE([cpuTargets[0][VDTTargetNameKey] isEqual:hostID]);
    cycle(c,p); REQUIRE(extensionNice()==5 && cpuCalls==0);

    // Save + independent Follow use production Store/Shared, not a UI-only result.
    reset(); p=preferences(disabledCPU,host); savePrefs(p); NSError *error=nil;
    REQUIRE(VDTNiceSavePreference(extID,VDTConfigTypeExtension,VDT_NICE_ENABLED_KEY,@YES,&error));
    REQUIRE([getPrefs()[@"extensionConfigs"][0][VDT_NICE_ENABLED_KEY] isEqual:@YES]);
    REQUIRE([getPrefs()[@"extensionConfigs"][0][@"enabled"] isEqual:@NO]);
    REQUIRE(VDTNiceSavePreference(extID,VDTConfigTypeExtension,VDT_NICE_VALUE_KEY,@6,&error));
    c=[VDTNiceCoordinator new]; cycle(c,getPrefs()); REQUIRE(extensionNice()==6);
    NSMutableDictionary *saved=[getPrefs() mutableCopy];
    NSMutableDictionary *duplicate=[saved[@"extensionConfigs"][0] mutableCopy]; duplicate[@"unknown"]=@"keep";
    saved[@"extensionConfigs"]=@[saved[@"extensionConfigs"][0],duplicate]; savePrefs(saved);
    REQUIRE(VDTNiceRemoveIndependentRule(extID,VDTConfigTypeExtension,&error));
    NSDictionary *follow=getPrefs();
    REQUIRE([follow[@"memoryRules"] isEqual:saved[@"memoryRules"]] && [follow[@"jetsamRules"] isEqual:saved[@"jetsamRules"]]);
    REQUIRE([follow[@"appConfigs"] isEqual:saved[@"appConfigs"]]);
    REQUIRE([follow[@"extensionConfigs"] count]==2);
    for (NSDictionary *e in follow[@"extensionConfigs"]) {
        REQUIRE(e[VDT_NICE_ENABLED_KEY]==nil && e[VDT_NICE_VALUE_KEY]==nil && e[VDT_NICE_REVISION_KEY]==nil);
        REQUIRE([e[@"enabled"] isEqual:@NO] && [e[@"percentage"] isEqual:@30]);
    }
    REQUIRE([follow[@"extensionConfigs"][1][@"unknown"] isEqual:@"keep"]);
    cycle(c,follow); REQUIRE(extensionNice()==9 && [receipt(follow)[@"inherited"] boolValue]);
    // Source changes with an unchanged value must update durable identity, no setpriority.
    NSMutableDictionary *same=[own mutableCopy]; same[VDT_NICE_VALUE_KEY]=@9;
    p=preferences(same,host); int before=writes; cycle(c,p);
    REQUIRE(writes==before && [c->records.allValues[0][@"target"][@"niceSourceIdentifier"] isEqual:extID]);
    REQUIRE(![receipt(p)[@"inherited"] boolValue]);

    // Lifetime reuse, exact path and metadata changes must never restore another process.
    reset(); c=[VDTNiceCoordinator new]; p=preferences(own,nil); cycle(c,p);
    process(424242)[@"start"]=@999; process(424242)[@"nice"]=@17;
    cycle(c,@{}); REQUIRE(writes==1 && extensionNice()==17 && c->records.count==0);
    reset(); c=[VDTNiceCoordinator new]; cycle(c,p); process(424242)[@"path"]=[extExe stringByAppendingString:@"Helper"];
    cycle(c,@{}); REQUIRE(writes==1 && extensionNice()==5 && c->records.count==1);
    process(424242)[@"path"]=extExe; cycle(c,@{}); REQUIRE(extensionNice()==-1 && c->records.count==0);
    reset(); c=[VDTNiceCoordinator new]; cycle(c,p);
    REQUIRE([@{@"CFBundleIdentifier":extID,@"CFBundleExecutable":@"Widget"} writeToFile:[extPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    NSDictionary *fallback=preferences(nil,host); NSMutableDictionary *withDaemon=[fallback mutableCopy];
    withDaemon[@"daemonConfigs"]=@[niceRule(@"Widget",@"daemonName",YES,@13)];
    REQUIRE(niceTargets(withDaemon).count==0); cycle(c,@{}); REQUIRE(writes==1 && c->records.count==1);
    REQUIRE([metadata() writeToFile:[extPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]); cycle(c,@{}); REQUIRE(extensionNice()==-1);
    reset(); c=[VDTNiceCoordinator new]; cycle(c,p);
    REQUIRE([@{@"CFBundleIdentifier":@"another.host"} writeToFile:[hostPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    cycle(c,@{}); REQUIRE(writes==1 && c->records.count==1);
    REQUIRE([@{@"CFBundleIdentifier":hostID,@"CFBundleExecutable":@"Host"} writeToFile:[hostPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    cycle(c,@{}); REQUIRE(extensionNice()==-1 && c->records.count==0);

    // Restart reads baseline from real journal; boot mismatch invalidates stale baseline.
    reset(); c=[VDTNiceCoordinator new]; cycle(c,p);
    c=[VDTNiceCoordinator new]; cycle(c,preferences(niceRule(extID,@"extensionIdentifier",YES,@8),nil));
    REQUIRE(extensionNice()==8 && [c->records.allValues[0][@"record"][@"original"] isEqual:@(-1)]);
    cycle(c,@{}); REQUIRE(extensionNice()==-1);
    reset(); c=[VDTNiceCoordinator new]; cycle(c,p); bootSeconds=2000; process(424242)[@"nice"]=@17;
    c=[VDTNiceCoordinator new]; cycle(c,@{}); REQUIRE(c->records.count==0 && writes==1 && extensionNice()==17);

    // Legacy App/Daemon targets without source fields remain readable and restorable.
    for (NSNumber *type in @[@(VDTConfigTypeApp),@(VDTConfigTypeDaemon)]) {
        reset(); [kernel removeAllObjects]; BOOL app=type.unsignedIntegerValue==VDTConfigTypeApp;
        addProcess(424243,app ? appExe : @"/usr/libexec/test-worker");
        NSString *identifier=app ? hostID : @"test-worker";
        p=@{@"enabled":@YES,(app ? @"appConfigs" : @"daemonConfigs"):@[niceRule(identifier,app ? @"bundleIdentifier" : @"daemonName",YES,@4)]};
        c=[VDTNiceCoordinator new]; cycle(c,p); REQUIRE([process(424243)[@"nice"] isEqual:@4] && c->records.count==1);
        NSMutableDictionary *legacyRecords=[c->records mutableCopy]; NSString *key=legacyRecords.allKeys[0];
        NSMutableDictionary *entry=[legacyRecords[key] mutableCopy], *legacyTarget=[entry[@"target"] mutableCopy];
        for (NSString *field in @[@"niceSourceType",@"niceSourceIdentifier",@"niceSourceRevision"]) [legacyTarget removeObjectForKey:field];
        entry[@"target"]=legacyTarget; legacyRecords[key]=entry;
        REQUIRE(writePlist(&c->store,VDT_NICE_JOURNAL,@{@"version":@1,@"boot":VDTNiceBootToken(),@"records":legacyRecords})==0);
        c=[VDTNiceCoordinator new]; cycle(c,@{}); REQUIRE(c->loadError==0 && c->records.count==0 && [process(424243)[@"nice"] isEqual:@(-1)]);
    }

    // Same-generation automatic retry uses the REAL life callback, no CPU
    // dispatch, and an explicit fake monotonic clock instead of sleeping.
    reset(); p=preferences(own,nil); savePrefs(p); deferAfter=YES; retryTestNow=10;
    Method clockMethod=class_getInstanceMethod(VDTNiceCoordinator.class,@selector(retryClock));
    IMP realClock=method_setImplementation(clockMethod,(IMP)VDTTestRetryClock);
    readError=EAGAIN; reloadPrefsSync();
    REQUIRE(writes==0 && reads==1 && deferredTasks.count==1 && nice_retry_scheduled);
    readError=0; retryTestNow=10.5;
    dispatch_block_t retryBlock=[deferredTasks[0] copy]; [deferredTasks removeObjectAtIndex:0]; retryBlock();
    REQUIRE(extensionNice()==5 && writes==1 && cpuCalls==0 && cpuDispatches==0 && deferredTasks.count==0);
    REQUIRE(!nice_retry_scheduled && vdt_nice_next_retry_delay()<0);
    // Retire the REAL singleton's journal before reset removes its files.
    // Losing a live original-value record is correctly a fail-closed event;
    // a fixture reset must not masquerade as that production failure.
    savePrefs(@{}); reloadPrefsSync();
    REQUIRE(coordinator()->records.count==0 && extensionNice()==-1 && writes==2);
    // Old-generation delayed work cannot apply a rule after it was removed.
    reset(); savePrefs(p); deferAfter=YES; retryTestNow=20; readError=EIO; reloadPrefsSync();
    REQUIRE(deferredTasks.count==1); retryBlock=[deferredTasks[0] copy]; [deferredTasks removeObjectAtIndex:0];
    readError=0; savePrefs(@{}); reloadPrefsSync(); int beforeStaleReads=reads; retryTestNow=200; retryBlock();
    REQUIRE(writes==0 && reads==beforeStaleReads && extensionNice()==-1 && cpuDispatches==0);
    method_setImplementation(clockMethod,realClock); deferAfter=NO;

    // Actual production life hooks: no CPU config, retries, proc start/end,
    // pref/global-off and public soft-remove are all separate from CPU success.
    reset(); p=preferences(own,nil); savePrefs(p); reloadPrefsSync();
    REQUIRE(extensionNice()==5 && writes==1 && cpuCalls==0 && cpuDispatches==0);
    int published=posts, resourcePublished=resourcePosts;
    reconcile_unreported_processes_sync(); handle_reported_pid_sync(424242);
    REQUIRE(writes==1 && cpuCalls==0 && posts==published);
    REQUIRE(resourcePosts==resourcePublished+2); // two independent lifecycle receipts
    niceRefreshCallback(NULL,NULL,NULL,NULL,NULL); REQUIRE(writes==1 && cpuCalls==0);
    REQUIRE(resourcePosts==resourcePublished+2); // nice retry cannot republish resources
    REQUIRE(VDTNiceRemoveIndependentRule(extID,VDTConfigTypeExtension,&error)); reloadPrefsSync();
    REQUIRE(extensionNice()==-1 && cpuCalls==0);
    savePrefs(p); reloadPrefsSync(); REQUIRE(extensionNice()==5);
    process(424242)[@"missing"]=@YES; reconcile_unreported_processes_sync();
    REQUIRE(coordinator()->records.count==0); process(424242)[@"missing"]=@NO; process(424242)[@"start"]=@777; process(424242)[@"nice"]=@(-1);
    handle_reported_pid_sync(424242); REQUIRE(extensionNice()==5 && cpuCalls==0);
    NSMutableDictionary *globalOff=[p mutableCopy]; globalOff[@"enabled"]=@NO; savePrefs(globalOff);
    restoreAllMonitors(); REQUIRE(extensionNice()==-1 && cpuCalls==0 && coordinator()->records.count==0);
    // Protected inherited Preferences source must never be written.
    reset(); REQUIRE([@{@"CFBundleIdentifier":@"com.apple.Preferences"} writeToFile:[hostPath stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    p=preferences(nil,niceRule(@"com.apple.Preferences",@"bundleIdentifier",YES,@7)); c=[VDTNiceCoordinator new]; cycle(c,p);
    REQUIRE(writes==0 && extensionNice()==-1);
    REQUIRE([fm removeItemAtPath:testRoot error:nil]);
    printf("PASS: production Foundation extension nice integration: %u assertions (fake kernel, no device)\n",assertions);
 }
 return 0;
}
