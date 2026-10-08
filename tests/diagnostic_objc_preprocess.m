#include "VDTDiagnostics.h"
#if VDT_DIAGNOSTICS_ENABLED
void VDTProbeRecordImpl(const char *, void *);
#endif
#define VDTProbeRecord(label, ...) VDT_DIAGNOSTIC_CALL(VDTProbeRecordImpl,label,__VA_ARGS__)
void f(int x) { VDTProbeRecord("test", @{@"a":@(x), @"b":@(x)}); }
