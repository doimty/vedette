#include "../VDTNicePolicy.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

enum { EventIdentity = 'I', EventRead = 'R', EventWrite = 'W', EventSave = 'S' };

typedef struct {
    int kernelValue;
    int identityCalls;
    VDTNiceIdentity identityAt[16];
    int readCalls;
    int readErrorAt;
    int readError;
    int readOverrideAt;
    int readOverrideValue;
    int writeCalls;
    int writeError;
    bool suppressWrite;
    int lastWriteValue;
    int saveCalls;
    int saveErrorAt;
    int saveError;
    bool hasStoredRecord;
    VDTNiceRecord storedRecord;
    char events[128];
    size_t eventCount;
} Fake;

static void event(Fake *fake, char value) {
    assert(fake->eventCount + 1 < sizeof(fake->events));
    fake->events[fake->eventCount++] = value;
    fake->events[fake->eventCount] = '\0';
}

static VDTNiceIdentity fakeIdentity(pid_t pid, void *context) {
    Fake *fake = context;
    assert(pid == 42);
    event(fake, EventIdentity);
    fake->identityCalls++;
    if (fake->identityCalls < (int)(sizeof(fake->identityAt) /
                                     sizeof(fake->identityAt[0]))) {
        return fake->identityAt[fake->identityCalls];
    }
    return VDTNiceIdentityCurrent;
}

static int fakeRead(pid_t pid, int *value, void *context) {
    Fake *fake = context;
    assert(pid == 42);
    event(fake, EventRead);
    fake->readCalls++;
    if (fake->readCalls == fake->readErrorAt) return fake->readError;
    *value = fake->readCalls == fake->readOverrideAt ?
        fake->readOverrideValue : fake->kernelValue;
    return 0;
}

static int fakeWrite(pid_t pid, int value, void *context) {
    Fake *fake = context;
    assert(pid == 42);
    event(fake, EventWrite);
    fake->writeCalls++;
    fake->lastWriteValue = value;
    if (fake->writeError) return fake->writeError;
    if (!fake->suppressWrite) fake->kernelValue = value;
    return 0;
}

static int fakeSave(const VDTNiceRecord *record, void *context) {
    Fake *fake = context;
    event(fake, EventSave);
    fake->saveCalls++;
    if (fake->saveCalls == fake->saveErrorAt) return fake->saveError;
    if (!record) {
        fake->hasStoredRecord = false;
        memset(&fake->storedRecord, 0, sizeof(fake->storedRecord));
    } else {
        fake->hasStoredRecord = true;
        fake->storedRecord = *record;
    }
    return 0;
}

static VDTNiceOperations operations(Fake *fake) {
    VDTNiceOperations result = {
        .identity = fakeIdentity,
        .readValue = fakeRead,
        .writeValue = fakeWrite,
        .saveRecord = fakeSave,
        .context = fake,
    };
    return result;
}

static void expectEvents(const Fake *fake, const char *expected) {
    if (strcmp(fake->events, expected) != 0) {
        fprintf(stderr, "event trace mismatch: got <%s>, expected <%s>\\n",
                fake->events, expected);
    }
    assert(strcmp(fake->events, expected) == 0);
}

static void expectRecord(const VDTNiceRecord *actual,
                         const VDTNiceRecord *expected) {
    assert(actual->captured == expected->captured);
    assert(actual->originalValue == expected->originalValue);
    assert(actual->ownsValue == expected->ownsValue);
    assert(actual->ownedValue == expected->ownedValue);
    assert(actual->hasIntent == expected->hasIntent);
    assert(actual->intentValue == expected->intentValue);
}

static void seed(Fake *fake, const VDTNiceRecord *record) {
    fake->hasStoredRecord = true;
    fake->storedRecord = *record;
}

static void test_value_and_record_boundaries(void) {
    assert(VDTNiceValueIsValid(-20));
    assert(VDTNiceValueIsValid(-1));
    assert(VDTNiceValueIsValid(0));
    assert(VDTNiceValueIsValid(20));
    assert(!VDTNiceValueIsValid(-21));
    assert(!VDTNiceValueIsValid(21));
    VDTNiceRecord zero = {0};
    VDTNiceRecord valid = {.captured = true, .originalValue = -20};
    VDTNiceRecord bad = {.captured = true, .originalValue = 21};
    assert(VDTNiceRecordIsValid(&zero));
    assert(VDTNiceRecordIsValid(&valid));
    assert(!VDTNiceRecordIsValid(&bad));
    bad = (VDTNiceRecord){.ownsValue = true, .ownedValue = 1};
    assert(!VDTNiceRecordIsValid(&bad));
    assert(!VDTNiceRecordIsValid(NULL));
}

