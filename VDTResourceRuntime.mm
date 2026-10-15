// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTResourceRuntime.h"
#import "VDTResourceShared.h"
#import "VDTResourceSystemBackend.h"
#import "VDTNiceShared.h"
#import "VDTNiceStore.h"
#import "VDTBundleIdentity.h"
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <notify.h>
#include <sys/sysctl.h>
#include <stdlib.h>

static NSMutableDictionary *resourceRowsByInstance;
static NSMutableDictionary *resourceRecords, *resourceRows, *resourceAttempts, *resourceDue;
static NSDictionary *resourceConfiguration;
static NSString *resourceBoot, *resourceRestoreNonce;
static BOOL resourceLoaded, resourceWrites, resourcePaused;
static int resourceStoreError, resourceControlError;
static int32_t resourceDarwin;
static int32_t resourceDarwinMajor(void);
static double resourceNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL resourceInteger(id value, long long low, long long high) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double d = [value doubleValue];
    return isfinite(d) && floor(d) == d && d >= (double)low && d <= (double)high &&
        [value longLongValue] >= low && [value longLongValue] <= high;
}
static BOOL resourceText(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= limit &&
        [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location == NSNotFound;
}
static NSDictionary *resourceBound(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *target = raw;
    if (!resourceInteger(target[VDTTargetPidKey], 2, INT_MAX) ||
        !resourceInteger(target[VDTConfigTypeKey], VDTConfigTypeApp, VDTConfigTypeExtension) ||
        !resourceInteger(target[VDTTargetStartSecondsKey], 1, LLONG_MAX) ||
        !resourceInteger(target[VDTTargetStartMicrosecondsKey], 0, 999999) ||
        !resourceText(target[VDTTargetNameKey], 1024)) return nil;
    id path = target[VDTTargetExecutablePathKey], comm = target[VDTTargetProcCommKey];
    if (path ? (!resourceText(path, 4096) || ![path hasPrefix:@"/"]) : !resourceText(comm, 255)) return nil;
    if ([target[VDTConfigTypeKey] unsignedIntegerValue] == VDTConfigTypeExtension &&
        (!path || !VDTNearestBundlePath(path, @"appex"))) return nil;
    NSMutableDictionary *bound = [NSMutableDictionary dictionary];
    for (NSString *key in @[VDTTargetPidKey, VDTConfigTypeKey, VDTTargetNameKey, VDTTargetStartSecondsKey,
        VDTTargetStartMicrosecondsKey, VDTTargetExecutablePathKey, VDTTargetProcCommKey])
        if (target[key]) bound[key] = target[key];
    return bound;
}
static NSString *resourceInstance(NSDictionary *target) {
    return [NSString stringWithFormat:@"%d:%llu:%llu:%@", [target[VDTTargetPidKey] intValue],
        [target[VDTTargetStartSecondsKey] unsignedLongLongValue], [target[VDTTargetStartMicrosecondsKey] unsignedLongLongValue],
        target[VDTTargetExecutablePathKey] ?: target[VDTTargetProcCommKey]];
}
static id resourcePair(VDTMemlimitPair pair) { return @[@(pair.active), @(pair.activeAttrs), @(pair.inactive), @(pair.inactiveAttrs)]; }
static BOOL resourcePriorityValid(id value, int32_t minimum) {
    int32_t maximum = 0;
    return VDTJetsamMaxBand(resourceDarwin, &maximum) && resourceInteger(value, minimum, maximum);
}
static BOOL resourceValueValid(id value, BOOL memory) {
    if (!memory) return resourcePriorityValid(value, 0);
    if (![value isKindOfClass:NSArray.class] || [value count] != 4) return NO;
    return resourceInteger(value[0], 1, INT32_MAX) && resourceInteger(value[2], 1, INT32_MAX) &&
        resourceInteger(value[1], 0, 1) && resourceInteger(value[3], 0, 1);
}
static VDTMemlimitPair resourcePairCore(NSArray *value) {
    return (VDTMemlimitPair){[value[0] intValue], [value[1] intValue], [value[2] intValue], [value[3] intValue]};
}
static BOOL resourceSideValid(id raw, BOOL memory) {
    if (![raw isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *side = raw;
    if (!resourceValueValid(side[@"original"], memory) || !resourceValueValid(side[@"last"], memory) ||
        ![@[@"pending", @"verified", @"unverified", @"restore-pending", @"conflict"] containsObject:side[@"phase"]]) return NO;
    id wanted = side[@"wanted"];
    NSString *phase = side[@"phase"];
    if (!wanted && ![phase isEqual:@"verified"] && ![phase isEqual:@"conflict"]) return NO;
    if ([phase isEqual:@"restore-pending"] && ![wanted isEqual:side[@"original"]]) return NO;
    // SET(-1) is a request, not a GET value. Never store it as an original/last.
    return !wanted || (memory ? resourceValueValid(wanted, YES) : resourcePriorityValid(wanted, -1));
}
static BOOL resourcePersist(void) {
    if (!resourceBoot || !VDTPolicyDarwinMajorIsKnown(resourceDarwin)) { resourceStoreError = ENOTSUP; return NO; }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version": @1, @"boot": resourceBoot,
        @"darwinMajor": @(resourceDarwin), @"records": resourceRecords ?: @{}} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || data.length > VDT_NICE_STORE_LIMIT) { resourceStoreError = EFBIG; return NO; }
    VDTNiceStore store;
    int error = VDTNiceStoreOpen(VDTResourceStateDirectory().fileSystemRepresentation, 1, &store);
    if (!error) { error = VDTNiceStoreWrite(&store, VDT_NICE_JOURNAL, data.bytes, data.length); VDTNiceStoreClose(&store); }
    resourceStoreError = error; return !error;
}
static NSDictionary *resourceRead(const char *name, int *error) {
    VDTNiceStore store; void *bytes = NULL; size_t length = 0;
    *error = VDTNiceStoreOpen(VDTResourceStateDirectory().fileSystemRepresentation, 1, &store);
    if (*error) return nil;
    *error = VDTNiceStoreRead(&store, name, &bytes, &length); VDTNiceStoreClose(&store);
    if (*error) return nil;
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
    id raw = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![raw isKindOfClass:NSDictionary.class]) { *error = EINVAL; return nil; }
    return raw;
}
static void resourceLoad(void) {
    if (resourceLoaded) { if (resourceStoreError) resourcePersist(); return; }
    resourceBoot = VDTNiceBootToken(); resourceDarwin = resourceDarwinMajor();
    resourceRecords = [NSMutableDictionary dictionary];
    if (!resourceBoot || !VDTPolicyDarwinMajorIsKnown(resourceDarwin)) { resourceStoreError = ENOTSUP; return; }
    int error = 0; NSDictionary *journal = resourceRead(VDT_NICE_JOURNAL, &error);
    if (error == ENOENT) { resourceLoaded = resourcePersist(); return; }
    if (error || ![journal[@"version"] isEqual:@1] || !resourceText(journal[@"boot"], 80)) {
        resourceStoreError = error ?: EINVAL; return;
    }
    // Lifetime tokens from another boot cannot authorize restoration.
    if (![journal[@"boot"] isEqual:resourceBoot]) { resourceLoaded = resourcePersist(); return; }
    id savedMajor = journal[@"darwinMajor"];
    if (!resourceInteger(savedMajor, 21, INT32_MAX) || [savedMajor intValue] != resourceDarwin) {
        resourceStoreError = EINVAL; return;
    }
    id records = journal[@"records"];
    if (![records isKindOfClass:NSDictionary.class] || [records count] > 2048) { resourceStoreError = EINVAL; return; }
    NSMutableDictionary *checked = [NSMutableDictionary dictionary];
    for (id key in records) {
        id raw = records[key]; NSDictionary *target = [raw isKindOfClass:NSDictionary.class] ? resourceBound(raw[@"target"]) : nil;
        if (!target || ![key isEqual:resourceInstance(target)] || (!raw[@"memory"] && !raw[@"priority"]) ||
            (raw[@"memory"] && !resourceSideValid(raw[@"memory"], YES)) ||
            (raw[@"priority"] && !resourceSideValid(raw[@"priority"], NO))) { resourceStoreError = EINVAL; return; }
        checked[key] = [raw mutableCopy];
    }
    resourceRecords = checked; resourceLoaded = YES; resourceStoreError = 0;
}
// Only an observed different start token or ESRCH proves an old lifetime gone.
// An unavailable path/permission read must retain pending restoration evidence.
static BOOL resourceGone(NSDictionary *target) {
    struct vdt_proc_bsdinfo info = {}; errno = 0;
    pid_t pid = [target[VDTTargetPidKey] intValue];
    int size = proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    VDTProcessInstanceToken observed = {info.pbi_start_tvsec, info.pbi_start_tvusec};
    if (size == sizeof(info)) return info.pbi_pid == (uint32_t)pid && VDTProcessInstanceTokenIsValid(observed) &&
        (observed.seconds != [target[VDTTargetStartSecondsKey] unsignedLongLongValue] ||
         observed.microseconds != [target[VDTTargetStartMicrosecondsKey] unsignedLongLongValue]);
    return size <= 0 && errno == ESRCH;
}
// Receipt-only helpers. They never change recovery records or retry state.
static NSNumber *resourceReceiptTime(void) {
    int saved = errno;
    NSNumber *value = @(NSDate.date.timeIntervalSince1970);
    errno = saved; return value;
}
static void resourceReceiptRead(NSMutableDictionary *detail, NSString *name, id value,
    NSNumber *startedAt, NSNumber *recordedAt, NSString *evidence) {
    int saved = errno;
    detail[[name stringByAppendingString:@"Observed"]] = value;
    detail[[name stringByAppendingString:@"ObservedAt"]] = recordedAt;
    detail[[name stringByAppendingString:@"ReadStartedAt"]] = startedAt;
    detail[[name stringByAppendingString:@"Evidence"]] = evidence;
    errno = saved;
}
static NSUInteger resourceReceiptRank(NSDictionary *row, NSString *side) {
    if ([row[@"state"] isEqual:@"store-error"]) return 0;
    NSString *state = row[side];
    NSArray *failures = @[@"store-error", @"conflict", @"read-failed", @"unverified", @"restore-pending", @"pending"];
    NSUInteger rank = [failures indexOfObject:state ?: @""];
    if (rank != NSNotFound) return rank;
    if ([state isEqual:@"applied"] || [state isEqual:@"restored"]) return 20;
    NSInteger skip = [row[[side stringByAppendingString:@"Skip"]] integerValue];
    if (skip == VDTApplySkipConflict) return 1;
    if (skip == VDTApplySkipReadbackFailed || skip == VDTApplySkipIdentity) return 2;
    if (skip != VDTApplySkipNone && skip != VDTApplySkipNoWrite) return 6;
    if ([row[@"state"] isEqual:@"pending"] || [row[@"state"] isEqual:@"partial"] ||
        [row[@"state"] isEqual:@"unsupported"]) return 7;
    return 10; // missing evidence must not be hidden behind another instance's success
}
static NSDictionary *resourceSideReceipt(NSDictionary *row, NSString *side) {
    NSMutableDictionary *value = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"state", @"pid", @"checkedAt", @"startSeconds", @"startMicroseconds"])
        if (row[key]) value[key] = row[key];
    if (row[side]) value[side] = row[side];
    for (NSString *suffix in @[@"Skip", @"PlanSkip", @"ExecutionSkip", @"ExecutionOutcome", @"ExecutorRan",
        @"Target", @"Action", @"CheckedAt", @"Observed", @"ObservedAt", @"ReadStartedAt", @"Evidence", @"Error"] ) {
        NSString *key = [side stringByAppendingString:suffix];
        if (row[key]) value[key] = row[key];
    }
    return value;
}
static void resourceRow(NSDictionary *target, NSString *state, NSDictionary *detail) {
    NSString *key = VDTNiceRuleKey((VDTConfigType)[target[VDTConfigTypeKey] unsignedIntegerValue], target[VDTTargetNameKey]);
    if (!key) return;
    NSMutableDictionary *row = [@{@"state": state, @"pid": target[VDTTargetPidKey],
        @"checkedAt": resourceReceiptTime(), @"boot": resourceBoot ?: @"",
        @"type": target[VDTConfigTypeKey], @"identifier": target[VDTTargetNameKey],
        @"startSeconds": target[VDTTargetStartSecondsKey], @"startMicroseconds": target[VDTTargetStartMicrosecondsKey]} mutableCopy];
    if (detail) [row addEntriesFromDictionary:detail];
    // Same-instance recovery replaces its own error. Successful sibling
    // instances cannot conceal an unresolved error from another lifetime.
    if (!resourceRowsByInstance) resourceRowsByInstance = [NSMutableDictionary dictionary];
    NSMutableDictionary *instances = resourceRowsByInstance[key];
    if (!instances) { instances = [NSMutableDictionary dictionary]; resourceRowsByInstance[key] = instances; }
    NSString *instance = resourceInstance(target);
    if ([state isEqual:@"gone"]) [instances removeObjectForKey:instance];
    else instances[instance] = row;
    NSDictionary *selected = instances[instance] ?: instances.allValues.firstObject ?: row;
    NSArray *severity = @[@"store-error", @"conflict", @"partial", @"unverified", @"pending", @"unsupported"];
    NSUInteger rank = [severity indexOfObject:selected[@"state"]];
    for (NSDictionary *candidate in instances.allValues) {
        NSUInteger candidateRank = [severity indexOfObject:candidate[@"state"]];
        if (candidateRank < rank) { selected = candidate; rank = candidateRank; }
    }
    NSMutableDictionary *aggregate = [selected mutableCopy];
    if (instances.count > 1) aggregate[@"multipleInstances"] = @YES;
    aggregate[@"instanceCount"] = @(instances.count);
    // Keep the legacy overall representative, but select each side separately.
    // An instance with a priority conflict cannot conceal a sibling's memory failure.
    NSMutableDictionary *sides = [NSMutableDictionary dictionary];
    NSArray *ordered = [instances.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *side in @[@"memory", @"priority"]) {
        NSDictionary *worst = nil;
        NSUInteger worstRank = NSNotFound;
        for (NSString *key in ordered) {
            NSDictionary *candidate = instances[key];
            NSUInteger candidateRank = resourceReceiptRank(candidate, side);
            if (!worst || candidateRank < worstRank) { worst = candidate; worstRank = candidateRank; }
        }
        sides[side] = resourceSideReceipt(worst ?: row, side);
    }
    if (instances.count > 1) aggregate[@"sideReceipts"] = sides;
    resourceRows[key] = aggregate;
}
static void resourceForgetRetries(NSString *instance) {
    NSString *prefix = [instance stringByAppendingString:@":"];
    for (NSString *key in resourceAttempts.allKeys)
        if ([key hasPrefix:prefix]) [resourceAttempts removeObjectForKey:key];
    for (NSString *key in resourceDue.allKeys)
        if ([key hasPrefix:prefix]) [resourceDue removeObjectForKey:key];
}
static NSString *resourceAttemptKey(NSString *instance, NSString *side, VDTOpKind kind) {
    return [NSString stringWithFormat:@"%@:%@:%d", instance, side, (int)kind];
}
static void resourceRetry(NSString *key, int error) {
    NSUInteger count = [resourceAttempts[key] unsignedIntegerValue];
    if (count < 3 && error != EPERM && error != EACCES && error != ENOTSUP && error != EINVAL)
        resourceDue[key] = @(resourceNow() + (count == 1 ? 0.5 : 2.0));
    else [resourceDue removeObjectForKey:key];
}
static id resourceObserve(const VDTResourceBackend *backend, VDTResourceSystemContext *context, pid_t pid, BOOL memory) {
    if (memory) {
        VDTMemlimitPair pair = {};
        if (backend->getMemlimit && backend->getMemlimit(context, pid, &pair)) {
            id value = resourcePair(pair); return resourceValueValid(value, YES) ? value : nil;
        }
    } else {
        VDTJetsamObservation observation = {};
        if (backend->getPriority && backend->getPriority(context, pid, &observation)) {
            id value = @(observation.effectivePriority); return resourceValueValid(value, NO) ? value : nil;
        }
    }
    return nil;
}
static BOOL resourceExecuteSide(NSDictionary *target, NSMutableDictionary *record,
    const VDTApplyOp *op, NSString *name, NSString *instance, const VDTResourceBackend *backend,
    VDTResourceSystemContext *context, NSMutableDictionary *detail) {
    BOOL memory = [name isEqual:@"memory"], restore = op->kind == VDTOpKindRestoreMemory || op->kind == VDTOpKindRestorePriority;
    NSString *attemptKey = resourceAttemptKey(instance, name, op->kind);
    detail[[name stringByAppendingString:@"CheckedAt"]] = resourceReceiptTime();
    detail[[name stringByAppendingString:@"ExecutorRan"]] = @NO;
    detail[[name stringByAppendingString:@"Action"]] = restore ? @"restore" : @"apply";
    id receiptTarget = restore ? record[name][@"original"] : (memory ? resourcePair(op->pair) : @(op->priorityBand));
    if (receiptTarget) detail[[name stringByAppendingString:@"Target"]] = receiptTarget;
    NSUInteger count = [resourceAttempts[attemptKey] unsignedIntegerValue];
    if ([resourceDue[attemptKey] doubleValue] > resourceNow()) { detail[name] = @"pending"; return NO; }
    [resourceDue removeObjectForKey:attemptKey];
    NSNumber *readStartedAt = resourceReceiptTime();
    pid_t pid = [target[VDTTargetPidKey] intValue]; errno = 0;
    id current = resourceObserve(backend, context, pid, memory);
    int readError = errno;
    NSNumber *readRecordedAt = resourceReceiptTime();
    if (!current) {
        if (count < 3) resourceAttempts[attemptKey] = @(count + 1);
        resourceRetry(attemptKey, readError ?: EIO);
        detail[name] = @"read-failed";
        detail[[name stringByAppendingString:@"Error"]] = @(readError ?: EIO);
        detail[[name stringByAppendingString:@"ExecutionSkip"]] = @(VDTApplySkipReadbackFailed);
        return NO;
    }
    resourceReceiptRead(detail, name, current, readStartedAt, readRecordedAt, @"read-before-execution");
    NSMutableDictionary *side = [record[name] mutableCopy];
    if (side) {
        BOOL atLast = [current isEqual:side[@"last"]];
        BOOL atWanted = side[@"wanted"] && [current isEqual:side[@"wanted"]];
        if ([side[@"phase"] isEqual:@"restore-pending"] && atWanted) {
            [record removeObjectForKey:name]; resourceRecords[instance] = record;
            if (!record[@"memory"] && !record[@"priority"]) [resourceRecords removeObjectForKey:instance];
            [resourceAttempts removeObjectForKey:attemptKey];
            detail[name] = @"restored"; return resourcePersist();
        }
        if (!atLast && !atWanted) {
            detail[[name stringByAppendingString:@"ExecutionSkip"]] = @(VDTApplySkipConflict);
            detail[[name stringByAppendingString:@"Evidence"]] = @"read-before-conflict";
            side[@"phase"] = @"conflict"; record[name] = side; resourceRecords[instance] = record;
            resourcePersist(); detail[name] = @"conflict"; return NO;
        }
        // Reconcile a crash between SET and the final journal commit. Unknown
        // coercions deliberately remain conflict instead of guessing ownership.
        side[@"last"] = current;
    } else if (restore) { detail[name] = @"restore-pending"; return NO; }
    else side = [@{@"original": current, @"last": current, @"phase": @"verified"} mutableCopy];
    id wanted = restore ? side[@"original"] : (memory ? resourcePair(op->pair) : @(op->priorityBand));
    if (!restore && ![current isEqual:wanted] && [side[@"phase"] isEqual:@"unverified"] && [side[@"wanted"] isEqual:wanted]) {
        // A confirmed SET followed by a coerced/unavailable readback is never
        // retried on ordinary lifecycle events, including manager restart.
        detail[name] = @"unverified";
        detail[[name stringByAppendingString:@"Observed"]] = current;
        return NO;
    }
    if ([current isEqual:wanted]) {
        if (restore) [record removeObjectForKey:name];
        else { side[@"phase"] = @"verified"; [side removeObjectForKey:@"wanted"]; record[name] = side; }
        if (record[@"memory"] || record[@"priority"]) resourceRecords[instance] = record;
        else [resourceRecords removeObjectForKey:instance];
        detail[name] = restore ? @"restored" : @"applied"; detail[[name stringByAppendingString:@"Observed"]] = current;
        detail[[name stringByAppendingString:@"Evidence"]] = @"matched-without-set";
        [resourceAttempts removeObjectForKey:attemptKey]; return resourcePersist();
    }
    if (count >= 3) { detail[name] = @"pending"; return NO; }
    resourceAttempts[attemptKey] = @(count + 1);
    // Write-ahead journal: keep the first original across rule changes. If the
    // durable save fails, neither SET may run. Power-loss atomicity is not CAS.
    side[@"phase"] = restore ? @"restore-pending" : @"pending"; side[@"wanted"] = wanted;
    record[name] = side; resourceRecords[instance] = record;
    if (!resourcePersist()) { detail[name] = @"store-error"; return NO; }
    VDTApplyTarget bound = {};
    bound.pid = pid; bound.hasExpectedToken = true;
    bound.expected = (VDTProcessInstanceToken){[target[VDTTargetStartSecondsKey] unsignedLongLongValue],
        [target[VDTTargetStartMicrosecondsKey] unsignedLongLongValue]};
    if (memory) {
        bound.hasPriorPair = true; bound.priorPair = resourcePairCore(side[@"original"]);
        bound.hasLastPair = true; bound.lastPair = resourcePairCore(current);
    } else {
        bound.hasPriorPriority = true; bound.priorPriority = [side[@"original"] intValue];
        bound.hasLastPriority = true; bound.lastPriority = [current intValue];
    }
    VDTApplyProgram program = {}; program.pid = pid; program.opCount = 1; program.ops[0] = *op;
    NSNumber *executionStartedAt = resourceReceiptTime();
    errno = 0; VDTApplyReport report = VDTApplyExecute(&program, &bound, backend, context); int error = errno;
    NSNumber *executionRecordedAt = resourceReceiptTime();
    VDTApplyOutcome outcome = memory ? report.memoryOutcome : report.jetsamOutcome;
    VDTApplySkip skip = memory ? report.memorySkip : report.jetsamSkip;
    detail[[name stringByAppendingString:@"ExecutorRan"]] = @YES;
    detail[[name stringByAppendingString:@"ExecutionSkip"]] = @(skip);
    detail[[name stringByAppendingString:@"ExecutionOutcome"]] = @(outcome);
    detail[[name stringByAppendingString:@"Error"]] = @(error);
    BOOL hasAfter = memory ? report.afterMemlimit.hasValue : report.afterPriority.hasValue;
    id after = hasAfter ? (memory ? resourcePair(report.afterMemlimit.pair) : @(report.afterPriority.priority)) : nil;
    BOOL identity = report.identityPostMatched;
    BOOL validAfter = after && identity && resourceValueValid(after, memory);
    BOOL good = (outcome == VDTApplyOutcomeApplied || outcome == VDTApplyOutcomeRestored) &&
        validAfter && (!restore || [after isEqual:side[@"original"]]);
    if (good) {
        if (restore) [record removeObjectForKey:name];
        else { side[@"last"] = after; side[@"phase"] = @"verified"; [side removeObjectForKey:@"wanted"]; record[name] = side; }
        detail[name] = restore ? @"restored" : @"applied";
        [resourceAttempts removeObjectForKey:attemptKey];
    } else {
        if (after && identity && resourceValueValid(after, memory)) side[@"last"] = after;
        if (skip == VDTApplySkipConflict) { side[@"phase"] = @"conflict"; detail[name] = @"conflict"; }
        else if (outcome == VDTApplyOutcomeAppliedUnverified || outcome == VDTApplyOutcomeRestoreUnconfirmed ||
            outcome == VDTApplyOutcomeApplied || outcome == VDTApplyOutcomeRestored) {
            side[@"phase"] = restore ? @"restore-pending" : @"unverified"; detail[name] = @"unverified";
            // A successful write with mismatched readback is not an invitation
            // to force the requested band repeatedly over a system coercion.
        } else { detail[name] = @"pending"; resourceRetry(attemptKey, error ?: EIO); }
        record[name] = side;
    }
    if (skip == VDTApplySkipIdentity) {
        // Do not attach an operation's readback to an instance whose identity was lost.
        for (NSString *suffix in @[@"Observed", @"ObservedAt", @"ReadStartedAt"])
            [detail removeObjectForKey:[name stringByAppendingString:suffix]];
        detail[[name stringByAppendingString:@"Evidence"]] = @"identity-unavailable";
    } else if (validAfter) {
        resourceReceiptRead(detail, name, after, executionStartedAt, executionRecordedAt,
            good ? @"written-verified" : @"written-unconfirmed");
    } else {
        BOOL hasBefore = memory ? report.beforeMemlimit.hasValue : report.beforePriority.hasValue;
        id before = hasBefore ? (memory ? resourcePair(report.beforeMemlimit.pair) : @(report.beforePriority.priority)) : nil;
        if (before && report.identityPreMatched && resourceValueValid(before, memory))
            resourceReceiptRead(detail, name, before, executionStartedAt, executionRecordedAt,
                skip == VDTApplySkipConflict ? @"read-before-conflict" : @"read-before-execution");
    }
    if (record[@"memory"] || record[@"priority"]) resourceRecords[instance] = record;
    else [resourceRecords removeObjectForKey:instance];
    return resourcePersist() && good && identity;
}
static int32_t resourceDarwinMajor(void) {
    char release[96] = {}; size_t size = sizeof(release);
    if (sysctlbyname("kern.osrelease", release, &size, NULL, 0) || size < 2 || size > sizeof(release) || release[size - 1]) return 0;
    errno = 0; char *end = NULL; long major = strtol(release, &end, 10);
    return !errno && major > 0 && major <= INT32_MAX && end && *end == '.' ? (int32_t)major : 0;
}
void vdt_resource_reload(NSDictionary *prefs) {
    if (!resourceRows) resourceRows = [NSMutableDictionary dictionary]; else [resourceRows removeAllObjects];
    resourceRowsByInstance = [NSMutableDictionary dictionary];
    resourceAttempts = [NSMutableDictionary dictionary]; resourceDue = [NSMutableDictionary dictionary];
    resourceConfiguration = VDTResourceConfiguration(prefs); resourceWrites = VDTResourceWriteEnabled(prefs);
    resourceLoad();
    resourceControlError = 0;
    int error = 0; NSDictionary *request = resourceRead(VDT_NICE_REQUEST, &error);
    if (error == ENOENT) { resourcePaused = NO; resourceRestoreNonce = nil; }
    else if (error || ![request[@"version"] isEqual:@1] || ![request[@"boot"] isEqual:resourceBoot] ||
        !resourceText(request[@"nonce"], 80)) {
        resourcePaused = YES; resourceRestoreNonce = nil;
        resourceControlError = error ?: EINVAL;
    }
    else { resourcePaused = YES; resourceRestoreNonce = request[@"nonce"]; }
}
BOOL vdt_resource_apply(NSDictionary *rawTarget, const VDTMemoryRule *memory, const VDTJetsamRule *jetsam) {
    NSDictionary *target = resourceBound(rawTarget);
    if (!target) return NO;
    resourceLoad();
    if (!resourceLoaded || resourceStoreError || resourceControlError) { resourceRow(target, @"store-error", nil); return NO; }
    NSString *instance = resourceInstance(target);
    if (!resourceRecords[instance] && resourceRecords.count >= 2048) {
        // The writer and loader share one record limit. Reaching capacity must
        // reject only the new target, not poison restoration of existing ones.
        resourceRow(target, @"pending", @{@"recordLimit": @YES}); return NO;
    }
    NSMutableDictionary *record = [resourceRecords[instance] mutableCopy] ?: [@{@"target": target} mutableCopy];
    if (resourceGone(target)) {
        [resourceRecords removeObjectForKey:instance]; resourceForgetRetries(instance);
        resourceRow(target, @"gone", nil); return resourcePersist();
    }
    VDTApplyCapabilities capabilities = VDTResourceSystemCapabilities();
    // Backend access is not pinned to a model/build/kernel. The journal and
    // policy use the same Darwin generation solely for numeric band semantics.
    int32_t darwinMajor = resourceDarwin;
    if (!capabilities.restoreWriteback) { resourceRow(target, @"unsupported", nil); return YES; }
    VDTMemoryRule effectiveMemory = memory ? *memory : (VDTMemoryRule){};
    VDTJetsamRule effectivePriority = jetsam ? *jetsam : (VDTJetsamRule){};
    if (!resourceWrites || resourcePaused) {
        // Revocation is authorized by this lifetime's validated journal, not by
        // whether a newly edited rule still parses. Never let corrupt config
        // prevent a global off/removal request from undoing our own override.
        effectiveMemory = VDTMemoryRule(); effectivePriority = VDTJetsamRule();
        effectiveMemory.state = VDTPolicyRecordDisabled; effectivePriority.state = VDTPolicyRecordDisabled;
    }
    VDTApplyProgram program = VDTApplyBuildProgram([target[VDTTargetPidKey] intValue],
        &effectiveMemory, &effectivePriority, darwinMajor, record[@"memory"] != nil, record[@"priority"] != nil, capabilities);
    NSMutableDictionary *detail = [@{@"memorySkip": @(program.memorySkip), @"prioritySkip": @(program.jetsamSkip),
        @"memoryPlanSkip": @(program.memorySkip), @"priorityPlanSkip": @(program.jetsamSkip)} mutableCopy];
    if (!program.opCount) {
        NSString *state = (!resourceWrites || resourcePaused) ? @"write-disabled" :
            ((program.memorySkip == VDTApplySkipUnsupported || program.jetsamSkip == VDTApplySkipUnsupported) ? @"unsupported" : @"no-write");
        resourceRow(target, state, detail); return YES;
    }
    const VDTResourceBackend *backend = VDTResourceSystemBackend();
    if (!backend) { resourceRow(target, @"unsupported", detail); return YES; }
    VDTResourceSystemContext context = {target};
    BOOL settled = YES; NSUInteger successes = 0;
    for (unsigned index = 0; index < program.opCount; ++index) {
        NSString *name = program.ops[index].kind == VDTOpKindSetMemory || program.ops[index].kind == VDTOpKindRestoreMemory ? @"memory" : @"priority";
        BOOL success = resourceExecuteSide(target, record, &program.ops[index], name, instance, backend, &context, detail);
        successes += success ? 1 : 0; settled = settled && success;
        if (resourceStoreError) break; // Never continue after a lost durable commit.
    }
    NSString *state = resourceStoreError ? @"store-error" : settled ? @"applied" : successes ? @"partial" : @"pending";
    if (!resourceStoreError) {
        if (!settled && !successes && ([detail[@"memory"] isEqual:@"unverified"] || [detail[@"priority"] isEqual:@"unverified"])) state = @"unverified";
        if ([detail[@"memory"] isEqual:@"conflict"] || [detail[@"priority"] isEqual:@"conflict"]) state = @"conflict";
        if (settled && [(detail[@"memory"] ?: @"restored") isEqual:@"restored"] &&
            [(detail[@"priority"] ?: @"restored") isEqual:@"restored"]) state = @"restored";
    }
    resourceRow(target, state, detail); return settled;
}
void vdt_resource_reconcile(NSArray<NSDictionary *> *targets) {
    // Caller supplies a freshly resolved full snapshot. No PID cache here can
    // prove identity, and missing rules retire only their own resource records.
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *target in targets) {
        NSDictionary *bound = resourceBound(target);
        if (bound) [live addObject:resourceInstance(bound)];
    }
    for (NSString *instance in [resourceRecords.allKeys copy])
        if (![live containsObject:instance]) vdt_resource_apply(resourceRecords[instance][@"target"], NULL, NULL);
}
BOOL vdt_resource_restore_all(void) {
    if (!resourcePaused || !resourceRestoreNonce) return NO;
    for (NSString *instance in [resourceRecords.allKeys copy])
        vdt_resource_apply(resourceRecords[instance][@"target"], NULL, NULL);
    return resourceLoaded && !resourceStoreError && !resourceControlError && resourceRecords.count == 0;
}
NSTimeInterval vdt_resource_next_retry_delay(void) {
    double minimum = INFINITY;
    for (NSNumber *deadline in resourceDue.allValues) minimum = MIN(minimum, deadline.doubleValue);
    return isfinite(minimum) ? MAX(0.05, minimum - resourceNow()) : -1;
}
void vdt_resource_publish(void) {
    if (!resourceBoot || !resourceConfiguration) return;
    NSDictionary *receipt = @{@"version": @1, @"boot": resourceBoot, @"configuration": resourceConfiguration,
        @"recordCount": @(resourceRecords.count), @"storeError": @(resourceStoreError ?: resourceControlError), @"paused": @(resourcePaused),
        @"restoreNonce": resourceRestoreNonce ?: @"", @"rows": resourceRows ?: @{}};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:receipt format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || data.length > VDT_NICE_STORE_LIMIT) {
        // Keep the status file readable and explicit; never silently publish a
        // truncated receipt or report a success that lost its evidence.
        receipt = @{ @"version": @1, @"boot": resourceBoot, @"configuration": resourceConfiguration,
            @"recordCount": @(resourceRecords.count), @"storeError": @(EFBIG),
            @"paused": @(resourcePaused), @"restoreNonce": resourceRestoreNonce ?: @"", @"rows": @{} };
        data = [NSPropertyListSerialization dataWithPropertyList:receipt
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    }
    if (!data || data.length > VDT_NICE_STORE_LIMIT) return;
    VDTNiceStore store;
    if (VDTNiceStoreOpen(VDTResourceStateDirectory().fileSystemRepresentation, 1, &store)) return;
    int error = VDTNiceStoreWrite(&store, VDT_NICE_STATUS, data.bytes, data.length);
    VDTNiceStoreClose(&store);
    if (!error) notify_post(VDT_RESOURCE_STATUS_NN);
}
