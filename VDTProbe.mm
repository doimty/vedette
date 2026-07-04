//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProbe.h"

#define VDT_PROBE_PRIMARY @"/var/mobile/Library/Preferences/com.udevs.vedette.probe.plist"
#define VDT_PROBE_FALLBACK @"/tmp/com.udevs.vedette.probe.plist"
#define VDT_PROBE_MAX_EVENTS 80

static dispatch_queue_t probeQueue(void){
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.udevs.vedette.probe", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

void VDTProbeRecord(NSString *eventName, NSDictionary *payload){
    if (!eventName) return;
    
    dispatch_async(probeQueue(), ^{
        @autoreleasepool {
            NSMutableDictionary *plist = [NSMutableDictionary dictionary];
            NSMutableArray *events = [NSMutableArray array];
            
            // Try to load existing
            NSString *primaryPath = VDT_PROBE_PRIMARY;
            NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:primaryPath];
            if (existing){
                [plist addEntriesFromDictionary:existing];
                NSArray *oldEvents = existing[@"events"];
                if ([oldEvents isKindOfClass:[NSArray class]]){
                    events = [NSMutableArray arrayWithArray:oldEvents];
                }
            }
            
            // Add new event
            [events addObject:@{
                @"event": eventName,
                @"payload": payload ?: @{},
                @"ts": @([[NSDate date] timeIntervalSince1970])
            }];
            
            // Trim to max
            if (events.count > VDT_PROBE_MAX_EVENTS){
                [events removeObjectsInRange:NSMakeRange(0, events.count - VDT_PROBE_MAX_EVENTS)];
            }
            
            plist[@"version"] = @"1.1.4+probe3";
            plist[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            plist[@"events"] = events;
            plist[@"primaryPath"] = primaryPath;
            plist[@"fallbackPath"] = VDT_PROBE_FALLBACK;
            
            // Update counters
            NSMutableDictionary *counters = [NSMutableDictionary dictionary];
            NSDictionary *oldCounters = plist[@"counters"];
            if ([oldCounters isKindOfClass:[NSDictionary class]]){
                [counters addEntriesFromDictionary:oldCounters];
            }
            NSNumber *cur = counters[eventName];
            counters[eventName] = @((cur ? [cur unsignedLongValue] : 0) + 1);
            plist[@"counters"] = counters;
            
            [plist writeToFile:primaryPath atomically:YES];
            [plist writeToFile:VDT_PROBE_FALLBACK atomically:YES];
        }
    });
}