static void test_invalid_arguments_are_side_effect_free(void) {
    Fake fake = {.kernelValue = -1};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    assert(VDTNiceTransition(0, true, 0, &record, &ops).outcome == VDTNiceInvalid);
    assert(VDTNiceTransition(-1, true, 0, &record, &ops).outcome == VDTNiceInvalid);
    assert(VDTNiceTransition(42, true, -21, &record, &ops).outcome == VDTNiceInvalid);
    assert(VDTNiceTransition(42, true, 21, &record, &ops).outcome == VDTNiceInvalid);
    VDTNiceRecord malformed = {.captured = true, .originalValue = 99};
    assert(VDTNiceTransition(42, true, 0, &malformed, &ops).outcome == VDTNiceInvalid);
    assert(VDTNiceTransition(42, true, 0, NULL, &ops).outcome == VDTNiceInvalid);
    assert(VDTNiceTransition(42, true, 0, &record, NULL).outcome == VDTNiceInvalid);
    assert(fake.eventCount == 0);
    assert(fake.identityCalls == 0 && fake.readCalls == 0 &&
           fake.writeCalls == 0 && fake.saveCalls == 0);
}

static void test_unmanaged_and_noop_capture(void) {
    Fake fake = {.kernelValue = 0};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, false, 123, &record, NULL);
    assert(result.outcome == VDTNiceUnmanaged);
    expectEvents(&fake, "");

    result = VDTNiceTransition(42, true, 0, &record, &ops);
    assert(result.outcome == VDTNiceApplied);
    assert(result.observedValid && result.observedValue == 0);
    assert(record.captured && record.originalValue == 0);
    assert(!record.ownsValue && !record.hasIntent);
    assert(fake.writeCalls == 0 && fake.saveCalls == 1);
    expectEvents(&fake, "IRS");

    fake.eventCount = 0;
    fake.events[0] = '\0';
    result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceRestored);
    assert(!record.captured && !fake.hasStoredRecord);
    assert(fake.writeCalls == 0);
    expectEvents(&fake, "IRS");
}

static void test_boundary_desired_values(void) {
    const int values[] = {-20, -1, 0, 20};
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        Fake fake = {.kernelValue = -1};
        VDTNiceOperations ops = operations(&fake);
        VDTNiceRecord record = {0};
        VDTNiceResult result = VDTNiceTransition(42, true, values[i], &record, &ops);
        assert(result.outcome == VDTNiceApplied);
        assert(record.captured && record.originalValue == -1);
        assert(fake.kernelValue == values[i]);
        if (values[i] == -1) {
            assert(fake.writeCalls == 0 && !record.ownsValue);
        } else {
            assert(record.ownsValue && record.ownedValue == values[i]);
        }
        result = VDTNiceTransition(42, false, 0, &record, &ops);
        assert(result.outcome == VDTNiceRestored);
        assert(fake.kernelValue == -1 && !record.captured);
    }
}

static void test_first_set_update_restore_preserves_original(void) {
    Fake fake = {.kernelValue = -1};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, 8, &record, &ops);
    assert(result.outcome == VDTNiceApplied);
    assert(fake.kernelValue == 8 && record.originalValue == -1);
    assert(record.ownsValue && record.ownedValue == 8 && !record.hasIntent);
    expectEvents(&fake, "IRSIRIWIRS");

    fake.eventCount = 0;
    fake.events[0] = '\0';
    result = VDTNiceTransition(42, true, -4, &record, &ops);
    assert(result.outcome == VDTNiceApplied);
    assert(fake.kernelValue == -4 && record.originalValue == -1);
    assert(record.ownsValue && record.ownedValue == -4 && !record.hasIntent);
    assert(fake.saveCalls == 4);
    fake.eventCount = 0;
    fake.events[0] = '\0';

    result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceRestored);
    assert(fake.kernelValue == -1 && !record.captured);
    assert(!fake.hasStoredRecord);
    expectEvents(&fake, "IRSIRIWIRS");
}

static void test_noop_on_managed_record_does_not_write(void) {
    Fake fake = {.kernelValue = 5};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {
        .captured = true, .originalValue = -1,
        .ownsValue = true, .ownedValue = 5,
    };
    seed(&fake, &record);
    VDTNiceResult result = VDTNiceTransition(42, true, 5, &record, &ops);
    assert(result.outcome == VDTNiceApplied);
    assert(fake.writeCalls == 0 && fake.saveCalls == 0);
    expectEvents(&fake, "IR");
}

