#include "VDTNicePolicy.h"

#include <string.h>

bool VDTNiceValueIsValid(int value) {
    return value >= VDT_NICE_MIN_VALUE && value <= VDT_NICE_MAX_VALUE;
}

bool VDTNiceRecordIsValid(const VDTNiceRecord *record) {
    if (!record) return false;
    if (!record->captured) {
        return record->originalValue == 0 && !record->ownsValue &&
            record->ownedValue == 0 && !record->hasIntent &&
            record->intentValue == 0;
    }
    if (!VDTNiceValueIsValid(record->originalValue)) return false;
    if (record->ownsValue) {
        if (!VDTNiceValueIsValid(record->ownedValue)) return false;
    } else if (record->ownedValue != 0) {
        return false;
    }
    if (record->hasIntent) {
        if (!VDTNiceValueIsValid(record->intentValue)) return false;
    } else if (record->intentValue != 0) {
        return false;
    }
    return true;
}

static VDTNiceResult resultFor(VDTNiceOutcome outcome) {
    VDTNiceResult result = {
        .outcome = outcome,
        .error = 0,
        .observedValid = false,
        .observedValue = 0,
    };
    return result;
}

static void observe(VDTNiceResult *result, int value) {
    result->observedValid = true;
    result->observedValue = value;
}

static bool recordsEqual(const VDTNiceRecord *left, const VDTNiceRecord *right) {
    return left->captured == right->captured &&
        left->originalValue == right->originalValue &&
        left->ownsValue == right->ownsValue &&
        left->ownedValue == right->ownedValue &&
        left->hasIntent == right->hasIntent &&
        left->intentValue == right->intentValue;
}

static bool saveCandidate(VDTNiceRecord *record,
                          const VDTNiceRecord *candidate,
                          const VDTNiceOperations *operations,
                          VDTNiceResult *result) {
    int error = operations->saveRecord(candidate, operations->context);
    if (error != 0) {
        result->outcome = VDTNiceStoreFailed;
        result->error = error;
        return false;
    }
    *record = *candidate;
    return true;
}

static bool removeRecord(VDTNiceRecord *record,
                         const VDTNiceOperations *operations,
                         VDTNiceResult *result) {
    int error = operations->saveRecord(NULL, operations->context);
    if (error != 0) {
        result->outcome = VDTNiceStoreFailed;
        result->error = error;
        return false;
    }
    memset(record, 0, sizeof(*record));
    return true;
}

// Called immediately before every kernel-facing read or write. Gone is the
// only identity state that permits retiring a captured record.
static bool identityIsCurrent(pid_t pid,
                              VDTNiceRecord *record,
                              const VDTNiceOperations *operations,
                              VDTNiceResult *result) {
    VDTNiceIdentity identity = operations->identity(pid, operations->context);
    if (identity == VDTNiceIdentityCurrent) return true;
    if (identity == VDTNiceIdentityGone) {
        if (record->captured && !removeRecord(record, operations, result)) return false;
        result->outcome = VDTNiceGone;
        return false;
    }
    // Only the two declared states have meaning. Corrupt/unknown callback
    // values fail closed exactly like an unavailable identity.
    result->outcome = VDTNiceIdentityUnavailable;
    return false;
}

static bool readCurrent(pid_t pid,
                        VDTNiceRecord *record,
                        const VDTNiceOperations *operations,
                        VDTNiceResult *result,
                        int *value) {
    if (!identityIsCurrent(pid, record, operations, result)) return false;
    int error = operations->readValue(pid, value, operations->context);
    if (error != 0) {
        result->outcome = VDTNiceReadFailed;
        result->error = error;
        return false;
    }
    observe(result, *value);
    if (!VDTNiceValueIsValid(*value)) {
        result->outcome = VDTNiceInvalid;
        return false;
    }
    return true;
}

static bool valueIsKnown(const VDTNiceRecord *record, int value) {
    return value == record->originalValue ||
        (record->ownsValue && value == record->ownedValue) ||
        (record->hasIntent && value == record->intentValue);
}

static bool readMatches(pid_t pid,
                        VDTNiceRecord *record,
                        const VDTNiceOperations *operations,
                        VDTNiceResult *result,
                        int expected) {
    int actual = 0;
    if (!readCurrent(pid, record, operations, result, &actual)) return false;
    if (actual != expected) {
        result->outcome = VDTNiceConflict;
        return false;
    }
    return true;
}

