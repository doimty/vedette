//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTShared.h"

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>

#ifdef __cplusplus
extern "C" {
#endif

// Thread-safe prefs accessors. Use instead of direct global access.
void VDTSetPrefs(NSDictionary *newPrefs);
NSDictionary *VDTGetPrefs(void);

// Keys of a normalised config entry (vdt_configs_from_prefs) and of a resolved
// target (vdt_resolve_targets / vdt_targets_for_pid).
extern NSString * const VDTConfigIdentifierKey;
extern NSString * const VDTConfigTypeKey;
extern NSString * const VDTConfigPercentageKey;
extern NSString * const VDTConfigIntervalKey;
extern NSString * const VDTConfigPolicyKey;
extern NSString * const VDTConfigEnabledKey;
extern NSString * const VDTTargetPidKey;
extern NSString * const VDTTargetNameKey;
extern NSString * const VDTTargetExecutablePathKey;
extern NSString * const VDTTargetProcCommKey;
extern NSString * const VDTTargetStartSecondsKey;
extern NSString * const VDTTargetStartMicrosecondsKey;
extern NSString * const VDTTargetMemoryRuleKey;
extern NSString * const VDTTargetJetsamRuleKey;
extern NSString * const VDTTargetContainingAppIdentifierKey;
extern NSString * const VDTTargetNiceSourceTypeKey;
extern NSString * const VDTTargetNiceSourceIdentifierKey;
extern NSString * const VDTTargetNiceSourceRevisionKey;

// Strict independent nice resolution; never uses CPU presence/enabled state.
// Extension targets retain their real identity; the containing App source is
// carried separately. These targets are for vdt_nice_apply, NOT vdt_apply_target.
NSArray<NSDictionary *> *vdt_nice_resolve_targets(NSDictionary *prefs);
NSArray<NSDictionary *> *vdt_nice_targets_for_pid(pid_t pid, NSDictionary *prefs);
// Hot paths consume a trusted VDTNiceRulesFromPrefs snapshot published on reload.
NSArray<NSDictionary *> *vdt_nice_resolve_targets_from_rules(NSDictionary *rules);
NSArray<NSDictionary *> *vdt_nice_targets_for_pid_from_rules(pid_t pid, NSDictionary *rules);

// Type-checked normalisation of the user-writable prefs plist. Entries without a
// valid identifier are dropped; entries with malformed parameters are retained
// as disabled so a reload can undo limits previously applied by Vedette. The
// global switch is folded into each entry's enabled flag.
NSArray<NSDictionary *>* vdt_configs_from_prefs(NSDictionary *prefs);

// Normalised resource rules (memoryRules / jetsamRules sections). Records keep
// their presence even when disabled or malformed so per-resource inheritance
// can be overridden deliberately; validation mirrors the frozen policy cores.
NSArray<NSDictionary *>* vdt_resource_rules_from_prefs(NSDictionary *prefs);

// Scans running processes and returns one target per configured process that is
// currently alive. Resource rules travel alongside the CPU configs so a
// memory-only or jetsam-only rule still resolves to its validated instance;
// each target carries its own percentage/interval/policy plus resource intents.
NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules);

// Same resolution for a single PID. Returns an empty array when the process is
// not configured, which means "leave it alone".
NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules);

// Revalidates only the PID + start-time lifetime token. This distinguishes a
// gone/reused PID from a temporarily unavailable path lookup during cleanup.
BOOL vdt_target_instance_is_current(NSDictionary *target);

// Revalidates the PID, process start time, and bound path/name of a target.
BOOL vdt_target_is_current(NSDictionary *target);

// Applies only the CPU transition and reports CPU success. A target with policy
// None or a zero percentage/interval restores CPU defaults. Resource work has
// an independent lifecycle, return value and journal; CPU dedup cannot skip it.
// Independently callable after resolution, including resource-only targets.
// Lifetime, write opt-in, precise kernel and durable restoration gates apply.
BOOL vdt_apply_resource_target(NSDictionary *target);
BOOL vdt_apply_target(NSDictionary *target);
void vdt_apply_targets(NSArray<NSDictionary *> *targets);

#ifdef __cplusplus
}
#endif