static void test_identity_unavailable_at_every_apply_gate(void) {
    for (int rejected = 1; rejected <= 4; rejected++) {
        Fake fake = {.kernelValue = -3};
        fake.identityAt[rejected] = VDTNiceIdentityUnavailableValue;
        VDTNiceOperations ops = operations(&fake);
        VDTNiceRecord record = {0};
        VDTNiceResult result = VDTNiceTransition(42, true, 7, &record, &ops);
        assert(result.outcome == VDTNiceIdentityUnavailable);
        assert(fake.identityCalls == rejected);
        assert(fake.writeCalls == (rejected == 4 ? 1 : 0));
        if (rejected == 1) assert(!record.captured);
        else assert(record.captured && record.hasIntent && record.intentValue == 7);
    }
}

static void test_identity_unavailable_at_every_restore_gate(void) {
    for (int rejected = 1; rejected <= 4; rejected++) {
        Fake fake = {.kernelValue = 4};
        VDTNiceRecord record = {
            .captured = true, .originalValue = -5,
            .ownsValue = true, .ownedValue = 4,
        };
        seed(&fake, &record);
        fake.identityAt[rejected] = VDTNiceIdentityUnavailableValue;
        VDTNiceOperations ops = operations(&fake);
        VDTNiceResult result = VDTNiceTransition(42, false, 0, &record, &ops);
        assert(result.outcome == VDTNiceIdentityUnavailable);
        assert(fake.identityCalls == rejected);
        assert(fake.writeCalls == (rejected == 4 ? 1 : 0));
        assert(record.captured);
        if (rejected >= 2) assert(record.hasIntent && record.intentValue == -5);
    }
}

static void test_unknown_identity_enum_fails_closed(void) {
    // Unknown enum values are never interpreted as Current or Gone.
    Fake beforeRead = {.kernelValue = -2};
    beforeRead.identityAt[1] = (VDTNiceIdentity)99;
    VDTNiceOperations ops = operations(&beforeRead);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, 5, &record, &ops);
    assert(result.outcome == VDTNiceIdentityUnavailable);
    assert(beforeRead.readCalls == 0 && beforeRead.writeCalls == 0);
    assert(beforeRead.saveCalls == 0 && !record.captured);

    // Unknown at the second guard keeps the already persisted intent and does
    // not perform the write.
    Fake beforeWrite = {.kernelValue = -2};
    beforeWrite.identityAt[2] = (VDTNiceIdentity)-1;
    ops = operations(&beforeWrite);
    record = (VDTNiceRecord){0};
    result = VDTNiceTransition(42, true, 5, &record, &ops);
    assert(result.outcome == VDTNiceIdentityUnavailable);
    assert(record.captured && record.hasIntent && record.intentValue == 5);
    assert(beforeWrite.writeCalls == 0 && beforeWrite.saveCalls == 1);
}

static void test_gone_retires_only_existing_record(void) {
    Fake fake = {.kernelValue = 6};
    VDTNiceRecord record = {
        .captured = true, .originalValue = -2,
        .ownsValue = true, .ownedValue = 6,
    };
    seed(&fake, &record);
    fake.identityAt[1] = VDTNiceIdentityGone;
    VDTNiceOperations ops = operations(&fake);
    VDTNiceResult result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceGone);
    assert(!record.captured && !fake.hasStoredRecord);
    assert(fake.readCalls == 0 && fake.writeCalls == 0);
    expectEvents(&fake, "IS");
}

static void test_unavailable_and_gone_keep_or_remove_on_store_failure(void) {
    Fake fake = {.kernelValue = 2, .saveErrorAt = 1, .saveError = EIO};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, 3, &record, &ops);
    assert(result.outcome == VDTNiceStoreFailed && result.error == EIO);
    assert(!record.captured && fake.writeCalls == 0);

    fake = (Fake){.kernelValue = 2, .saveErrorAt = 1, .saveError = EIO};
    record = (VDTNiceRecord){.captured = true, .originalValue = 0};
    seed(&fake, &record);
    fake.identityAt[1] = VDTNiceIdentityGone;
    ops = operations(&fake);
    result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceStoreFailed && result.error == EIO);
    assert(record.captured && fake.hasStoredRecord);
    assert(fake.readCalls == 0 && fake.writeCalls == 0);
}

