#pragma once
// Test-only shim so production headers that import <Preferences/PSSpecifier.h>
// can be compiled against the fake Preferences surface. No UIKit/Preferences is
// linked or executed.
#import "../PreferencesHost.h"
