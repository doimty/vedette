#import <Foundation/Foundation.h>

static inline NSString *VDTLoc(Class cls, NSString *key) {
    if (key.length == 0) return @"";
    NSBundle *bundle = [NSBundle bundleForClass:cls] ?: [NSBundle mainBundle];
    return [bundle localizedStringForKey:key value:key table:nil];
}