static void test_read_failures_at_each_read_stage(void) {
    for (int failedRead = 1; failedRead <= 3; failedRead++) {
        Fake fake = {.kernelValue = -2, .readErrorAt = failedRead, .readError = EIO};
        VDTNiceOperations ops = operations(&fake);
        VDTNiceRecord record = {0};
        VDTNiceResult result = VDTNiceTransition(42, true, 9, &record, &ops);
        assert(result.outcome == VDTNiceReadFailed && result.error == EIO);
        assert(fake.writeCalls == (failedRead == 3 ? 1 : 0));
        if (failedRead == 1) assert(!record.captured);
        else assert(record.captured && record.hasIntent);
    }
}

static void test_write_permission_and_verify_failures_keep_intent(void) {
    Fake fake = {.kernelValue = 1, .writeError = EPERM};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, -7, &record, &ops);
    assert(result.outcome == VDTNiceWriteFailed && result.error == EPERM);
    assert(fake.kernelValue == 1 && record.hasIntent && record.intentValue == -7);

    fake = (Fake){.kernelValue = 1, .suppressWrite = true};
    ops = operations(&fake);
    record = (VDTNiceRecord){0};
    result = VDTNiceTransition(42, true, -7, &record, &ops);
    assert(result.outcome == VDTNiceVerifyFailed);
    assert(fake.writeCalls == 1 && record.hasIntent && record.intentValue == -7);
}

static void test_guard_mismatch_conflicts_without_write(void) {
    Fake fake = {.kernelValue = 1, .readOverrideAt = 2, .readOverrideValue = 2};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, 9, &record, &ops);
    assert(result.outcome == VDTNiceConflict);
    assert(fake.writeCalls == 0 && record.hasIntent && record.intentValue == 9);
}

static void test_external_change_conflicts_for_set_and_restore(void) {
    Fake fake = {.kernelValue = 10};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {
        .captured = true, .originalValue = -1,
        .ownsValue = true, .ownedValue = 4,
    };
    seed(&fake, &record);
    VDTNiceResult result = VDTNiceTransition(42, true, 6, &record, &ops);
    assert(result.outcome == VDTNiceConflict);
    assert(fake.writeCalls == 0 && fake.saveCalls == 0);

    fake.eventCount = 0;
    fake.events[0] = '\0';
    result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceConflict);
    assert(fake.writeCalls == 0 && record.originalValue == -1);
}

static void test_store_failures_at_apply_stages(void) {
    for (int failedSave = 1; failedSave <= 2; failedSave++) {
        Fake fake = {.kernelValue = 0, .saveErrorAt = failedSave, .saveError = ENOSPC};
        VDTNiceOperations ops = operations(&fake);
        VDTNiceRecord record = {0};
        VDTNiceResult result = VDTNiceTransition(42, true, 5, &record, &ops);
        assert(result.outcome == VDTNiceStoreFailed && result.error == ENOSPC);
        if (failedSave == 1) {
            assert(!record.captured && fake.writeCalls == 0);
            assert(!fake.hasStoredRecord);
        } else {
            assert(record.captured && record.hasIntent && record.intentValue == 5);
            assert(fake.writeCalls == 1 && fake.kernelValue == 5);
            expectRecord(&fake.storedRecord, &record);
        }
    }
}

static void test_crash_recovery_before_and_after_write(void) {
    // Stop at the identity guard immediately before write: intent is durable,
    // kernel remains original, and a later call can safely apply a new value.
    Fake before = {.kernelValue = -2};
    before.identityAt[3] = VDTNiceIdentityUnavailableValue;
    VDTNiceOperations beforeOps = operations(&before);
    VDTNiceRecord beforeRecord = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, 7, &beforeRecord, &beforeOps);
    assert(result.outcome == VDTNiceIdentityUnavailable);
    assert(beforeRecord.hasIntent && before.kernelValue == -2 && before.writeCalls == 0);
    before.identityCalls = 0;
    memset(before.identityAt, 0, sizeof(before.identityAt));
    before.eventCount = 0;
    before.events[0] = '\0';
    result = VDTNiceTransition(42, true, 8, &beforeRecord, &beforeOps);
    assert(result.outcome == VDTNiceApplied);
    assert(beforeRecord.originalValue == -2 && before.kernelValue == 8);
    assert(beforeRecord.ownedValue == 8 && !beforeRecord.hasIntent);

    // Fail the final commit after the kernel accepted the value; retry recognizes
    // intent==current and commits without another kernel write.
    Fake after = {.kernelValue = 3, .saveErrorAt = 2, .saveError = EIO};
    VDTNiceOperations afterOps = operations(&after);
    VDTNiceRecord afterRecord = {0};
    result = VDTNiceTransition(42, true, 10, &afterRecord, &afterOps);
    assert(result.outcome == VDTNiceStoreFailed);
    assert(after.kernelValue == 10 && afterRecord.hasIntent);
    int writes = after.writeCalls;
    after.saveErrorAt = 0;
    after.saveCalls = 0;
    result = VDTNiceTransition(42, true, 10, &afterRecord, &afterOps);
    assert(result.outcome == VDTNiceApplied);
    assert(after.writeCalls == writes && !afterRecord.hasIntent);
    assert(afterRecord.originalValue == 3 && afterRecord.ownedValue == 10);
}

