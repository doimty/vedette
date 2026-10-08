//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#ifndef VDTProbe_h
#define VDTProbe_h

#import <Foundation/Foundation.h>
#import "VDTDiagnostics.h"

#ifdef __cplusplus
extern "C" {
#endif

void VDTMarkerRecord(NSString *processName, pid_t pid, NSString *executablePath, BOOL isApplication, NSString *bundleIdentifier);
void VDTNotifyPostRecord(NSString *processName, pid_t pid, NSString *identifier, BOOL isApplication);

// Diagnostic payloads are call-site lazy: Release does not construct dictionaries.
void VDTProbeRecordImpl(NSString *label, NSDictionary *info);
#define VDTProbeRecord(label, ...) \
    VDT_DIAGNOSTIC_CALL(VDTProbeRecordImpl, label, __VA_ARGS__)

#ifdef __cplusplus
}
#endif

#endif /* VDTProbe_h */
