// Executes the production bounded-attempt helper. No kernel or Foundation.
#include "VDTNiceAttempt.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    VDTNiceAttempt s = {0};
    assert(VDTNiceAttemptAllowed(s, 10));
    assert(!VDTNiceAttemptAllowed(s, -1) && !VDTNiceAttemptAllowed(s, NAN));
    s = VDTNiceAttemptFinished(s, 10, VDTNiceWriteFailed, EAGAIN);
    assert(s.count == 1 && s.pending && s.due == 10.5);
    assert(!VDTNiceAttemptAllowed(s, 10.49) && VDTNiceAttemptAllowed(s, 10.5));
    s = VDTNiceAttemptFinished(s, 10.5, VDTNiceReadFailed, EIO);
    assert(s.count == 2 && s.pending && s.due == 12.5);
    assert(!VDTNiceAttemptAllowed(s, 12.49) && VDTNiceAttemptAllowed(s, 12.5));
    s = VDTNiceAttemptFinished(s, 12.5, VDTNiceIdentityUnavailable, 0);
    assert(s.count == 3 && !s.pending && !VDTNiceAttemptAllowed(s, 10000));
    VDTNiceOutcome terminal[] = {VDTNiceApplied, VDTNiceRestored, VDTNiceGone,
        VDTNiceConflict, VDTNiceInvalid, VDTNiceUnmanaged};
    for (unsigned i = 0; i < sizeof(terminal)/sizeof(*terminal); ++i) {
        s = VDTNiceAttemptFinished((VDTNiceAttempt){0}, 10, terminal[i], EAGAIN);
        assert(!s.pending && !VDTNiceAttemptAllowed(s, 10000));
    }
    int denied[] = {EPERM, EACCES, EINVAL, ENOTSUP, E2BIG, EFBIG};
    for (unsigned i = 0; i < sizeof(denied)/sizeof(*denied); ++i) {
        s = VDTNiceAttemptFinished((VDTNiceAttempt){0}, 10, VDTNiceWriteFailed, denied[i]);
        assert(!s.pending && !VDTNiceAttemptAllowed(s, 10000));
    }
    s = VDTNiceAttemptFinished((VDTNiceAttempt){0}, 10, VDTNiceStoreFailed, EIO);
    assert(s.pending);
    s = VDTNiceAttemptFinished(s, 10.5, VDTNiceApplied, 0);
    assert(!s.pending && !VDTNiceAttemptAllowed(s, 10000));
    puts("PASS production attempt policy: deadline, 3-attempt bound, no Conflict/permission retries, reset/success");
    return 0;
}
