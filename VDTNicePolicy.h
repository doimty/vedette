#ifndef VDT_NICE_POLICY_H
#define VDT_NICE_POLICY_H

#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VDT_NICE_MIN_VALUE (-20)
#define VDT_NICE_MAX_VALUE 20

typedef struct {
    bool captured;
    int originalValue;
    bool ownsValue;
    int ownedValue;
    bool hasIntent;
    int intentValue;
} VDTNiceRecord;

typedef enum {
    VDTNiceIdentityCurrent = 0,
    VDTNiceIdentityGone,
    // C enum constants share one namespace; the outcome uses the shorter
    // VDTNiceIdentityUnavailable spelling below.
    VDTNiceIdentityUnavailableValue,
} VDTNiceIdentity;

typedef enum {
    VDTNiceUnmanaged = 0,
    VDTNiceApplied,
    VDTNiceRestored,
    VDTNiceGone,
    VDTNiceInvalid,
    VDTNiceIdentityUnavailable,
    VDTNiceReadFailed,
    VDTNiceWriteFailed,
    VDTNiceVerifyFailed,
    VDTNiceStoreFailed,
    VDTNiceConflict,
} VDTNiceOutcome;

typedef struct {
    VDTNiceOutcome outcome;
    int error;
    bool observedValid;
    int observedValue;
} VDTNiceResult;

typedef struct {
    VDTNiceIdentity (*identity)(pid_t pid, void *context);
    int (*readValue)(pid_t pid, int *value, void *context);
    int (*writeValue)(pid_t pid, int value, void *context);
    int (*saveRecord)(const VDTNiceRecord *record, void *context);
    void *context;
} VDTNiceOperations;

bool VDTNiceValueIsValid(int value);
bool VDTNiceRecordIsValid(const VDTNiceRecord *record);

// Applies or restores one nice transition. Callback errors are errno values.
// A successful saveRecord(NULL, ...) removes persistent state. The caller's
// record is advanced only after a successful save; on removal it is zeroed.
VDTNiceResult VDTNiceTransition(pid_t pid,
                               bool enabled,
                               int desired,
                               VDTNiceRecord *record,
                               const VDTNiceOperations *operations);

#ifdef __cplusplus
}
#endif

#endif
