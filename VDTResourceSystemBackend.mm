// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTResourceSystemBackend.h"
#import "VDTResourceSystemIO.h"
#import "VDTProcessManager.h"
#include <errno.h>
#include <string.h>
#include <sys/sysctl.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#include <TargetConditionals.h>
extern "C" int memorystatus_control(uint32_t, int32_t, uint32_t, void *, size_t);
static int32_t systemDarwinMajor(void) {
    char release[96] = {}; size_t length = sizeof(release);
    if (sysctlbyname("kern.osrelease", release, &length, NULL, 0) || length < 2 || length > sizeof(release) || release[length - 1]) return 0;
    errno = 0; char *end = NULL; long major = strtol(release, &end, 10);
    return !errno && end && *end == '.' && major > 0 && major <= INT32_MAX ? (int32_t)major : 0;
}
static bool supported(void *unused) {
    (void)unused;
#if (defined(__arm64__) || defined(__aarch64__)) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    // All native iOS devices may use the backend; no model/build/kernel pin.
    // Entitlement or kernel rejection is reported by the operation itself.
    return geteuid() == 0;
#else
    return false;
#endif
}
static bool identity(void *opaque, pid_t pid) {
    VDTResourceSystemContext *context = (VDTResourceSystemContext *)opaque;
    NSDictionary *target = context ? context->target : nil;
    if (!target || [target[VDTTargetPidKey] intValue] != pid || pid <= 1 || pid == getpid()) { errno = EINVAL; return false; }
    NSString *path = target[VDTTargetExecutablePathKey], *name = target[VDTTargetNameKey];
    if ([path isEqual:@"/usr/libexec/runningboardd"] || [name isEqual:@"com.apple.Preferences"] ||
        [path containsString:@"/Preferences.app/"]) { errno = EPERM; return false; }
    if (!vdt_target_is_current(target)) { errno = ESTALE; return false; }
    return true;
}
static bool readToken(void *opaque, pid_t pid, VDTProcessInstanceToken *out) {
    if (!out || !identity(opaque, pid)) return false;
    struct vdt_proc_bsdinfo info = {}; errno = 0;
    int result = proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    VDTProcessInstanceToken value = {info.pbi_start_tvsec, info.pbi_start_tvusec};
    if (result != sizeof(info) || info.pbi_pid != (uint32_t)pid || !VDTProcessInstanceTokenIsValid(value) || !identity(opaque, pid)) return false;
    *out = value; return true;
}
static int systemControl(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t bytes) {
#if (defined(__arm64__) || defined(__aarch64__)) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    return memorystatus_control(command, pid, flags, buffer, bytes);
#else
    (void)command; (void)pid; (void)flags; (void)buffer; (void)bytes;
    errno = ENOTSUP; return -1;
#endif
}
static VDTResourceSystemIO systemIO(void *context) {
    return (VDTResourceSystemIO){context, getpid(), supported, identity, readToken, systemControl, systemDarwinMajor()};
}
static bool getMemory(void *context, pid_t pid, VDTMemlimitPair *out) {
    VDTResourceSystemIO io = systemIO(context); return VDTResourceKernelBackend()->getMemlimit(&io, pid, out);
}
static bool setMemory(void *context, pid_t pid, const VDTMemlimitPair *pair) {
    VDTResourceSystemIO io = systemIO(context); return VDTResourceKernelBackend()->setMemlimit(&io, pid, pair);
}
static bool getPriority(void *context, pid_t pid, VDTJetsamObservation *out) {
    VDTResourceSystemIO io = systemIO(context); return VDTResourceKernelBackend()->getPriority(&io, pid, out);
}
static bool setPriority(void *context, pid_t pid, int32_t band) {
    VDTResourceSystemIO io = systemIO(context); return VDTResourceKernelBackend()->setPriority(&io, pid, band);
}
static bool getToken(void *context, pid_t pid, VDTProcessInstanceToken *out) {
    VDTResourceSystemIO io = systemIO(context); return VDTResourceKernelBackend()->getInstanceToken(&io, pid, out);
}
VDTApplyCapabilities VDTResourceSystemCapabilities(void) {
    bool enabled = supported(NULL);
    return (VDTApplyCapabilities){enabled, enabled, enabled, enabled};
}
const VDTResourceBackend *VDTResourceSystemBackend(void) {
    static const VDTResourceBackend backend = {"native-ios-memorystatus", getMemory, setMemory, getPriority, setPriority, getToken};
    return &backend;
}
