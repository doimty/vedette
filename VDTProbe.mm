//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProbe.h"

#define VDT_MARKER_PRIMARY @"/var/mobile/Library/Preferences/com.udevs.vedette.marker.plist"
#define VDT_MARKER_FALLBACK @"/tmp/com.udevs.vedette.marker.plist"
#define VDT_MARKER_MAX_EVENTS 40
#define VDT_NOTIFY_MAX_EVENTS 40

static dispatch_queue_t markerQueue(void){
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.udevs.vedette.marker", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

void VDTMarkerRecord(NSString *processName, pid_t pid, NSString *executablePath, BOOL isApplication, NSString *bundleIdentifier){
    if (!processName.length) return;

    dispatch_async(markerQueue(), ^{
        @autoreleasepool {
            NSMutableDictionary *plist = [NSMutableDictionary dictionary];
            NSMutableArray *events = [NSMutableArray array];

            NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:VDT_MARKER_PRIMARY];
            if (existing){
                [plist addEntriesFromDictionary:existing];
                NSArray *oldEvents = existing[@"events"];
                if ([oldEvents isKindOfClass:[NSArray class]]){
                    events = [NSMutableArray arrayWithArray:oldEvents];
                }
            }

            [events addObject:@{
                @"processName": processName ?: @"",
                @"pid": @(pid),
                @"executablePath": executablePath ?: @"",
                @"isApplication": @(isApplication),
                @"bundleIdentifier": bundleIdentifier ?: @"",
                @"ts": @([[NSDate date] timeIntervalSince1970])
            }];

            if (events.count > VDT_MARKER_MAX_EVENTS){
                [events removeObjectsInRange:NSMakeRange(0, events.count - VDT_MARKER_MAX_EVENTS)];
            }

            NSMutableDictionary *counters = [NSMutableDictionary dictionary];
            NSDictionary *oldCounters = plist[@"counters"];
            if ([oldCounters isKindOfClass:[NSDictionary class]]){
                [counters addEntriesFromDictionary:oldCounters];
            }
            NSNumber *cur = counters[processName];
            counters[processName] = @((cur ? [cur unsignedLongValue] : 0) + 1);

            plist[@"version"] = @"1.1.4+marker2";
            plist[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            plist[@"events"] = events;
            plist[@"counters"] = counters;
            plist[@"primaryPath"] = VDT_MARKER_PRIMARY;
            plist[@"fallbackPath"] = VDT_MARKER_FALLBACK;

            [plist writeToFile:VDT_MARKER_PRIMARY atomically:YES];
            [plist writeToFile:VDT_MARKER_FALLBACK atomically:YES];
        }
    });
}

void VDTNotifyPostRecord(NSString *processName, pid_t pid, NSString *identifier, BOOL isApplication){
    if (!processName.length) return;

    dispatch_async(markerQueue(), ^{
        @autoreleasepool {
            NSMutableDictionary *plist = [NSMutableDictionary dictionary];
            NSMutableArray *events = [NSMutableArray array];

            NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:VDT_MARKER_PRIMARY];
            if (existing){
                [plist addEntriesFromDictionary:existing];
                NSArray *oldEvents = existing[@"notifyEvents"];
                if ([oldEvents isKindOfClass:[NSArray class]]){
                    events = [NSMutableArray arrayWithArray:oldEvents];
                }
            }

            [events addObject:@{
                @"processName": processName ?: @"",
                @"pid": @(pid),
                @"identifier": identifier ?: @"",
                @"isApplication": @(isApplication),
                @"ts": @([[NSDate date] timeIntervalSince1970])
            }];

            if (events.count > VDT_NOTIFY_MAX_EVENTS){
                [events removeObjectsInRange:NSMakeRange(0, events.count - VDT_NOTIFY_MAX_EVENTS)];
            }

            NSMutableDictionary *counters = [NSMutableDictionary dictionary];
            NSDictionary *oldCounters = plist[@"notifyCounters"];
            if ([oldCounters isKindOfClass:[NSDictionary class]]){
                [counters addEntriesFromDictionary:oldCounters];
            }
            NSNumber *cur = counters[processName];
            counters[processName] = @((cur ? [cur unsignedLongValue] : 0) + 1);

            plist[@"version"] = @"1.1.4+marker2";
            plist[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            plist[@"notifyEvents"] = events;
            plist[@"notifyCounters"] = counters;
            plist[@"primaryPath"] = VDT_MARKER_PRIMARY;
            plist[@"fallbackPath"] = VDT_MARKER_FALLBACK;

            [plist writeToFile:VDT_MARKER_PRIMARY atomically:YES];
            [plist writeToFile:VDT_MARKER_FALLBACK atomically:YES];
        }
    });
}
