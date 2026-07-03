#import "VDTProbe.h"

static NSString * const VDTProbePrimaryPath = @"/var/mobile/Library/Preferences/com.udevs.vedette.probe.plist";
static NSString * const VDTProbeFallbackPath = @"/tmp/com.udevs.vedette.probe.plist";
static NSUInteger const VDTProbeMaxEvents = 80;

static id VDTProbeSafeObject(id obj) {
    if (!obj) return @"";
    if ([obj isKindOfClass:NSString.class] || [obj isKindOfClass:NSNumber.class] || [obj isKindOfClass:NSDate.class] || [obj isKindOfClass:NSData.class]) return obj;
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *safe = [NSMutableArray array];
        for (id item in (NSArray *)obj) [safe addObject:VDTProbeSafeObject(item) ?: @""];
        return safe;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            safe[[key description] ?: @"key"] = VDTProbeSafeObject(value) ?: @"";
        }];
        return safe;
    }
    return [obj description] ?: @"";
}

static NSMutableDictionary *VDTProbeReadState(void) {
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:VDTProbePrimaryPath];
    if (!existing) existing = [NSDictionary dictionaryWithContentsOfFile:VDTProbeFallbackPath];
    NSMutableDictionary *state = existing ? [existing mutableCopy] : [NSMutableDictionary dictionary];
    if (![state[@"counters"] isKindOfClass:NSDictionary.class]) state[@"counters"] = @{};
    if (![state[@"events"] isKindOfClass:NSArray.class]) state[@"events"] = @[];
    return state;
}

static void VDTProbeWriteState(NSDictionary *state) {
    [state writeToFile:VDTProbePrimaryPath atomically:YES];
    [state writeToFile:VDTProbeFallbackPath atomically:YES];
}

void VDTProbeRecord(NSString *event, NSDictionary *payload) {
    @autoreleasepool {
        @synchronized([NSClassFromString(@"VDTProbeLock") class] ?: NSObject.class) {
            NSString *eventName = event.length ? event : @"unknown";
            NSMutableDictionary *state = VDTProbeReadState();
            NSMutableDictionary *counters = [state[@"counters"] mutableCopy] ?: [NSMutableDictionary dictionary];
            counters[eventName] = @([counters[eventName] unsignedIntegerValue] + 1);

            NSMutableArray *events = [state[@"events"] mutableCopy] ?: [NSMutableArray array];
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
            entry[@"event"] = eventName;
            if (payload) entry[@"payload"] = VDTProbeSafeObject(payload);
            [events addObject:entry];
            while (events.count > VDTProbeMaxEvents) [events removeObjectAtIndex:0];

            state[@"version"] = @"1.1.4+probe1";
            state[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            state[@"primaryPath"] = VDTProbePrimaryPath;
            state[@"fallbackPath"] = VDTProbeFallbackPath;
            state[@"counters"] = counters;
            state[@"events"] = events;
            VDTProbeWriteState(state);
        }
    }
}
