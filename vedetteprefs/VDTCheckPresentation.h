// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>

// Read-only groupings for one mechanism. All recorded fields remain reachable
// on either the result screen or its diagnostic screen.
NSArray<NSDictionary *> *VDTCheckPresentationSections(NSDictionary *model, BOOL diagnostics);
NSArray<NSDictionary *> *VDTCheckPresentationFields(NSDictionary *model, BOOL diagnostics);
