//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#ifndef VDTProbe_h
#define VDTProbe_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void VDTProbeRecord(NSString *eventName, NSDictionary *payload);

#ifdef __cplusplus
}
#endif

#endif /* VDTProbe_h */