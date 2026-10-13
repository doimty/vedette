#pragma once
// ABI-compatible fake kernel, deliberately test-only. Include real declarations
// before redirection; never weaken Store ownership or target identity checks.
#import <Foundation/Foundation.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <notify.h>
#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>
#ifdef __cplusplus
extern "C" {
#endif
int VDTTestGetPriority(int, id_t);
int VDTTestSetPriority(int, id_t, int);
int VDTTestPidPath(int, void *, uint32_t);
int VDTTestProcName(int, void *, uint32_t);
int VDTTestPidInfo(int, int, uint64_t, void *, int);
int VDTTestListPids(uint32_t, uint32_t, void *, int);
int VDTTestCPUOne(int);
int VDTTestCPUThree(int, int, int);
int VDTTestSysctl(const char *, void *, size_t *, void *, size_t);
uint32_t VDTTestNotifyPost(const char *);
uint32_t VDTTestNotifyRegister(const char *, int *);
uint32_t VDTTestNotifySet(int, uint64_t);
uint32_t VDTTestNotifyGet(int, uint64_t *);
uint32_t VDTTestNotifyCancel(int);
uint32_t VDTTestNotifyDispatch(const char *, int *, dispatch_queue_t, void (^)(int));
void VDTTestCFPost(CFNotificationCenterRef, CFStringRef, const void *, CFDictionaryRef, Boolean);
void VDTTestCFObserve(CFNotificationCenterRef, const void *, CFNotificationCallback, CFStringRef, const void *, CFNotificationSuspensionBehavior);
void VDTTestAsync(dispatch_queue_t, dispatch_block_t);
void VDTTestAfter(dispatch_time_t, dispatch_queue_t, dispatch_block_t);
#ifdef __cplusplus
}
#endif
#define getpriority VDTTestGetPriority
#define setpriority VDTTestSetPriority
#define proc_pidpath VDTTestPidPath
#define proc_name VDTTestProcName
#define proc_pidinfo VDTTestPidInfo
#define proc_listpids VDTTestListPids
#define proc_clear_cpulimits VDTTestCPUOne
#define proc_disable_cpumon VDTTestCPUOne
#define proc_set_cpumon_defaults VDTTestCPUOne
#define proc_resume_cpumon VDTTestCPUOne
#define proc_setcpu_percentage VDTTestCPUThree
#define proc_set_cpumon_params_fatal VDTTestCPUThree
#define sysctlbyname VDTTestSysctl
#define notify_post VDTTestNotifyPost
#define notify_register_check VDTTestNotifyRegister
#define notify_set_state VDTTestNotifySet
#define notify_get_state VDTTestNotifyGet
#define notify_cancel VDTTestNotifyCancel
#define notify_register_dispatch VDTTestNotifyDispatch
#define CFNotificationCenterPostNotification VDTTestCFPost
#define CFNotificationCenterAddObserver VDTTestCFObserve
#define dispatch_async VDTTestAsync
#define dispatch_after VDTTestAfter
