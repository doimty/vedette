// Copyright (c) 2026 Vedette contributors.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef VDTJetsamPolicy_h
#define VDTJetsamPolicy_h
#include "VDTMemoryPolicy.h" // shared typed-input, record, plan and inheritance API
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    VDTJetsamModeInvalid = 0,
    VDTJetsamModeSystem, // no band and no SET(-1); not Idle
    VDTJetsamModeNamed,  // persist the semantic name, not its mapped number
    VDTJetsamModeRaw     // persist raw number AND its exact source Darwin major
} VDTJetsamMode;
typedef enum {
    VDTJetsamNamedInvalid = 0,
    VDTJetsamNamedIdle,
    VDTJetsamNamedBackground,
    VDTJetsamNamedMail,
    VDTJetsamNamedPhone,
    VDTJetsamNamedUISupport,
    VDTJetsamNamedForegroundSupport,
    VDTJetsamNamedForeground,
    VDTJetsamNamedAudioAndAccessory,
    VDTJetsamNamedConductor,
    VDTJetsamNamedDriverApple,
    VDTJetsamNamedHome,
    VDTJetsamNamedExecutive,
    VDTJetsamNamedImportant,
    VDTJetsamNamedCritical,
    VDTJetsamNamedMaximum,
    VDTJetsamNamedDefault,
    VDTJetsamNamedTelephony,
    VDTJetsamNamedElevatedInactive,
    VDTJetsamNamedIdleDeferred,
    VDTJetsamNamedBackgroundOpportunistic,
    VDTJetsamNamedFreezer,
    VDTJetsamNamedAgingBand1Stuck
} VDTJetsamNamedBand;

typedef enum {
    VDTJetsamBandInvalid = 0,
    VDTJetsamBandNamedDefined, // explicit intent, NOT a safe/recommended band list
    VDTJetsamBandManagedReserved,
    VDTJetsamBandUnnamedAdvanced,
    VDTJetsamBandInternal,
    VDTJetsamBandSpecialSet
} VDTJetsamBandClass;

typedef struct {
    VDTPolicyRecordState state;
    VDTPolicyInteger schema;
    VDTJetsamMode mode;
    VDTJetsamNamedBand named;
    VDTPolicyInteger rawBand;
    VDTPolicyInteger rawSourceDarwinMajor;
} VDTJetsamRuleInput;
typedef struct {
    VDTPolicyRecordState state;
    VDTPolicyParseStatus parseStatus;
    VDTJetsamMode mode;
    VDTJetsamNamedBand named;
    int32_t rawBand;
    int32_t rawSourceDarwinMajor;
} VDTJetsamRule;

typedef struct {
    VDTPolicyPlanStatus status;
    VDTPolicyPlanReason reason;
    bool priorOverride;
    VDTJetsamBandClass bandClass;
    bool hasBand; // false for System/unsupported/invalid/unknown OS/restoration
    int32_t band; // diagnostic raw value remains in the rule, not a blocked plan
} VDTJetsamPlan;

VDTJetsamRule VDTParseJetsamRule(const VDTJetsamRuleInput *input);
// MAX is known ONLY for the four explicitly verified target versions.
bool VDTJetsamMaxBand(int32_t targetDarwinMajor, int32_t *out);
VDTJetsamBandClass VDTClassifyJetsamBand(int32_t targetDarwinMajor, int32_t band);
// No syscall/ABI payload/assertion is emitted. Raw cannot silently migrate even
// between equal-scale Darwin versions. Advanced reserved/freezer/gap/internal
// and special SET values are retained for diagnosis but unsupported for plans.
VDTJetsamPlan VDTPlanJetsamRule(const VDTJetsamRule *rule,
    int32_t targetDarwinMajor, bool priorOverride);

#ifdef __cplusplus
}
#endif
#endif
