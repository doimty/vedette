// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef VDTMemoryPolicy_h
#define VDTMemoryPolicy_h
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define VDT_RESOURCE_POLICY_SCHEMA_VERSION 1

// The adapter must distinguish CFBoolean, missing/null, string, floating point
// and integers BEFORE calling C. No string coercion or atoi is performed here.
// Unsigned values not representable in int64_t must use Overflow, not a cast.
typedef enum {
    VDTPolicyInputInvalid = 0,
    VDTPolicyInputInteger,
    VDTPolicyInputBoolean,
    VDTPolicyInputNull,
    VDTPolicyInputString,
    VDTPolicyInputFloatingPoint,
    VDTPolicyInputOverflow
} VDTPolicyInputTag;
typedef struct {
    VDTPolicyInputTag tag;
    int64_t value; // read only when tag == Integer
} VDTPolicyInteger;

typedef enum {
    VDTPolicyParseOK = 0,
    VDTPolicyParseInvalidArgument,
    VDTPolicyParseInvalidType,
    VDTPolicyParseOutOfRange,
    VDTPolicyParseUnknownSchema,
    VDTPolicyParseInvalidRecord,
    VDTPolicyParseUnknownMode
} VDTPolicyParseStatus;

typedef enum {
    VDTPolicyRecordMissing = 0, // only this permits inheritance
    VDTPolicyRecordDisabled,
    VDTPolicyRecordEnabled,
    VDTPolicyRecordInvalid    // present, invalid override; never inherit
} VDTPolicyRecordState;

typedef enum {
    VDTPolicyPlanInvalid = 0,
    VDTPolicyPlanNoWrite,
    VDTPolicyPlanReady,       // abstract intent only, NOT applied/device support
    VDTPolicyPlanUnsupported,
    VDTPolicyPlanReadOnly,
    VDTPolicyPlanRestoreRequired
} VDTPolicyPlanStatus;
typedef enum {
    VDTPolicyReasonNone = 0,
    VDTPolicyReasonInvalidInput,
    VDTPolicyReasonUnknownTargetOS,
    VDTPolicyReasonUnlimitedUnverified,
    VDTPolicyReasonMixedSystemUnverified,
    VDTPolicyReasonRestoreUnverified,
    VDTPolicyReasonRawVersionMismatch,
    VDTPolicyReasonUnknownSourceOS,
    VDTPolicyReasonManagedBand,
    VDTPolicyReasonUnnamedBand,
    VDTPolicyReasonInternalBand,
    VDTPolicyReasonSpecialSetValue,
    VDTPolicyReasonNamedBandUnavailable
} VDTPolicyPlanReason;

VDTPolicyParseStatus VDTPolicyReadInt32(VDTPolicyInteger input, int32_t *out);
bool VDTPolicyDarwinMajorIsKnown(int32_t targetDarwinMajor);

typedef enum {
    VDTMemoryModeInvalid = 0,
    VDTMemoryModeSystem,
    VDTMemoryModeUnlimited,
    VDTMemoryModeCustom
} VDTMemoryMode;
typedef struct {
    VDTMemoryMode mode;
    int32_t mib; // positive for Custom; ZERO for System/Unlimited, no XNU sentinel
} VDTMemoryLimit;
typedef struct {
    VDTPolicyRecordState state;
    VDTPolicyInteger schema;
    VDTPolicyInteger active;
    VDTPolicyInteger inactive;
} VDTMemoryRuleInput;
typedef struct {
    VDTPolicyRecordState state;
    VDTPolicyParseStatus parseStatus;
    VDTMemoryLimit active;
    VDTMemoryLimit inactive;
} VDTMemoryRule;

VDTPolicyParseStatus VDTParseMemoryLimit(VDTPolicyInteger input, VDTMemoryLimit *out);
VDTMemoryRule VDTParseMemoryRule(const VDTMemoryRuleInput *input);

typedef struct {
    VDTPolicyPlanStatus status;
    VDTPolicyPlanReason reason;
    bool priorOverride; // evidence remains owned by instance engine; never cleared
    bool hasCustomPair;
    int32_t activeMiB;
    int32_t inactiveMiB;
} VDTMemoryPlan;
// A two-sided hard-limit intent exists ONLY for Custom/Custom. No kernel flags,
// PID, callbacks or syscall are exposed. Mixed System/Custom needs M2 ABI proof.
// System/disabled/missing on a previously managed instance needs verified
// restoration, not a SET of 0/-1 or a deletion masquerading as restored.
VDTMemoryPlan VDTPlanMemoryRule(const VDTMemoryRule *rule,
    int32_t targetDarwinMajor, bool priorOverride);

// Independent selection AFTER the caller has validated extension identity.
// Existing CPU, PID/path/start-time validation and resolution are not replaced.
typedef enum {
    VDTPolicyOriginNone = 0,
    VDTPolicyOriginApp,
    VDTPolicyOriginExtension
} VDTPolicyRuleOrigin;
typedef struct {
    VDTPolicyRuleOrigin origin;
    VDTPolicyRecordState state;
} VDTResourceRuleSelection;
typedef struct {
    VDTPolicyRecordState cpu;
    VDTPolicyRecordState memory;
    VDTPolicyRecordState jetsam;
} VDTResourceRecordStates;
typedef struct {
    VDTResourceRuleSelection cpu;
    VDTResourceRuleSelection memory;
    VDTResourceRuleSelection jetsam;
} VDTResourceRuleSelections;
VDTResourceRuleSelection VDTSelectResourceRule(bool extensionIdentityValid,
    VDTPolicyRecordState app, VDTPolicyRecordState extension);
VDTResourceRuleSelections VDTSelectResourceRules(bool extensionIdentityValid,
    VDTResourceRecordStates app, VDTResourceRecordStates extension);

#ifdef __cplusplus
}
#endif
#endif
