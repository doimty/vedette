// Real production resolver + nice coordinator; ALL kernel APIs below are fake.
#import "../VDTProcessManager.h"
#import "../VDTNiceShared.h"
#import "../PrivateHeaders.h"
#import "../VDTSpringBoardIdentity.h"
#include <errno.h>
#include <sys/resource.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static const int MockPID=424242;
static const char *MockPath, *MockComm;
static uint64_t MockStart=100;
static int CpuCalls, NiceReads, NiceWrites, NiceValue, LsCalls;
static int LastCpuPercentage;
static NSString *TestRoot, *MockAppIdentifier;
static BOOL MockAlive=YES;
extern "C" NSString *VDTTestJbroot(NSString *path) { return [TestRoot stringByAppendingString:path]; }
static int mockPath(int pid, void *buffer, uint32_t size) {
    if (!MockAlive || pid!=MockPID || !MockPath || strlen(MockPath)+1>size) { errno=ESRCH;return 0; }
    strcpy((char *)buffer,MockPath);return (int)strlen(MockPath);
}
static int mockName(int pid, void *buffer, uint32_t size) {
    if (!MockAlive || pid!=MockPID || !MockComm || strlen(MockComm)+1>size) { errno=ESRCH;return 0; }
    strcpy((char *)buffer,MockComm);return (int)strlen(MockComm);
}
static int mockInfo(int pid,int flavor,uint64_t arg,void *buffer,int size) {
    (void)flavor;(void)arg;
    if (!MockAlive || pid!=MockPID) { errno=ESRCH;return 0; }
    if (size!=(int)sizeof(struct vdt_proc_bsdinfo)) { errno=EINVAL;return 0; }
    struct vdt_proc_bsdinfo info={};info.pbi_pid=MockPID;
    info.pbi_start_tvsec=MockStart;info.pbi_start_tvusec=1;
    memcpy(buffer,&info,sizeof(info));return sizeof(info);
}
static int mockList(uint32_t type,uint32_t ti,void *buffer,int size) {
    (void)type;(void)ti;
    if (!MockAlive)return 0;
    if (!buffer)return sizeof(int);
    if (size<(int)sizeof(int))return 0;
    *(int *)buffer=MockPID;return sizeof(int);
}
static int mockCpu(int pid) { if(pid!=MockPID)abort();++CpuCalls;return 0; }
static int mockThrottle(int pid,int action,int percent) { (void)action;LastCpuPercentage=percent;return mockCpu(pid); }
static int mockFatal(int pid,int percent,int interval) { (void)interval;LastCpuPercentage=percent;return mockCpu(pid); }
static int mockGet(int which,id_t pid) { if(which!=PRIO_PROCESS || pid!=MockPID)abort();++NiceReads;errno=0;return NiceValue; }
static int mockSet(int which,id_t pid,int value) { if(which!=PRIO_PROCESS || pid!=MockPID)abort();++NiceWrites;NiceValue=value;return 0; }

@interface VDTSpringBoardTestAppProxy : NSObject
@property (nonatomic,readonly) NSString *bundleIdentifier;
+ (id)applicationProxyForBundleURL:(NSURL *)url;
@end
@implementation VDTSpringBoardTestAppProxy
- (NSString *)bundleIdentifier { return MockAppIdentifier; }
+ (id)applicationProxyForBundleURL:(NSURL *)url { (void)url;++LsCalls;return MockAppIdentifier ? [self new] : nil; }
@end
static Class mockObjcGetClass(const char *name) {
    return strcmp(name,"LSApplicationProxy")==0 ? VDTSpringBoardTestAppProxy.class : objc_getClass(name);
}