static VDTNiceResult applyEnabled(pid_t pid,
                                 int desired,
                                 VDTNiceRecord *record,
                                 const VDTNiceOperations *operations) {
    VDTNiceResult result = resultFor(VDTNiceInvalid);
    int current = 0;
    if (!readCurrent(pid, record, operations, &result, &current)) return result;

    bool wasCaptured = record->captured;
    if (wasCaptured && !valueIsKnown(record, current)) {
        result.outcome = VDTNiceConflict;
        return result;
    }

    // A no-op still has to durably capture the original value on first use.
    // If recovering an intent, it also commits the observed value and clears
    // that intent without inventing a future restore target.
    if (current == desired) {
        VDTNiceRecord candidate = wasCaptured ? *record : (VDTNiceRecord){0};
        if (!wasCaptured) {
            candidate.captured = true;
            candidate.originalValue = current;
        } else if (current == candidate.originalValue) {
            candidate.ownsValue = false;
            candidate.ownedValue = 0;
        } else {
            candidate.ownsValue = true;
            candidate.ownedValue = current;
        }
        candidate.hasIntent = false;
        candidate.intentValue = 0;
        if (!wasCaptured || !recordsEqual(record, &candidate)) {
            if (!saveCandidate(record, &candidate, operations, &result)) return result;
        }
        result.outcome = VDTNiceApplied;
        return result;
    }

    VDTNiceRecord intent = wasCaptured ? *record : (VDTNiceRecord){0};
    if (!wasCaptured) {
        intent.captured = true;
        intent.originalValue = current;
    }
    // Preserve the first original, but promote a currently observed known
    // non-original value before replacing any older pending intent.
    if (current != intent.originalValue) {
        intent.ownsValue = true;
        intent.ownedValue = current;
    }
    intent.hasIntent = true;
    intent.intentValue = desired;
    if (!saveCandidate(record, &intent, operations, &result)) return result;

    // Guard against a value change between the initial observation and the
    // intent-backed write. The intent remains durable if this conflicts.
    if (!readMatches(pid, record, operations, &result, current)) return result;
    if (!identityIsCurrent(pid, record, operations, &result)) return result;
    int error = operations->writeValue(pid, desired, operations->context);
    if (error != 0) {
        result.outcome = VDTNiceWriteFailed;
        result.error = error;
        return result;
    }

    int readback = 0;
    if (!readCurrent(pid, record, operations, &result, &readback)) return result;
    if (readback != desired) {
        result.outcome = VDTNiceVerifyFailed;
        return result;
    }

    VDTNiceRecord committed = *record;
    committed.hasIntent = false;
    committed.intentValue = 0;
    if (desired == committed.originalValue) {
        committed.ownsValue = false;
        committed.ownedValue = 0;
    } else {
        committed.ownsValue = true;
        committed.ownedValue = desired;
    }
    if (!saveCandidate(record, &committed, operations, &result)) return result;
    result.outcome = VDTNiceApplied;
    return result;
}

static VDTNiceResult restoreDisabled(pid_t pid,
                                    VDTNiceRecord *record,
                                    const VDTNiceOperations *operations) {
    VDTNiceResult result = resultFor(VDTNiceInvalid);
    int current = 0;
    if (!readCurrent(pid, record, operations, &result, &current)) return result;

    if (current == record->originalValue) {
        if (!removeRecord(record, operations, &result)) return result;
        result.outcome = VDTNiceRestored;
        return result;
    }
    if (!valueIsKnown(record, current)) {
        result.outcome = VDTNiceConflict;
        return result;
    }
    if (!operations->writeValue) {
        result.outcome = VDTNiceInvalid;
        return result;
    }

    VDTNiceRecord intent = *record;
    // Keep the currently observed value recoverable before replacing intent.
    if (current != intent.originalValue) {
        intent.ownsValue = true;
        intent.ownedValue = current;
    }
    intent.hasIntent = true;
    intent.intentValue = intent.originalValue;
    if (!record->hasIntent || !recordsEqual(record, &intent)) {
        if (!saveCandidate(record, &intent, operations, &result)) return result;
    }

    if (!readMatches(pid, record, operations, &result, current)) return result;
    if (!identityIsCurrent(pid, record, operations, &result)) return result;
    int error = operations->writeValue(pid, record->originalValue, operations->context);
    if (error != 0) {
        result.outcome = VDTNiceWriteFailed;
        result.error = error;
        return result;
    }

    int readback = 0;
    if (!readCurrent(pid, record, operations, &result, &readback)) return result;
    if (readback != record->originalValue) {
        result.outcome = VDTNiceVerifyFailed;
        return result;
    }
    if (!removeRecord(record, operations, &result)) return result;
    result.outcome = VDTNiceRestored;
    return result;
}

VDTNiceResult VDTNiceTransition(pid_t pid,
                               bool enabled,
                               int desired,
                               VDTNiceRecord *record,
                               const VDTNiceOperations *operations) {
    VDTNiceResult result = resultFor(VDTNiceInvalid);
    if (pid <= 0 || !record || !VDTNiceRecordIsValid(record)) return result;
    if (enabled && !VDTNiceValueIsValid(desired)) return result;

    // Disabling an unmanaged process is deliberately a complete no-op, even
    // when no callbacks were supplied by the runtime.
    if (!enabled && !record->captured) {
        result.outcome = VDTNiceUnmanaged;
        return result;
    }
    if (!operations || !operations->identity || !operations->readValue ||
        !operations->saveRecord) {
        return result;
    }
    if (enabled && !operations->writeValue) return result;

    if (enabled) return applyEnabled(pid, desired, record, operations);
    return restoreDisabled(pid, record, operations);
}
