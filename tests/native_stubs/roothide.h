#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
NSString *VDTTestJbroot(NSString *path);
#ifdef __cplusplus
}
#endif
#define jbroot(path) VDTTestJbroot(path)