static void test_restore_write_failure_retries_and_removal_failure(void) {
    Fake fake = {.kernelValue = 12, .writeError = EPERM};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {
        .captured = true, .originalValue = -3,
        .ownsValue = true, .ownedValue = 12,
    };
    seed(&fake, &record);
    VDTNiceResult result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceWriteFailed && result.error == EPERM);
    assert(record.hasIntent && record.intentValue == -3 && fake.kernelValue == 12);

    fake.writeError = 0;
    fake.saveCalls = 0;
    fake.eventCount = 0;
    fake.events[0] = '\0';
    result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceRestored);
    assert(fake.kernelValue == -3 && !record.captured && !fake.hasStoredRecord);

    fake = (Fake){.kernelValue = 12, .saveErrorAt = 2, .saveError = EIO};
    ops = operations(&fake);
    record = (VDTNiceRecord){
        .captured = true, .originalValue = -3,
        .ownsValue = true, .ownedValue = 12,
    };
    seed(&fake, &record);
    result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceStoreFailed && result.error == EIO);
    assert(fake.kernelValue == -3 && record.captured && record.hasIntent);
    assert(record.intentValue == -3 && fake.hasStoredRecord);
    expectRecord(&fake.storedRecord, &record);
}

static void test_restore_intent_store_failure_prevents_write(void) {
    Fake fake = {.kernelValue = 7, .saveErrorAt = 1, .saveError = EROFS};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {
        .captured = true, .originalValue = -5,
        .ownsValue = true, .ownedValue = 7,
    };
    seed(&fake, &record);
    VDTNiceResult result = VDTNiceTransition(42, false, 0, &record, &ops);
    assert(result.outcome == VDTNiceStoreFailed && result.error == EROFS);
    assert(fake.writeCalls == 0 && fake.kernelValue == 7);
    assert(!record.hasIntent && record.ownedValue == 7);
}

static void test_no_original_value_overwrite_and_gone_after_set(void) {
    // Changing policy values never replaces the initially captured original.
    Fake fake = {.kernelValue = 6};
    VDTNiceOperations ops = operations(&fake);
    VDTNiceRecord record = {0};
    VDTNiceResult result = VDTNiceTransition(42, true, 4, &record, &ops);
    assert(result.outcome == VDTNiceApplied && record.originalValue == 6);
    result = VDTNiceTransition(42, true, -8, &record, &ops);
    assert(result.outcome == VDTNiceApplied && record.originalValue == 6);
    assert(record.ownedValue == -8);

    // Gone on readback occurs after an already guarded write; it retires state
    // and performs no further kernel operation.
    fake = (Fake){.kernelValue = -1};
    fake.identityAt[4] = VDTNiceIdentityGone;
    ops = operations(&fake);
    record = (VDTNiceRecord){0};
    result = VDTNiceTransition(42, true, 3, &record, &ops);
    assert(result.outcome == VDTNiceGone);
    assert(fake.writeCalls == 1 && fake.readCalls == 2);
    assert(!record.captured && !fake.hasStoredRecord);
}

int main(void) {
    test_value_and_record_boundaries();
    test_invalid_arguments_are_side_effect_free();
    test_unmanaged_and_noop_capture();
    test_boundary_desired_values();
    test_first_set_update_restore_preserves_original();
    test_noop_on_managed_record_does_not_write();
    test_identity_unavailable_at_every_apply_gate();
    test_identity_unavailable_at_every_restore_gate();
    test_unknown_identity_enum_fails_closed();
    test_gone_retires_only_existing_record();
    test_unavailable_and_gone_keep_or_remove_on_store_failure();
    test_read_failures_at_each_read_stage();
    test_write_permission_and_verify_failures_keep_intent();
    test_guard_mismatch_conflicts_without_write();
    test_external_change_conflicts_for_set_and_restore();
    test_store_failures_at_apply_stages();
    test_crash_recovery_before_and_after_write();
    test_restore_write_failure_retries_and_removal_failure();
    test_restore_intent_store_failure_prevents_write();
    test_no_original_value_overwrite_and_gone_after_set();
    puts("nice policy tests passed");
    return 0;
}
