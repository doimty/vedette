// Call-site lazy diagnostics shared with pure-C regression tests.
#ifndef VDT_DIAGNOSTICS_H
#define VDT_DIAGNOSTICS_H

#ifndef VDT_DIAGNOSTICS_ENABLED
# if defined(DEBUG) && DEBUG
#  define VDT_DIAGNOSTICS_ENABLED 1
# else
#  define VDT_DIAGNOSTICS_ENABLED 0
# endif
#endif

#if VDT_DIAGNOSTICS_ENABLED
#define VDT_DIAGNOSTIC_CALL(emitter, label, ...) \
    (emitter)((label), (__VA_ARGS__))
#else
// Do not evaluate label, payload, or the emitter expression in Release.
#define VDT_DIAGNOSTIC_CALL(emitter, label, ...) do { (void)0; } while (0)
#endif

#endif
