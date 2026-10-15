// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTNiceRuntime.h"
#import "VDTNiceShared.h"
#import "VDTNiceStore.h"
#import "VDTNicePolicy.h"
#import "VDTNiceAttempt.h"
#import "VDTProcessIdentity.h"
#import "VDTBundleIdentity.h"
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <notify.h>
#include <sys/resource.h>
#include <unistd.h>

// Never silently inherit Linux's PRIO_MAX=19 in an iOS build.
static_assert(PRIO_MIN == -20 && PRIO_MAX == 20, "Darwin nice ABI changed");
static BOOL integer(id value, long long low, long long high, long long *out) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double d = [value doubleValue];
    if (!isfinite(d) || d < (double)low || d > (double)high || floor(d) != d) return NO;
    long long n = [value longLongValue];
    if (n < low || n > high) return NO;
    if (out) *out = n;
    return YES;
}
static BOOL boolean(id value, BOOL *out) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    if (out) *out = [value boolValue];
    return YES;
}
static BOOL text(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= limit &&
        [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location == NSNotFound;
}
static NSDictionary *boundTarget(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *target = raw; long long pid, type, seconds, microseconds;
    if (!integer(target[VDTTargetPidKey], 2, INT_MAX, &pid) ||
        !integer(target[VDTConfigTypeKey], VDTConfigTypeApp, VDTConfigTypeExtension, &type) ||
        !integer(target[VDTTargetStartSecondsKey], 1, LLONG_MAX, &seconds) ||
        !integer(target[VDTTargetStartMicrosecondsKey], 0, 999999, &microseconds) ||
        !text(target[VDTTargetNameKey], 1024)) return nil;
    NSMutableDictionary *result = [@{VDTTargetPidKey: @(pid), VDTConfigTypeKey: @(type),
        VDTTargetNameKey: target[VDTTargetNameKey], VDTTargetStartSecondsKey: @(seconds),
        VDTTargetStartMicrosecondsKey: @(microseconds)} mutableCopy];
    id path = target[VDTTargetExecutablePathKey], comm = target[VDTTargetProcCommKey];
    if (path) {
        if (!text(path, 4096) || ![path hasPrefix:@"/"]) return nil;
        result[VDTTargetExecutablePathKey] = path;
    } else if (type != VDTConfigTypeExtension && text(comm, 255)) result[VDTTargetProcCommKey] = comm;
    else return nil;
    if (type == VDTConfigTypeExtension && !VDTNearestBundlePath(path, @"appex")) return nil;
    if (type != VDTConfigTypeExtension && path && VDTNearestBundlePath(path, @"appex")) return nil;
    id host = target[@"containingAppIdentifier"];
    if (host) {
        if (type != VDTConfigTypeExtension || !text(host, 1024)) return nil;
        result[@"containingAppIdentifier"] = host;
    }
    // Optional for legacy App/Daemon journals; new records retain source apart
    // from the actual Extension identity. Partial/malformed source is rejected.
    id sourceType = target[@"niceSourceType"], sourceName = target[@"niceSourceIdentifier"],
       sourceRevision = target[@"niceSourceRevision"];
    if (sourceType || sourceName || sourceRevision) {
        long long source;
        if (!integer(sourceType, VDTConfigTypeApp, VDTConfigTypeExtension, &source) ||
            !text(sourceName, 1024) || ![sourceRevision isKindOfClass:NSString.class] ||
            [sourceRevision length] > 80) return nil;
        BOOL inherited = type == VDTConfigTypeExtension && source == VDTConfigTypeApp;
        if (inherited ? ![sourceName isEqual:host] :
            (source != type || ![sourceName isEqual:target[VDTTargetNameKey]])) return nil;
        result[@"niceSourceType"] = sourceType; result[@"niceSourceIdentifier"] = sourceName;
        result[@"niceSourceRevision"] = sourceRevision;
    }
    return result;
}
static NSString *instanceKey(NSDictionary *target) {
    NSString *identity = target[VDTTargetExecutablePathKey] ?: target[VDTTargetProcCommKey];
    return [NSString stringWithFormat:@"%d:%llu:%llu:%@", [target[VDTTargetPidKey] intValue],
        [target[VDTTargetStartSecondsKey] unsignedLongLongValue],
        [target[VDTTargetStartMicrosecondsKey] unsignedLongLongValue], identity];
}
static NSString *ruleKey(NSDictionary *target) {
    return VDTNiceRuleKey((VDTConfigType)[target[VDTConfigTypeKey] unsignedIntegerValue], target[VDTTargetNameKey]);
}
static NSDictionary *ruleForTarget(NSDictionary *target, NSDictionary *rules) {
    return VDTNiceEffectiveRuleFromRules(target[VDTTargetNameKey],
        (VDTConfigType)[target[VDTConfigTypeKey] unsignedIntegerValue],
        target[@"containingAppIdentifier"], rules);
}
static NSDictionary *targetWithSource(NSDictionary *target, NSDictionary *rule) {
    NSMutableDictionary *updated = [target mutableCopy];
    updated[@"niceSourceType"] = rule[@"sourceType"];
    updated[@"niceSourceIdentifier"] = rule[@"sourceIdentifier"];
    updated[@"niceSourceRevision"] = rule[@"sourceRevision"];
    return updated;
}
static BOOL protectedRule(NSDictionary *rule) {
    NSString *name = rule[@"sourceIdentifier"] ?: rule[@"identifier"];
    NSUInteger type = [rule[@"sourceType"] ?: rule[@"type"] unsignedIntegerValue];
    if (type == VDTConfigTypeApp) return [name isEqual:@"com.apple.Preferences"];
    if (type == VDTConfigTypeDaemon) return [name isEqual:@"launchd"] || [name isEqual:@"runningboardd"];
    return NO;
}
static NSDictionary *encodeRecord(const VDTNiceRecord *r) {
    return @{@"captured": @(r->captured), @"original": @(r->originalValue),
        @"owns": @(r->ownsValue), @"owned": @(r->ownedValue),
        @"hasIntent": @(r->hasIntent), @"intent": @(r->intentValue)};
}
static BOOL decodeRecord(id raw, VDTNiceRecord *r) {
    if (![raw isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *d = raw; BOOL captured, owns, intent; long long original, owned, pending;
    if (!boolean(d[@"captured"], &captured) || !boolean(d[@"owns"], &owns) || !boolean(d[@"hasIntent"], &intent) ||
        !integer(d[@"original"], -20, 20, &original) || !integer(d[@"owned"], -20, 20, &owned) ||
        !integer(d[@"intent"], -20, 20, &pending)) return NO;
    *r = (VDTNiceRecord){.captured = (bool)captured, .originalValue = (int)original,
        .ownsValue = (bool)owns, .ownedValue = (int)owned, .hasIntent = (bool)intent, .intentValue = (int)pending};
    return captured && VDTNiceRecordIsValid(r);
}
// A false Boolean identity check cannot distinguish ESRCH from a transient
// permission/read failure. Only a proven lifetime mismatch or ESRCH is Gone.
static VDTNiceIdentity nativeIdentity(pid_t pid, NSDictionary *target) {
    if (pid <= 1 || pid == getpid()) return VDTNiceIdentityUnavailableValue;
    struct vdt_proc_bsdinfo info = {}; errno = 0;
    int bytes = proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != (int)sizeof(info)) return errno == ESRCH ? VDTNiceIdentityGone : VDTNiceIdentityUnavailableValue;
    if (info.pbi_pid != (uint32_t)pid) return VDTNiceIdentityUnavailableValue;
    if (info.pbi_start_tvsec != [target[VDTTargetStartSecondsKey] unsignedLongLongValue] ||
        info.pbi_start_tvusec != [target[VDTTargetStartMicrosecondsKey] unsignedLongLongValue]) return VDTNiceIdentityGone;
    if (!vdt_target_is_current(target)) return VDTNiceIdentityUnavailableValue;
    if ([target[VDTConfigTypeKey] unsignedIntegerValue] == VDTConfigTypeExtension) {
        NSString *path = target[VDTTargetExecutablePathKey];
        NSDictionary *info = VDTReadExtensionBundleInfo(VDTNearestBundlePath(path, @"appex"), path);
        if (![info[@"extensionIdentifier"] isEqual:target[VDTTargetNameKey]])
            return VDTNiceIdentityUnavailableValue;
        NSString *host = target[@"containingAppIdentifier"];
        if (host) {
            NSString *appPath = info[@"containingAppPath"];
            NSDictionary *appInfo = appPath ? [NSDictionary dictionaryWithContentsOfFile:
                [appPath stringByAppendingPathComponent:@"Info.plist"]] : nil;
            if (![appInfo[@"CFBundleIdentifier"] isEqual:host])
                return VDTNiceIdentityUnavailableValue;
        }
        // Recheck lifetime/path after metadata I/O as well as before it.
        if (!vdt_target_is_current(target)) return VDTNiceIdentityUnavailableValue;
    }
    return VDTNiceIdentityCurrent;
}
static NSString *outcomeCode(VDTNiceOutcome outcome) {
    switch (outcome) {
        case VDTNiceUnmanaged: return @"disabled";
        case VDTNiceApplied: return @"applied";
        case VDTNiceRestored: return @"restored";
        case VDTNiceGone: return @"target-not-running";
        case VDTNiceInvalid: return @"invalid";
        case VDTNiceIdentityUnavailable: return @"identity-unavailable";
        case VDTNiceReadFailed: return @"read-failed";
        case VDTNiceWriteFailed: return @"write-failed";
        case VDTNiceVerifyFailed: return @"verify-failed";
        case VDTNiceStoreFailed: return @"store-failed";
        case VDTNiceConflict: return @"conflict";
    }
    return @"state-unavailable";
}

@interface VDTNiceCoordinator : NSObject {
@public
    VDTNiceStore store;
    NSMutableDictionary<NSString *, NSDictionary *> *records;
    NSMutableDictionary<NSString *, NSDictionary *> *outcomes;
    NSMutableSet<NSString *> *attempted;
    NSMutableDictionary<NSString *, NSDictionary *> *attemptStates;
    NSMutableSet<NSString *> *goneCleanupStarted;
    NSDictionary<NSString *, NSDictionary *> *rules;
    NSString *boot;
    NSString *restoreNonce;
    int loadError;
    BOOL paused;
    BOOL loaded;
    BOOL receiptDirty;
}
- (void)reload:(NSDictionary *)prefs;
- (void)reconcile;
- (void)apply:(NSDictionary *)target;
- (void)publish;
- (NSTimeInterval)retryClock;
- (NSTimeInterval)nextRetryDelay;
- (BOOL)restoreAll;
- (int)save:(const VDTNiceRecord *)record target:(NSDictionary *)target;
@end

// Per-transition receipt evidence only; never persisted into the nice journal.
typedef struct {
    __strong VDTNiceCoordinator *owner;
    __strong NSDictionary *target;
    unsigned writeCalls;
    NSTimeInterval observedAt;
} NativeContext;
static VDTNiceIdentity identityCallback(pid_t pid, void *raw) {
    return nativeIdentity(pid, ((NativeContext *)raw)->target);
}
static int readCallback(pid_t pid, int *value, void *raw) {
    NativeContext *context = (NativeContext *)raw;
    errno = 0; int n = getpriority(PRIO_PROCESS, (id_t)pid); int error = errno;
    if (n == -1 && error) return error;
    context->observedAt = NSDate.date.timeIntervalSince1970;
    errno = error; *value = n; return 0;
}
static int writeCallback(pid_t pid, int value, void *raw) {
    ++((NativeContext *)raw)->writeCalls;
    errno = 0;
    return setpriority(PRIO_PROCESS, (id_t)pid, value) == 0 ? 0 : (errno ?: EIO);
}
static int saveCallback(const VDTNiceRecord *record, void *raw) {
    NativeContext *c = (NativeContext *)raw;
    return [c->owner save:record target:c->target];
}
static id readPlist(VDTNiceStore *store, const char *name, int *error) {
    void *bytes = NULL; size_t length = 0;
    *error = VDTNiceStoreRead(store, name, &bytes, &length);
    if (*error) return nil;
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
    id result = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (!result) *error = EINVAL;
    return result;
}
static int writePlist(VDTNiceStore *store, const char *name, NSDictionary *object) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || data.length > VDT_NICE_STORE_LIMIT) return EFBIG;
    return VDTNiceStoreWrite(store, name, data.bytes, data.length);
}
static int writeStatusReceipt(VDTNiceStore *store, NSDictionary *receipt) {
    if (![NSPropertyListSerialization propertyList:receipt isValidForFormat:NSPropertyListBinaryFormat_v1_0]) return EINVAL;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:receipt
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return EINVAL;
    if (data.length > VDT_NICE_STORE_LIMIT) {
        // Status is a rebuildable display cache, never the recovery journal.
        // Publish a bounded error instead of leaving an old success on disk.
        id stamp = receipt[@"updatedAt"];
        if (!text(receipt[@"boot"], 100) || ![stamp isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)stamp) == CFBooleanGetTypeID() ||
            !isfinite([stamp doubleValue]) || [stamp doubleValue] <= 0 ||
            [stamp doubleValue] >= 253402300800.0) return EFBIG;
        NSDictionary *fallback = @{@"version": @1, @"boot": receipt[@"boot"],
            @"rules": @{}, @"statusError": @(EFBIG), @"updatedAt": stamp};
        // No checkedAt/readback or removal-ack fields: this records a failed
        // receipt publication, not a kernel check or successful restoration.
        data = [NSPropertyListSerialization dataWithPropertyList:fallback
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (!data || data.length > VDT_NICE_STORE_LIMIT) return EFBIG;
    }
    return VDTNiceStoreWrite(store, VDT_NICE_STATUS, data.bytes, data.length);
}
@implementation VDTNiceCoordinator
- (instancetype)init {
    if ((self = [super init])) {
        store = (VDTNiceStore){.parentFD = -1, .directoryFD = -1, .parentPath = NULL, .leaf = NULL};
        records = [NSMutableDictionary dictionary]; outcomes = [NSMutableDictionary dictionary];
        attempted = [NSMutableSet set]; attemptStates = [NSMutableDictionary dictionary];
        goneCleanupStarted = [NSMutableSet set]; rules = @{};
    }
    return self;
}
- (void)dealloc { VDTNiceStoreClose(&store); }
- (void)load {
    if (loaded) return;
    loaded = YES; loadError = 0; boot = VDTNiceBootToken();
    if (!boot) { loadError = ENOTSUP; return; }
    BOOL needsStore = NO;
    for (NSDictionary *rule in rules.allValues) if ([rule[@"requestedEnabled"] boolValue]) { needsStore = YES; break; }
    loadError = VDTNiceStoreOpen(VDTNiceStateDirectory().fileSystemRepresentation, needsStore, &store);
    if (loadError == ENOENT && !needsStore) {
        if (!records.count) loadError = 0;
        return;
    }
    if (loadError) return;
    int error = 0; id raw = readPlist(&store, VDT_NICE_JOURNAL, &error);
    if (error == ENOENT) {
        // Losing a journal while this coordinator still owns live records is
        // not a new installation. Keep the only remaining baseline in memory.
        if (records.count) loadError = ENOENT;
        return;
    }
    if (error) { loadError = error; return; }
    if (![raw isKindOfClass:NSDictionary.class] || !text(raw[@"boot"], 100)) { loadError = EINVAL; return; }
    if (![raw[@"boot"] isEqual:boot]) {
        // A PID+start token is only meaningful within its boot. Never restore
        // an old boot's baseline into a new boot, even if all numbers collide.
        // Discard the stale journal before any entry validation: a record an
        // older version wrote must not keep the store from being replaced.
        int saved = writePlist(&store, VDT_NICE_JOURNAL, @{@"version": @1, @"boot": boot, @"records": @{}});
        if (saved) { loadError = saved; return; }
        [records removeAllObjects];
        return;
    }
    if (![raw[@"version"] isEqual:@1] || ![raw[@"records"] isKindOfClass:NSDictionary.class] ||
        [raw[@"records"] count] > VDTNiceMaximumRecords) { loadError = EINVAL; return; }
    NSMutableDictionary *validated = [NSMutableDictionary dictionary];
    NSDictionary *entries = raw[@"records"];
    BOOL dropped = NO;
    for (id key in entries) {
        id entry = entries[key];
        NSDictionary *target = [entry isKindOfClass:NSDictionary.class] ? boundTarget(entry[@"target"]) : nil;
        VDTNiceRecord r = {};
        if (!target || !decodeRecord(entry[@"record"], &r) || ![key isEqual:instanceKey(target)]) {
            // Format drift must not dead-lock the whole store: a fresh load
            // drops records this version cannot read (an unreadable record
            // could never be restored from), while a live coordinator that
            // still owns in-memory records keeps the strict guarded form.
            if (records.count) { loadError = EINVAL; return; }
            dropped = YES;
            continue;
        }
        validated[key] = @{@"target": target, @"record": encodeRecord(&r)};
    }
    if (dropped) {
        int saved = writePlist(&store, VDT_NICE_JOURNAL, @{@"version": @1, @"boot": boot, @"records": validated});
        if (saved) { loadError = saved; return; }
    }
    records = validated;
}
- (void)checkRestoreRequest {
    BOOL wasPaused = paused;
    NSString *oldNonce = restoreNonce;
    paused = NO; restoreNonce = nil;
    if (store.directoryFD < 0) return;
    int error = 0; id request = readPlist(&store, VDT_NICE_REQUEST, &error);
    if (error != ENOENT) {
        paused = YES; // Invalid/unreadable requests never permit a fresh write.
        if (error || ![request isKindOfClass:NSDictionary.class] || ![request[@"version"] isEqual:@1] ||
            !text(request[@"nonce"], 100) || !text(request[@"boot"], 100)) {
            loadError = error ?: EINVAL;
        } else if (![request[@"boot"] isEqual:boot]) {
            int removed = VDTNiceStoreRemove(&store, VDT_NICE_REQUEST);
            if (removed) loadError = removed;
            paused = removed != 0;
        } else restoreNonce = request[@"nonce"];
    }
    if (wasPaused != paused || ![oldNonce ?: @"" isEqual:restoreNonce ?: @""]) receiptDirty = YES;
}
- (void)reload:(NSDictionary *)prefs {
    rules = VDTNiceRulesFromPrefs(prefs);
    receiptDirty = YES;
    [attempted removeAllObjects]; [attemptStates removeAllObjects]; [goneCleanupStarted removeAllObjects]; [outcomes removeAllObjects];
    VDTNiceStoreClose(&store); loaded = NO;
    [self load];
    if (rules.count > VDTNiceMaximumRecords) loadError = E2BIG;
    [self checkRestoreRequest];
}
- (int)save:(const VDTNiceRecord *)r target:(NSDictionary *)target {
    if (loadError || store.directoryFD < 0 || !boot) return loadError ?: EIO;
    NSString *key = instanceKey(target);
    NSMutableDictionary *next = [records mutableCopy];
    if (r) next[key] = @{@"target": target, @"record": encodeRecord(r)};
    else [next removeObjectForKey:key];
    if (next.count > VDTNiceMaximumRecords) return E2BIG;
    int error = writePlist(&store, VDT_NICE_JOURNAL, @{@"version": @1, @"boot": boot, @"records": next});
    if (!error) records = next;
    return error;
}
- (NSTimeInterval)retryClock { return NSProcessInfo.processInfo.systemUptime; }
- (NSTimeInterval)nextRetryDelay {
    if (loadError || store.directoryFD < 0) return -1;
    NSTimeInterval now = [self retryClock], delay = -1;
    for (NSDictionary *outcome in outcomes.allValues) {
        NSDictionary *target = outcome[@"target"], *rule = ruleForTarget(target, rules);
        BOOL enabled = [outcome[@"attemptEnabled"] boolValue] && !paused && [rule[@"enabled"] boolValue];
        if (enabled && protectedRule(rule)) continue;
        NSString *key = [instanceKey(target) stringByAppendingString:enabled ? @":apply" : @":restore"];
        NSDictionary *state = attemptStates[key];
        if (![state[@"pending"] boolValue]) continue;
        NSTimeInterval candidate = MAX(0, [state[@"due"] doubleValue] - now);
        if (delay < 0 || candidate < delay) delay = candidate;
    }
    return delay;
}
- (void)runTarget:(NSDictionary *)target enabled:(BOOL)enabled desired:(int)desired {
    NSString *key = instanceKey(target);
    NSString *attemptKey = [key stringByAppendingString:enabled ? @":apply" : @":restore"];
    NSDictionary *savedAttempt = attemptStates[attemptKey];
    VDTNiceAttempt attempt = {.count = [savedAttempt[@"count"] unsignedIntValue],
        .pending = (bool)[savedAttempt[@"pending"] boolValue], .due = [savedAttempt[@"due"] doubleValue]};
    NSTimeInterval now = [self retryClock];
    if (!VDTNiceAttemptAllowed(attempt, now)) return;
    [attempted addObject:attemptKey];
    VDTNiceRecord r = {};
    if (records[key] && !decodeRecord(records[key][@"record"], &r)) { loadError = EINVAL; return; }
    NativeContext context = {self, target, 0, 0};
    VDTNiceOperations ops = {.identity = identityCallback, .readValue = readCallback,
        .writeValue = writeCallback, .saveRecord = saveCallback, .context = &context};
    VDTNiceResult result = VDTNiceTransition([target[VDTTargetPidKey] intValue], enabled, desired, &r, &ops);
    // Same-value source changes still need a durable, real identity/source
    // update; the frozen C policy correctly avoids a redundant value save.
    if (result.outcome == VDTNiceApplied && r.captured &&
        ![records[key][@"target"] isEqual:target]) {
        int error = [self save:&r target:target];
        if (error) { result.outcome = VDTNiceStoreFailed; result.error = error; }
    }
    attempt = VDTNiceAttemptFinished(attempt, [self retryClock], result.outcome, result.error);
    attemptStates[attemptKey] = @{@"count": @(attempt.count), @"pending": @(attempt.pending), @"due": @(attempt.due)};
    NSMutableDictionary *outcome = [@{@"target": target, @"state": outcomeCode(result.outcome),
        @"error": @(result.error), @"checkedAt": @(NSDate.date.timeIntervalSince1970),
        @"attemptEnabled": @(enabled), @"retryPending": @(attempt.pending), @"attemptCount": @(attempt.count)} mutableCopy];
    if (result.observedValid) {
        outcome[@"observed"] = @(result.observedValue);
        if (context.observedAt > 0) outcome[@"observedAt"] = @(context.observedAt);
    }
    outcome[@"writeCalls"] = @(context.writeCalls);
    outcome[@"evidence"] = ((result.outcome == VDTNiceApplied || result.outcome == VDTNiceRestored) && result.observedValid)
        ? (context.writeCalls ? @"written-verified" : @"matched-without-set") : @"execution-result";
    if (r.captured) outcome[@"original"] = @(r.originalValue);
    outcomes[key] = outcome;
    receiptDirty = YES;
    // Bound failed/unmanaged observations as well as persistent records. Active
    // recovery records are never evicted just to satisfy this cache bound.
    if (outcomes.count > VDTNiceMaximumRecords) {
        for (NSString *oldKey in [outcomes.allKeys copy]) {
            if (records[oldKey]) continue;
            [outcomes removeObjectForKey:oldKey];
            [goneCleanupStarted removeObject:oldKey];
            [attempted removeObject:[oldKey stringByAppendingString:@":apply"]];
            [attempted removeObject:[oldKey stringByAppendingString:@":restore"]];
            [attemptStates removeObjectForKey:[oldKey stringByAppendingString:@":apply"]];
            [attemptStates removeObjectForKey:[oldKey stringByAppendingString:@":restore"]];
            if (outcomes.count <= VDTNiceMaximumRecords) break;
        }
    }
}
- (void)reconcile {
    [self load]; [self checkRestoreRequest];
    if (loadError || store.directoryFD < 0) return;
    for (NSString *key in [records.allKeys copy]) {
        NSDictionary *target = records[key][@"target"];
        NSDictionary *rule = ruleForTarget(target, rules);
        VDTNiceIdentity identity = nativeIdentity([target[VDTTargetPidKey] intValue], target);
        if (identity == VDTNiceIdentityGone) {
            // Forgetting an old instance must not be suppressed by a previous
            // successful apply in this config generation.
            if (![goneCleanupStarted containsObject:key]) {
                [goneCleanupStarted addObject:key];
                [attempted removeObject:[key stringByAppendingString:@":restore"]];
                [attemptStates removeObjectForKey:[key stringByAppendingString:@":restore"]];
            }
            [self runTarget:target enabled:NO desired:0];
        } else if (paused || ![rule[@"enabled"] boolValue]) {
            [self runTarget:target enabled:NO desired:0];
        }
    }
    // Failed first attempts may have no captured journal (identity/read error).
    // Retry their already-bound targets too; every IO still goes through the
    // production lifetime/path guards. No PID scan, CPU call or polling here.
    for (NSDictionary *outcome in [outcomes.allValues copy]) {
        NSDictionary *target = outcome[@"target"], *rule = ruleForTarget(target, rules);
        BOOL enabled = [outcome[@"attemptEnabled"] boolValue] && !paused && [rule[@"enabled"] boolValue];
        NSString *attemptKey = [instanceKey(target) stringByAppendingString:enabled ? @":apply" : @":restore"];
        if (![attemptStates[attemptKey][@"pending"] boolValue]) continue;
        if (enabled) [self apply:target];
        else [self runTarget:target enabled:NO desired:0];
    }
}
- (void)apply:(NSDictionary *)rawTarget {
    if (loadError || store.directoryFD < 0) return;
    NSDictionary *target = boundTarget(rawTarget);
    if (!target) return;
    NSDictionary *rule = ruleForTarget(target, rules);
    if (protectedRule(rule) || [target[VDTTargetPidKey] intValue] == getpid()) return;
    target = targetWithSource(target, rule);
    BOOL enabled = !paused && [rule[@"enabled"] boolValue];
    // An unmanaged disabled/invalid target is a policy no-op, but retaining
    // its verified host identity is necessary for a source-matching receipt.
    [self runTarget:target enabled:enabled desired:[rule[@"value"] intValue]];
}
- (BOOL)restoreAll {
    [attempted removeAllObjects]; [attemptStates removeAllObjects]; [goneCleanupStarted removeAllObjects];
    [self load];
    if (loadError) return NO;
    for (NSString *key in [records.allKeys copy]) [self runTarget:records[key][@"target"] enabled:NO desired:0];
    [self publish];
    return records.count == 0;
}
- (void)publish {
    if (!receiptDirty || store.directoryFD < 0 || !boot) return;
    NSMutableDictionary *allRules = [NSMutableDictionary dictionary];
    for (NSString *key in rules) {
        NSDictionary *rule = rules[key];
        allRules[key] = VDTNiceEffectiveRuleFromRules(rule[@"identifier"],
            (VDTConfigType)[rule[@"type"] unsignedIntegerValue], nil, rules);
    }
    // Derive receipts from the REAL target and its current effective source,
    // including inherited extensions and pending restorations after deletion.
    for (NSDictionary *entry in [records.allValues arrayByAddingObjectsFromArray:outcomes.allValues]) {
        NSDictionary *target = entry[@"target"]; NSString *key = ruleKey(target);
        if (key) allRules[key] = ruleForTarget(target, rules);
    }
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (NSString *key in outcomes) {
        NSDictionary *outcome = outcomes[key]; NSString *configKey = ruleKey(outcome[@"target"]);
        if (!configKey) continue;
        NSMutableArray *group = groups[configKey];
        if (!group) { group = [NSMutableArray array]; groups[configKey] = group; }
        [group addObject:@{@"key": key, @"outcome": outcome}];
    }
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    NSMutableSet *activeKeys = [NSMutableSet setWithArray:groups.allKeys];
    for (NSDictionary *entry in records.allValues) {
        NSString *key = ruleKey(entry[@"target"]);
        if (key) [activeKeys addObject:key];
    }
    NSUInteger totalPendingRestore = 0;
    for (NSString *key in allRules) {
        NSDictionary *rule = allRules[key];
        // No execution/recovery evidence means no historical receipt. Preserve
        // explicit errors and policy explanations rather than hiding them when
        // a rule has not yet produced a target outcome.
        if (![activeKeys containsObject:key] && !loadError && !paused &&
            [rule[@"valid"] boolValue] &&
            !(protectedRule(rule) && [rule[@"requestedEnabled"] boolValue])) continue;
        NSMutableDictionary *row = [rule mutableCopy];
        BOOL enabled = [rule[@"enabled"] boolValue];
        NSString *state = enabled ? @"target-not-running" : @"disabled";
        NSUInteger targetCount = 0, appliedCount = 0, pendingCount = 0;
        int error = 0; BOOL sawFailure = NO;
        NSTimeInterval newestCheck = 0, oldestCheck = DBL_MAX;
        BOOL retryPending = NO;
        NSArray *group = groups[key] ?: @[];
        row[@"outcomeCount"] = @(group.count);
        for (NSDictionary *item in group) {
            NSDictionary *outcome = item[@"outcome"]; NSString *current = outcome[@"state"];
            NSTimeInterval checked = [outcome[@"checkedAt"] doubleValue];
            if (checked > 0) { newestCheck = MAX(newestCheck, checked); oldestCheck = MIN(oldestCheck, checked); }
            retryPending = retryPending || [outcome[@"retryPending"] boolValue];
            if (![current isEqual:@"target-not-running"]) ++targetCount;
            if ([current isEqual:@"applied"]) ++appliedCount;
            BOOL failure = ![@[@"applied", @"restored", @"disabled", @"target-not-running"] containsObject:current];
            if (failure) { ++pendingCount; state = current; error = [outcome[@"error"] intValue]; sawFailure = YES; }
            else if (!sawFailure && ![current isEqual:@"target-not-running"]) state = current;
            if (group.count == 1) {
                for (NSString *field in @[@"observed", @"original", @"observedAt", @"writeCalls", @"evidence"])
                    if (outcome[field]) row[field] = outcome[field];
                NSDictionary *target = outcome[@"target"];
                row[@"pid"] = target[VDTTargetPidKey];
                row[@"startSeconds"] = target[VDTTargetStartSecondsKey];
                row[@"startMicroseconds"] = target[VDTTargetStartMicrosecondsKey];
            }
        }
        NSUInteger restoring = 0;
        if (!enabled || paused) for (NSDictionary *entry in records.allValues)
            if ([ruleKey(entry[@"target"]) isEqual:key]) ++restoring;
        totalPendingRestore += restoring;
        pendingCount = MAX(pendingCount, restoring);
        if (!sawFailure && restoring) state = @"pending";
        if (![rule[@"valid"] boolValue] && !restoring) state = @"invalid";
        if (protectedRule(rule) && [rule[@"requestedEnabled"] boolValue]) state = @"protected";
        if (paused && !restoring && !sawFailure) state = @"paused";
        if (loadError) { state = boot ? @"state-unavailable" : @"boot-unavailable"; error = loadError; }
        row[@"state"] = state; row[@"error"] = @(error);
        row[@"targetCount"] = @(targetCount); row[@"appliedCount"] = @(appliedCount);
        row[@"pendingCount"] = @(pendingCount); row[@"retryPending"] = @(retryPending);
        if (newestCheck > 0) { row[@"checkedAt"] = @(newestCheck); row[@"oldestCheckedAt"] = @(oldestCheck); }
        rows[key] = row;
    }
    NSDictionary *receipt = @{@"version": @1, @"boot": boot, @"rules": rows,
        @"recordCount": @(records.count), @"pendingRestoreCount": @(totalPendingRestore),
        @"paused": @(paused), @"restoreNonce": restoreNonce ?: @"", @"storeError": @(loadError),
        @"updatedAt": @(NSDate.date.timeIntervalSince1970)};
    int error = writeStatusReceipt(&store, receipt);
    if (!error) {
        receiptDirty = NO;
        // A saved error envelope is also a new display result, not SET success.
        notify_post(VDT_NICE_RESULTS_NOTIFICATION);
    }
    // Any failed commit retains the dirty bit and sends no result notification.
}
@end
static VDTNiceCoordinator *coordinator(void) {
    static VDTNiceCoordinator *value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [VDTNiceCoordinator new]; });
    return value;
}
void vdt_nice_reload(NSDictionary *prefs) { [coordinator() reload:prefs]; }
void vdt_nice_reconcile(void) { [coordinator() reconcile]; }
void vdt_nice_apply(NSDictionary *target) { [coordinator() apply:target]; }
void vdt_nice_publish(void) { [coordinator() publish]; }
NSTimeInterval vdt_nice_next_retry_delay(void) { return [coordinator() nextRetryDelay]; }
BOOL vdt_nice_restore_all(void) { return [coordinator() restoreAll]; }