#define objc_getClass mockObjcGetClass
#define proc_pidpath mockPath
#define proc_name mockName
#define proc_pidinfo mockInfo
#define proc_listpids mockList
#define proc_clear_cpulimits mockCpu
#define proc_disable_cpumon mockCpu
#define proc_set_cpumon_defaults mockCpu
#define proc_resume_cpumon mockCpu
#define proc_setcpu_percentage mockThrottle
#define proc_set_cpumon_params_fatal mockFatal
#define getpriority mockGet
#define setpriority mockSet
#ifndef VDT_RESOLVER_IMPLEMENTATION
#define VDT_RESOLVER_IMPLEMENTATION "../VDTProcessManager.mm"
#endif
#import VDT_RESOLVER_IMPLEMENTATION
#import "../VDTNiceRuntime.mm"
#undef objc_getClass
#undef proc_pidpath
#undef proc_name
#undef proc_pidinfo
#undef proc_listpids
#undef getpriority
#undef setpriority

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"SpringBoard native line %d: %s\n",__LINE__,#x);abort(); } } while (0)
static NSDictionary *rule(BOOL cpu,BOOL nice,int value) {
    return @{@"daemonName":@"SpringBoard",@"enabled":@(cpu),@"percentage":@80,@"interval":@120,
        @"violationPolicy":@(VDTViolationPolicyThrottle),VDT_NICE_ENABLED_KEY:@(nice),
        VDT_NICE_VALUE_KEY:@(value),VDT_NICE_REVISION_KEY:@"test"};
}
static NSDictionary *preferences(NSDictionary *entry) { return @{@"enabled":@YES,@"daemonConfigs":@[entry]}; }
static NSArray *resolve(NSDictionary *prefs) { return vdt_targets_for_pid(MockPID,vdt_configs_from_prefs(prefs)); }
static void resetKernel(void) {
    MockPath=VDT_SPRINGBOARD_EXECUTABLE;MockComm=VDT_SPRINGBOARD_RULE_NAME;MockAlive=YES;MockStart=100;
    NiceValue=-1;CpuCalls=NiceReads=NiceWrites=LsCalls=LastCpuPercentage=0;MockAppIdentifier=nil;
}
static void clearJournal(void) { [NSFileManager.defaultManager removeItemAtPath:VDTNiceStateDirectory() error:nil]; }
static void runNice(VDTNiceCoordinator *c,NSDictionary *prefs) {
    [c reload:prefs];[c reconcile];
    for(NSDictionary *target in resolve(prefs))[c apply:target];
    [c publish];
}
int main(void) {
    @autoreleasepool {
        if(geteuid()!=0) { fputs("SKIP: root needed for isolated test storage\n",stderr);return 77; }
        char dir[]="/tmp/vedette-springboard.XXXXXX";CHECK(mkdtemp(dir)!=NULL);TestRoot=@(dir);
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:VDTTestJbroot(@"/var/tmp") withIntermediateDirectories:YES attributes:nil error:nil]);
        resetKernel();
        NSDictionary *niceOnly=preferences(rule(NO,YES,5));
        CHECK(resolve(@{}).count==0);
        NSArray *targets=resolve(niceOnly);CHECK(targets.count==1);NSDictionary *target=targets[0];
        CHECK([target[VDTConfigTypeKey] isEqual:@(VDTConfigTypeDaemon)]);
        CHECK([target[VDTTargetNameKey] isEqual:@"SpringBoard"]);
        CHECK([target[VDTTargetExecutablePathKey] isEqual:@VDT_SPRINGBOARD_EXECUTABLE]);
        CHECK([target[VDTConfigPolicyKey] isEqual:@(VDTViolationPolicyNone)]);
        CHECK([target[VDTConfigPercentageKey] isEqual:@0]);
        CHECK(LsCalls==0); // It works even when no LaunchServices App proxy exists.
        CHECK(vdt_resolve_targets(vdt_configs_from_prefs(niceOnly)).count==1);
        CHECK(vdt_target_is_current(target));
        VDTNiceCoordinator *nice=[VDTNiceCoordinator new];runNice(nice,niceOnly);
        CHECK(NiceValue==5 && NiceWrites==1 && CpuCalls==0);
        runNice(nice,preferences(rule(NO,YES,10)));CHECK(NiceValue==10 && NiceWrites==2 && CpuCalls==0);
        runNice(nice,preferences(rule(NO,NO,10)));CHECK(NiceValue==-1 && nice->records.count==0 && CpuCalls==0);
        runNice(nice,niceOnly);CHECK(NiceValue==5);
        runNice(nice,@{});CHECK(NiceValue==-1 && nice->records.count==0); // Deleting rule still restores.
        runNice(nice,niceOnly);
        NSMutableDictionary *disabled=[niceOnly mutableCopy];disabled[@"enabled"]=@NO;
        runNice(nice,disabled);CHECK(NiceValue==-1 && nice->records.count==0);
        // CPU-only stays on the existing transition path; nice remains untouched.
        clearJournal();resetKernel();nice=[VDTNiceCoordinator new];
        NSDictionary *cpuOnly=preferences(rule(YES,NO,5));target=resolve(cpuOnly).firstObject;
        CHECK(target!=nil && vdt_apply_target(target));CHECK(CpuCalls==2 && LastCpuPercentage==80);
        runNice(nice,cpuOnly);CHECK(NiceReads==0 && NiceWrites==0 && NiceValue==-1);
        target=resolve(preferences(rule(NO,NO,5))).firstObject;CHECK(vdt_apply_target(target));CHECK(CpuCalls==6);
        // New default row has no enabled fields and makes no implicit CPU/nice claim.
        target=resolve(preferences(@{@"daemonName":@"SpringBoard"})).firstObject;
        CHECK(target!=nil && [target[VDTConfigPolicyKey] isEqual:@(VDTViolationPolicyNone)]);
        CHECK(![VDTNiceRulesFromPrefs(preferences(@{@"daemonName":@"SpringBoard"}))[@"1:SpringBoard"][@"enabled"] boolValue]);

        resetKernel();
        const char *badPaths[]={NULL,"/usr/libexec/SpringBoard","/Applications/Fake.app/SpringBoard",
            "/System/Library/CoreServices/SpringBoard.app/SpringBoardHelper",
            "/var/jb/System/Library/CoreServices/SpringBoard.app/SpringBoard",
            "/System/Library/CoreServices/SpringBoard.app/SpringBoard/"};
        for(unsigned i=0;i<sizeof(badPaths)/sizeof(badPaths[0]);++i) { MockPath=badPaths[i];CHECK(resolve(niceOnly).count==0); }
        MockPath="/Applications/Other.app/worker";MockComm="worker";
        NSDictionary *otherDaemon=preferences(@{@"daemonName":@"worker",@"enabled":@YES});
        CHECK(resolve(otherDaemon).count==0); // No broad .app -> daemon relaxation.
        MockAppIdentifier=@"com.test.other";
        NSDictionary *otherApp=@{@"appConfigs":@[@{@"bundleIdentifier":@"com.test.other",@"enabled":@YES}]};
        CHECK(resolve(otherApp).count==1 && [resolve(otherApp)[0][VDTConfigTypeKey] isEqual:@(VDTConfigTypeApp)]);
        MockPath="/usr/libexec/worker";MockComm="worker";MockAppIdentifier=nil;
        CHECK(resolve(otherDaemon).count==1 && [resolve(otherDaemon)[0][VDTTargetNameKey] isEqual:@"worker"]);
        MockPath=NULL;CHECK(resolve(otherDaemon).count==1); // Generic fallback unchanged.

        resetKernel();MockAppIdentifier=@"com.apple.springboard";
        NSDictionary *appSB=@{@"bundleIdentifier":@"com.apple.springboard",@"enabled":@YES};
        NSDictionary *both=@{@"appConfigs":@[appSB],@"daemonConfigs":@[rule(NO,NO,0)]};
        target=resolve(both).firstObject;CHECK(target!=nil);
        CHECK([target[VDTConfigTypeKey] isEqual:@(VDTConfigTypeDaemon)] && [target[VDTConfigPolicyKey] isEqual:@0]);
        CHECK(LsCalls==0); // Explicit disabled daemon entry cannot be overridden by App rule.
        CHECK([resolve(@{@"appConfigs":@[appSB]}).firstObject[VDTConfigTypeKey] isEqual:@(VDTConfigTypeApp)]);
        NSDictionary *duplicates=@{@"daemonConfigs":@[rule(NO,NO,0),rule(YES,YES,5)]};
        CHECK([resolve(duplicates).firstObject[VDTConfigPolicyKey] isEqual:@0]);
        CHECK(![VDTNiceRulesFromPrefs(duplicates)[@"1:SpringBoard"][@"enabled"] boolValue]);

        // Existing fresh PID/path checks still reject a target changed after resolve.
        resetKernel();target=resolve(cpuOnly).firstObject;MockStart=101;
        CHECK(!vdt_target_is_current(target));CHECK(!vdt_apply_target(target) && CpuCalls==0);
        resetKernel();target=resolve(cpuOnly).firstObject;MockPath="/usr/libexec/SpringBoard";
        CHECK(!vdt_target_is_current(target));CHECK(!vdt_apply_target(target) && CpuCalls==0);
        resetKernel();target=resolve(cpuOnly).firstObject;MockPath=NULL;
        CHECK(!vdt_target_is_current(target));CHECK(!vdt_apply_target(target) && CpuCalls==0);

        clearJournal();resetKernel();nice=[VDTNiceCoordinator new];runNice(nice,niceOnly);
        CHECK(nice->records.count==1 && NiceValue==5);int writes=NiceWrites;
        MockPath="/usr/libexec/SpringBoard";runNice(nice,@{});
        CHECK(nice->records.count==1 && NiceWrites==writes); // Same PID, unavailable identity is not Gone.
        MockPath=VDT_SPRINGBOARD_EXECUTABLE;runNice(nice,@{});
        CHECK(nice->records.count==0 && NiceValue==-1);
        runNice(nice,niceOnly);writes=NiceWrites;MockStart=101;runNice(nice,@{});
        CHECK(nice->records.count==0 && NiceWrites==writes); // Reused PID is never restored.
        CHECK([NSFileManager.defaultManager removeItemAtPath:TestRoot error:nil]);
        printf("SpringBoard production resolver/nice integration: %u checks passed (fake kernel)\n",checks);
    }
    return 0;
}
