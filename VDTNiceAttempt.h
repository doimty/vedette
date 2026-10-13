// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#ifndef VDT_NICE_ATTEMPT_H
#define VDT_NICE_ATTEMPT_H
#include "VDTNicePolicy.h"
#include <errno.h>
#include <math.h>

// At most the initial attempt and two delayed retries per instance/action and
// configuration generation. Deadlines use monotonic uptime, not wall time.
typedef struct {
    unsigned count;
    bool pending;
    double due;
} VDTNiceAttempt;
enum { VDTNiceAttemptLimit = 3 };

static inline bool VDTNiceAttemptAllowed(VDTNiceAttempt state, double now) {
    return isfinite(now) && now >= 0 &&
        (state.count == 0 || (state.pending && state.count < VDTNiceAttemptLimit && now >= state.due));
}
static inline bool VDTNiceFailureIsRetryable(VDTNiceOutcome outcome, int error) {
    if (outcome == VDTNiceIdentityUnavailable || outcome == VDTNiceVerifyFailed) return true;
    if (outcome != VDTNiceReadFailed && outcome != VDTNiceWriteFailed && outcome != VDTNiceStoreFailed) return false;
    // Permission/configuration errors and Conflict never become automatic writes.
    return error == EINTR || error == EAGAIN || error == EBUSY || error == EIO ||
        error == ETIMEDOUT || error == ENOMEM || error == ENOSPC;
}
static inline VDTNiceAttempt VDTNiceAttemptFinished(VDTNiceAttempt state, double now,
                                                   VDTNiceOutcome outcome, int error) {
    if (state.count < VDTNiceAttemptLimit) ++state.count;
    state.pending = state.count < VDTNiceAttemptLimit && VDTNiceFailureIsRetryable(outcome, error);
    state.due = state.pending ? now + (state.count == 1 ? 0.5 : 2.0) : 0;
    return state;
}
#endif
