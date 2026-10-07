// UI-only layout metrics. No process policy or CPU thresholds.
#ifndef VDT_COMPACT_METRICS_H
#define VDT_COMPACT_METRICS_H
#include <math.h>

static inline double VDTCompactRowMetric(double scaledHeight) {
    if (!isfinite(scaledHeight) || scaledHeight < 44.0) return 44.0;
    return ceil(scaledHeight);
}
#endif
