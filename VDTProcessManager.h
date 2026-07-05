//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>

extern NSDictionary *prefs;

#ifdef __cplusplus
extern "C" {
#endif

void apply_process_configs(NSArray <NSString *>*identifiers, NSArray <NSNumber *> *types, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals, NSArray <NSNumber *> *violationPolicies);
void received_new_proc(pid_t pid);

#ifdef __cplusplus
}
#endif

