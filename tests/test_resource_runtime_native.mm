// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
// Real production coordinator + atomic file store, fake policy kernel only.
#import "../VDTResourceRuntime.h"
#import "../VDTResourceShared.h"
#import "../VDTResourceSystemBackend.h"
#import "../VDTNiceShared.h"
#import "../VDTNiceStore.h"
#import "../VDTBundleIdentity.h"
#include <sys/sysctl.h>
#include <notify.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
NSString *const VDTConfigIdentifierKey=@"identifier", *const VDTConfigTypeKey=@"type";
NSString *const VDTConfigPercentageKey=@"percentage", *const VDTConfigIntervalKey=@"interval", *const VDTConfigPolicyKey=@"violationPolicy", *const VDTConfigEnabledKey=@"enabled";
NSString *const VDTTargetPidKey=@"pid", *const VDTTargetNameKey=@"name", *const VDTTargetExecutablePathKey=@"executablePath", *const VDTTargetProcCommKey=@"procComm";
NSString *const VDTTargetStartSecondsKey=@"startSeconds", *const VDTTargetStartMicrosecondsKey=@"startMicroseconds";
NSString *const VDTTargetMemoryRuleKey=@"memoryRule", *const VDTTargetJetsamRuleKey=@"jetsamRule";
static NSString *testRoot;
NSString *VDTTestJbroot(NSString *path) { return [testRoot stringByAppendingString:path]; }
static VDTMemlimitPair kernelPair;
static int32_t kernelPriority;
static VDTProcessInstanceToken kernelToken={100,20};
static BOOL alive=YES, supportedSystem=YES, failMemory=NO, failAfterWriteRead=NO, coercePriority=NO;
static BOOL driftMemoryAfterObserve=NO, driftPriorityAfterObserve=NO;
static const char *fixtureRelease="21.1.0";
static unsigned writes, memoryWrites, priorityWrites, failCommit;
static int fixtureWrite(VDTNiceStore *store,const char *name,const void *bytes,size_t length) {
    if (!strcmp(name,VDT_NICE_JOURNAL) && failCommit && --failCommit==0) return EIO;
    return VDTNiceStoreWrite(store,name,bytes,length);
}
static int fixtureVersion(const char *name,void *out,size_t *length,void *newp,size_t newlen) {
    (void)newp; (void)newlen; assert(!strcmp(name,"kern.osrelease"));
    const char *release=fixtureRelease; if (*length<strlen(release)+1) return -1;
    memcpy(out,release,strlen(release)+1); *length=strlen(release)+1; return 0;
}
static int fixtureProc(int pid,int flavor,uint64_t arg,void *out,int length) {
    (void)arg; assert(flavor==VDT_PROC_PIDTBSDINFO && length==sizeof(struct vdt_proc_bsdinfo));
    if (!alive) { errno=ESRCH; return 0; }
    struct vdt_proc_bsdinfo info={}; info.pbi_pid=pid;
    info.pbi_start_tvsec=kernelToken.seconds; info.pbi_start_tvusec=kernelToken.microseconds;
    memcpy(out,&info,sizeof(info)); return sizeof(info);
}
BOOL vdt_target_is_current(NSDictionary *target) {
    return alive && [target[VDTTargetStartSecondsKey] unsignedLongLongValue]==kernelToken.seconds &&
        [target[VDTTargetStartMicrosecondsKey] unsignedLongLongValue]==kernelToken.microseconds;
}
static bool fakeToken(void *context,pid_t pid,VDTProcessInstanceToken *out) {
    (void)pid; VDTResourceSystemContext *c=(VDTResourceSystemContext *)context;
    if (!vdt_target_is_current(c->target)) return false; *out=kernelToken; return true;
}
static bool getMemory(void *context,pid_t pid,VDTMemlimitPair *out) {
    (void)context; (void)pid; if (failAfterWriteRead && writes) { errno=EIO; return false; }
    *out=kernelPair;
    if (driftMemoryAfterObserve) { kernelPair=(VDTMemlimitPair){444,1,555,1}; driftMemoryAfterObserve=NO; }
    return true;
}
static bool setMemory(void *context,pid_t pid,const VDTMemlimitPair *pair) {
    (void)context; (void)pid; if (failMemory) { errno=EIO; return false; }
    ++writes; ++memoryWrites; kernelPair=*pair; return true;
}
static bool getPriority(void *context,pid_t pid,VDTJetsamObservation *out) {
    (void)context; (void)pid; *out=(VDTJetsamObservation){kernelPriority};
    if (driftPriorityAfterObserve) { kernelPriority=7; driftPriorityAfterObserve=NO; }
    return true;
}
static bool setPriority(void *context,pid_t pid,int32_t band) {
    (void)context; (void)pid; ++writes; ++priorityWrites; kernelPriority=coercePriority?18:band; return true;
}
VDTApplyCapabilities VDTResourceSystemCapabilities(void) {
    bool on=supportedSystem; return (VDTApplyCapabilities){on,on,on,on};
}
const VDTResourceBackend *VDTResourceSystemBackend(void) {
    static const VDTResourceBackend b={"fake kernel",getMemory,setMemory,getPriority,setPriority,fakeToken}; return &b;
}
#define VDTNiceStoreWrite fixtureWrite
#define proc_pidinfo fixtureProc
#define sysctlbyname fixtureVersion
#ifndef VDT_RESOURCE_RUNTIME_FILE
#define VDT_RESOURCE_RUNTIME_FILE "../VDTResourceRuntime.mm"
#endif
#include VDT_RESOURCE_RUNTIME_FILE
#undef VDTNiceStoreWrite
#undef proc_pidinfo
#undef sysctlbyname
static NSDictionary *target(void) {
    return @{VDTTargetPidKey:@42,VDTConfigTypeKey:@(VDTConfigTypeDaemon),VDTTargetNameKey:@"fixture-daemon",
        VDTTargetExecutablePathKey:@"/usr/bin/fixture-daemon",VDTTargetProcCommKey:@"fixture-daemon",
        VDTTargetStartSecondsKey:@100,VDTTargetStartMicrosecondsKey:@20};
}
static NSDictionary *prefs(BOOL enabled) { return @{@"enabled":@(enabled)}; }
static VDTMemoryRule memory(int32_t a,int32_t i) {
    VDTMemoryRuleInput input={VDTPolicyRecordEnabled,{VDTPolicyInputInteger,1},{VDTPolicyInputInteger,a},{VDTPolicyInputInteger,i}};
    return VDTParseMemoryRule(&input);
}
static VDTJetsamRule priorityForMajor(int32_t value, int32_t major) {
    VDTJetsamRuleInput input={}; input.state=VDTPolicyRecordEnabled; input.schema=(VDTPolicyInteger){VDTPolicyInputInteger,1};
    input.mode=VDTJetsamModeRaw; input.rawBand=(VDTPolicyInteger){VDTPolicyInputInteger,value}; input.rawSourceDarwinMajor=(VDTPolicyInteger){VDTPolicyInputInteger,major};
    return VDTParseJetsamRule(&input);
}
static VDTJetsamRule priority(int32_t value) { return priorityForMajor(value,21); }
static void restart(void) {
    resourceLoaded=NO; resourceRecords=nil; resourceRows=nil; resourceBoot=nil; resourceStoreError=0; resourceControlError=0;
    resourceAttempts=nil; resourceDue=nil; resourceRestoreNonce=nil; resourcePaused=NO; resourceRowsByInstance=nil; resourceDarwin=0;
}
static void reset(void) {
    [NSFileManager.defaultManager removeItemAtPath:VDTResourceStateDirectory() error:nil]; restart();
    kernelPair=(VDTMemlimitPair){2048,0,2048,0}; kernelPriority=18; kernelToken=(VDTProcessInstanceToken){100,20};
    alive=YES; supportedSystem=YES; failMemory=NO; failAfterWriteRead=NO; coercePriority=NO;
    driftMemoryAfterObserve=driftPriorityAfterObserve=NO;
    writes=memoryWrites=priorityWrites=failCommit=0; fixtureRelease="21.1.0";
}
int main(void) {
    @autoreleasepool {
        if (geteuid()!=0) { puts("ERROR requires a root-owned isolated store"); return 1; }
        NSString *parent = @(getenv("VDT_RESOURCE_RUNTIME_TEST_ROOT") ?: "/tmp");
        char *directory = strdup([parent stringByAppendingPathComponent:@"runtime.XXXXXX"].fileSystemRepresentation);
        assert(directory && mkdtemp(directory)); testRoot=@(directory); free(directory);
        assert([NSFileManager.defaultManager createDirectoryAtPath:[testRoot stringByAppendingString:@"/var/tmp"]
            withIntermediateDirectories:YES attributes:nil error:nil]);
        NSDictionary *t=target(); VDTMemoryRule m=memory(64,128), changed=memory(96,192);
        VDTJetsamRule p=priority(13), changedPriority=priority(17), coerced=priority(19);
        reset(); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&m,&p) && writes==2 && kernelPair.active==64 && kernelPriority==13); // enabled rules apply without a separate opt-in
        reset(); vdt_resource_reload(@{@"enabled":@YES,@"resourceWriteEnabled":@NO});
        assert(vdt_resource_apply(t,&m,&p) && writes==2); // a stale legacy opt-out key is ignored
        reset(); vdt_resource_reload(prefs(NO));
        assert(vdt_resource_apply(t,&m,&p) && writes==0); // main switch off writes nothing
        reset(); vdt_resource_reload(prefs(YES));
        for (unsigned i=0;i<2048;i++) resourceRecords[[NSString stringWithFormat:@"fixture-limit-%u",i]]=@{@"target":t};
        assert(!vdt_resource_apply(t,&m,NULL) && writes==0 && !resourceStoreError);
        // Keep the no-SET-before-durable-WAL failure first so its mutation is
        // killed by the intended authority assertion, not a later commit case.
        reset(); vdt_resource_reload(prefs(YES)); failCommit=1;
        assert(!vdt_resource_apply(t,&m,NULL) && writes==0 && resourceStoreError==EIO);
        reset(); vdt_resource_reload(prefs(YES)); failCommit=1;
        assert(!vdt_resource_apply(t,NULL,&p) && writes==0 && priorityWrites==0 && resourceStoreError==EIO);
        reset(); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&m,NULL) && writes==1 && kernelPair.active==64);
        assert(vdt_resource_apply(t,&changed,NULL) && writes==2 && kernelPair.active==96);
        assert([resourceRecords[resourceInstance(t)][@"memory"][@"original"][0] isEqual:@2048]);
        vdt_resource_reload(prefs(NO)); // global off still restores
        assert(vdt_resource_apply(t,&changed,NULL) && writes==3 && kernelPair.active==2048 && resourceRecords.count==0);
        reset(); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&m,NULL)); restart(); vdt_resource_reload(prefs(NO));
        assert(vdt_resource_apply(t,&m,NULL) && kernelPair.active==2048 && resourceRecords.count==0);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        VDTMemoryRule broken=m; broken.state=VDTPolicyRecordInvalid; broken.parseStatus=VDTPolicyParseInvalidRecord;
        vdt_resource_reload(prefs(NO));
        assert(vdt_resource_apply(t,&broken,NULL) && kernelPair.active==2048 && resourceRecords.count==0);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        failCommit=2;
        assert(!vdt_resource_apply(t,NULL,NULL) && resourceRecords.count==0 && resourceStoreError==EIO);
        vdt_resource_reload(prefs(NO));
        assert(vdt_resource_apply(t,NULL,NULL) && resourceRecords.count==0 && !resourceStoreError && kernelPair.active==2048);
        reset(); vdt_resource_reload(prefs(YES)); failCommit=2;
        assert(!vdt_resource_apply(t,&m,NULL) && writes==1 && resourceStoreError==EIO);
        restart(); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&m,NULL) && writes==1); // pending WAL recovered without repeat SET
        assert(vdt_resource_apply(t,NULL,NULL) && kernelPair.active==2048 && resourceRecords.count==0);
        reset(); vdt_resource_reload(prefs(YES)); failAfterWriteRead=YES;
        assert(!vdt_resource_apply(t,&m,NULL) && writes==1 && resourceRecords.count==1);
        failAfterWriteRead=NO; restart(); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&m,NULL) && writes==1);
        failAfterWriteRead=YES;
        assert(!vdt_resource_apply(t,NULL,NULL) && resourceRecords.count==1);
        failAfterWriteRead=NO;
        for (NSString *key in resourceDue.allKeys) resourceDue[key]=@0;
        assert(vdt_resource_apply(t,NULL,NULL) && resourceRecords.count==0 && kernelPair.active==2048);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,&p));
        kernelPair=(VDTMemlimitPair){333,1,333,1}; kernelPriority=5;
        // Both the coordinator GET and the executor GET see independent drift.
        driftMemoryAfterObserve=driftPriorityAfterObserve=YES;
        assert(vdt_resource_apply(t,&m,&p) && memoryWrites==2 && priorityWrites==2 && kernelPair.active==64 && kernelPair.inactive==128 && kernelPriority==13);
        assert(!driftMemoryAfterObserve && !driftPriorityAfterObserve);
        kernelPair=(VDTMemlimitPair){777,1,888,1}; kernelPriority=6;
        assert(vdt_resource_apply(t,&changed,&changedPriority) && memoryWrites==3 && priorityWrites==3 && kernelPair.active==96 && kernelPair.inactive==192 && kernelPriority==17);
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"original"] isEqual:@[@2048,@0,@2048,@0]]));
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"original"] isEqual:@18]);
        restart(); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&changed,&changedPriority) && writes==6 && !resourceStoreError);
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"original"] isEqual:@[@2048,@0,@2048,@0]]));
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"original"] isEqual:@18]);
        kernelPair=(VDTMemlimitPair){333,1,333,1}; kernelPriority=5;
        assert(!vdt_resource_apply(t,NULL,NULL) && writes==6 && resourceRecords.count==1 && kernelPair.active==333 && kernelPriority==5);
        assert(memoryWrites==3 && priorityWrites==3);
        NSString *conflictKey = VDTNiceRuleKey((VDTConfigType)[t[VDTConfigTypeKey] unsignedIntegerValue], t[VDTTargetNameKey]);
        NSDictionary *conflictRow = resourceRows[conflictKey];
        assert(conflictRow && [conflictRow[@"instanceCount"] unsignedIntegerValue] == 1);
        assert(([conflictRow[@"memory"] isEqual:@"conflict"] &&
            [conflictRow[@"memoryObserved"] isEqual:@[@333,@1,@333,@1]]));
        assert([conflictRow[@"memoryEvidence"] isEqual:@"read-before-conflict"] && conflictRow[@"memoryObservedAt"]);
        assert([conflictRow[@"priority"] isEqual:@"conflict"] && [conflictRow[@"priorityObserved"] isEqual:@5]);
        assert([conflictRow[@"priorityEvidence"] isEqual:@"read-before-conflict"] && conflictRow[@"priorityObservedAt"]);
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"original"] isEqual:@[@2048,@0,@2048,@0]]));
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"original"] isEqual:@18]);
        // A later APPLY can recover a restore conflict; a subsequent restore
        // still uses the pre-management values, never either drifted reading.
        assert(vdt_resource_apply(t,&changed,&changedPriority) && writes==8 && kernelPair.active==96 && kernelPriority==17);
        assert(vdt_resource_apply(t,NULL,NULL) && writes==10 && kernelPair.active==2048 && kernelPriority==18 && resourceRecords.count==0);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,&p));
        kernelPair=(VDTMemlimitPair){96,1,192,1}; kernelPriority=17;
        assert(vdt_resource_apply(t,&changed,&changedPriority) && writes==2); // new target already observed, no SET
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"last"] isEqual:@[@96,@1,@192,@1]]));
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"last"] isEqual:@17]);
        assert(vdt_resource_apply(t,NULL,NULL) && writes==4 && kernelPair.active==2048 && kernelPriority==18 && resourceRecords.count==0);
        // Drift and a new rule do not bypass WAL or replace the first original.
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        kernelPair=(VDTMemlimitPair){333,1,333,1}; failCommit=1;
        assert(!vdt_resource_apply(t,&changed,NULL) && writes==1 && memoryWrites==1 && resourceStoreError==EIO);
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"original"] isEqual:@[@2048,@0,@2048,@0]]));
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"last"] isEqual:@[@64,@1,@128,@1]]));
        vdt_resource_reload(prefs(NO));
        assert(!vdt_resource_apply(t,NULL,NULL) && writes==1 && kernelPair.active==333 && resourceRecords.count==1);
        assert([resourceRecords[resourceInstance(t)][@"memory"][@"phase"] isEqual:@"conflict"]);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,NULL,&p));
        kernelPriority=5; failCommit=1;
        assert(!vdt_resource_apply(t,NULL,&changedPriority) && writes==1 && priorityWrites==1 && resourceStoreError==EIO);
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"original"] isEqual:@18]);
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"last"] isEqual:@13]);
        vdt_resource_reload(prefs(NO));
        assert(!vdt_resource_apply(t,NULL,NULL) && writes==1 && kernelPriority==5 && resourceRecords.count==1);
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"phase"] isEqual:@"conflict"]);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        kernelPair=(VDTMemlimitPair){333,1,333,1}; failMemory=YES;
        assert(!vdt_resource_apply(t,&changed,NULL) && writes==1);
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"last"] isEqual:@[@64,@1,@128,@1]]));
        failMemory=NO; vdt_resource_reload(prefs(NO));
        assert(!vdt_resource_apply(t,NULL,NULL) && writes==1 && kernelPair.active==333 && resourceRecords.count==1);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        kernelToken=(VDTProcessInstanceToken){101,20};
        assert(vdt_resource_apply(t,NULL,NULL) && writes==1 && resourceRecords.count==0); // gone, zero write to reused PID
        reset(); supportedSystem=NO; vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,&m,&p) && writes==0);
        const int32_t modernMajors[]={22,25,26,30};
        const char *modernReleases[]={"22.1.0","25.0.0","26.2.0","30.9.0"};
        for (unsigned i=0;i<sizeof(modernMajors)/sizeof(modernMajors[0]);i++) {
            reset(); fixtureRelease=modernReleases[i]; kernelPriority=180;
            VDTJetsamRule modern=priorityForMajor(150,modernMajors[i]);
            VDTJetsamRule highest=priorityForMajor(210,modernMajors[i]);
            vdt_resource_reload(prefs(YES));
            assert(vdt_resource_apply(t,NULL,&modern) && priorityWrites==1 && kernelPriority==150);
            restart(); vdt_resource_reload(prefs(YES));
            assert(!resourceStoreError && resourceRecords.count==1);
            assert([resourceRecords[resourceInstance(t)][@"priority"][@"original"] isEqual:@180]);
            assert(vdt_resource_apply(t,&m,&highest) && kernelPriority==210 && kernelPair.active==64);
            unsigned before=writes; restart(); vdt_resource_reload(prefs(YES));
            assert(vdt_resource_apply(t,&m,&highest) && writes==before && !resourceStoreError);
            vdt_resource_reload(prefs(NO));
            assert(vdt_resource_apply(t,NULL,NULL) && kernelPriority==180 && kernelPair.active==2048 && resourceRecords.count==0);
        }
        // A same-boot record with different numeric semantics is not silently
        // reinterpreted; a real OS upgrade changes boot and follows old-boot discard.
        reset(); fixtureRelease="22.1.0"; kernelPriority=180;
        VDTJetsamRule modern=priorityForMajor(150,22); vdt_resource_reload(prefs(YES));
        assert(vdt_resource_apply(t,NULL,&modern)); resourceDarwin=21; assert(resourcePersist()); restart();
        vdt_resource_reload(prefs(YES));
        assert(!vdt_resource_apply(t,NULL,NULL) && resourceStoreError==EINVAL && priorityWrites==1);
        reset(); vdt_resource_reload(prefs(YES)); coercePriority=YES;
        assert(!vdt_resource_apply(t,NULL,&coerced) && priorityWrites==1);
        restart(); vdt_resource_reload(prefs(YES));
        assert(!vdt_resource_apply(t,NULL,&coerced) && priorityWrites==1); // no repeated coercion writes
        kernelPriority=5; restart(); vdt_resource_reload(prefs(YES));
        assert(!vdt_resource_apply(t,NULL,&coerced) && priorityWrites==1 && kernelPriority==5);
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"phase"] isEqual:@"unverified"]);
        assert([resourceRecords[resourceInstance(t)][@"priority"][@"original"] isEqual:@18]);
        reset(); vdt_resource_reload(prefs(YES)); failAfterWriteRead=YES;
        assert(!vdt_resource_apply(t,&m,NULL) && memoryWrites==1);
        failAfterWriteRead=NO; kernelPair=(VDTMemlimitPair){333,1,333,1};
        restart(); vdt_resource_reload(prefs(YES));
        assert(!vdt_resource_apply(t,&m,NULL) && memoryWrites==1 && kernelPair.active==333);
        assert([resourceRecords[resourceInstance(t)][@"memory"][@"phase"] isEqual:@"unverified"]);
        assert(vdt_resource_apply(t,&changed,NULL) && memoryWrites==2 && kernelPair.active==96);
        assert(([resourceRecords[resourceInstance(t)][@"memory"][@"original"] isEqual:@[@2048,@0,@2048,@0]]));
        assert(vdt_resource_apply(t,NULL,NULL) && memoryWrites==3 && kernelPair.active==2048 && resourceRecords.count==0);
        reset(); vdt_resource_reload(prefs(YES)); failMemory=YES;
        assert(!vdt_resource_apply(t,&m,&p) && priorityWrites==1 && memoryWrites==0 && resourceRecords.count==1);
        for (unsigned i=0;i<5;i++) {
            for (NSString *key in resourceDue.allKeys) resourceDue[key]=@0;
            vdt_resource_apply(t,&m,&p);
        }
        assert(priorityWrites==1); // successful side never forced by failing sibling
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,&p));
        vdt_resource_reconcile(@[]); assert(resourceRecords.count==0 && kernelPair.active==2048 && kernelPriority==18);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        NSString *boot=resourceBoot; resourceBoot=@"foreign-boot"; assert(resourcePersist()); restart();
        vdt_resource_reload(prefs(NO)); assert(resourceRecords.count==0 && writes==1); // no cross-boot restore
        resourceBoot=boot;
        reset(); vdt_resource_reload(prefs(YES));
        resourceRecords[@"broken"]=@{@"target":t,@"memory":@{@"original":@0}}; assert(resourcePersist()); restart();
        vdt_resource_reload(prefs(YES)); assert(!vdt_resource_apply(t,&m,NULL) && writes==0 && resourceStoreError==EINVAL);
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        VDTNiceStore store; assert(!VDTNiceStoreOpen(VDTResourceStateDirectory().fileSystemRepresentation,1,&store));
        NSData *request=[NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"boot":resourceBoot,@"nonce":@"test-removal"}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert(!VDTNiceStoreWrite(&store,VDT_NICE_REQUEST,request.bytes,request.length)); VDTNiceStoreClose(&store);
        vdt_resource_reload(prefs(YES)); assert(resourcePaused && [resourceRestoreNonce isEqual:@"test-removal"]);
        assert(vdt_resource_restore_all() && resourceRecords.count==0 && kernelPair.active==2048); vdt_resource_publish();
        reset(); vdt_resource_reload(prefs(YES)); assert(vdt_resource_apply(t,&m,NULL));
        assert(!VDTNiceStoreOpen(VDTResourceStateDirectory().fileSystemRepresentation,1,&store));
        NSData *bad=[NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"boot":resourceBoot}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert(!VDTNiceStoreWrite(&store,VDT_NICE_REQUEST,bad.bytes,bad.length)); VDTNiceStoreClose(&store);
        vdt_resource_reload(prefs(YES));
        assert(!vdt_resource_apply(t,&changed,NULL) && writes==1 && resourceControlError==EINVAL);
        assert(resourcePersist());
        assert(!vdt_resource_apply(t,&changed,NULL) && writes==1 && resourceControlError==EINVAL);
        assert(!vdt_resource_restore_all()); // journal save cannot erase a bad request lock
        assert([NSFileManager.defaultManager removeItemAtPath:testRoot error:nil]);
        puts("PASS production resource runtime + real atomic store; fake kernel, not UIKit/device");
    }
}
