// Copyright (c) 2019-2021 Lars Fröder

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import "CHPDaemonList.h"
#import "CHPDaemonInfo.h"
#import "../../Common.h"
#import "../../VDTSpringBoardIdentity.h"

#import <dirent.h>
#import <errno.h>

// Missing optional sources are normal; IO errors are never successful empties.
static NSArray *VDTDaemonDirectory(NSString *path, BOOL optional) {
    NSError *error = nil;
    NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:
        [NSURL fileURLWithPath:path isDirectory:YES] includingPropertiesForKeys:nil options:0 error:&error];
    if (!entries && optional && [error.domain isEqualToString:NSCocoaErrorDomain] &&
        (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) return @[];
    return entries;
}

@implementation VDTDaemonList

+ (instancetype)sharedInstance
{
	NSAssert(NSThread.isMainThread, @"Daemon catalog access must be on main");
	static VDTDaemonList* sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^
	{
		//Initialise instance
		sharedInstance = [[VDTDaemonList alloc] init];
	});
	return sharedInstance;
}

- (instancetype)init
{
	if ((self = [super init])) {
		NSAssert(NSThread.isMainThread, @"Main only");
		_observers = [NSHashTable weakObjectsHashTable];
		VDTListCatalogInit(&_state);
	}
	return self;
}

- (BOOL)daemonList:(NSArray*)daemonList containsDisplayName:(NSString*)displayName
{
	for(VDTDaemonInfo* info in daemonList)
	{
		if([info.displayName isEqualToString:displayName])
		{
			return YES;
		}
	}

	return NO;
}

- (BOOL)loaded { NSAssert(NSThread.isMainThread, @"Main only"); return _state.loaded; }
- (BOOL)loading { NSAssert(NSThread.isMainThread, @"Main only"); return _state.loading; }
- (BOOL)failed { NSAssert(NSThread.isMainThread, @"Main only"); return _state.failed; }
- (NSArray *)daemonList { NSAssert(NSThread.isMainThread, @"Main only"); return _daemonList; }

- (void)updateDaemonListIfNeeded
{
	NSAssert(NSThread.isMainThread, @"Main only");
	// Preserve the original loaded gate: warm opens never re-enumerate daemons.
	if (!VDTListCatalogEnsure(&_state, NSProcessInfo.processInfo.systemUptime, false)) return;
	uint64_t generation = _state.activeGeneration;
	[self sendReloadToObservers];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		@autoreleasepool {
			NSArray *records = nil;
			@try { records = [self scanDaemonList]; }
			@catch (NSException *exception) { (void)exception; }
			dispatch_async(dispatch_get_main_queue(), ^{
				VDTListCatalogCompletion completion = VDTListCatalogComplete(&self->_state, generation, records != nil);
				if (completion == VDTListCatalogIgnored) return;
				if (completion == VDTListCatalogPublish) self->_daemonList = [records copy];
				if (completion != VDTListCatalogSuperseded) [self sendReloadToObservers];
				[self updateDaemonListIfNeeded];
			});
		}
	});
}

- (void)refresh
{
	NSAssert(NSThread.isMainThread, @"Main only");
	VDTListCatalogInvalidate(&_state);
	[self updateDaemonListIfNeeded];
}

- (NSArray *)scanDaemonList
{
	NSArray *system = VDTDaemonDirectory(@"/System/Library/LaunchDaemons", NO);
	NSArray *nano = VDTDaemonDirectory(@"/System/Library/NanoLaunchDaemons", YES);
	NSArray *extra = VDTDaemonDirectory(VDT_JBROOT_PATH("/Library/LaunchDaemons"), YES);
	if (!system || !nano || !extra) return nil;
	NSMutableArray<NSURL*>* daemonPlists = [system mutableCopy];
	[daemonPlists addObjectsFromArray:nano];
	[daemonPlists addObjectsFromArray:extra];

	for(NSURL* daemonPlistURL in [daemonPlists reverseObjectEnumerator])
	{
		if(![daemonPlistURL.pathExtension isEqualToString:@"plist"])
		{
			[daemonPlists removeObject:daemonPlistURL];
		}
	}

	NSMutableArray* daemonListM = [NSMutableArray new];

	// Known system entry, not an assertion that it is currently running. This
	// remains available when LaunchDaemons/LaunchServices omit SpringBoard.
	// Seed first so later discovery cannot replace it with a same-named binary.
	VDTDaemonInfo* springBoard = [[VDTDaemonInfo alloc] init];
	springBoard.executablePath = @VDT_SPRINGBOARD_EXECUTABLE;
	springBoard.plistIdentifier = @VDT_SPRINGBOARD_LAUNCHD_ID;
	[daemonListM addObject:springBoard];

	for(NSURL* daemonPlistURL in daemonPlists)
	{
		NSDictionary* daemonDictionary = [NSDictionary dictionaryWithContentsOfURL:daemonPlistURL];
		if (!daemonDictionary) return nil;
		
		VDTDaemonInfo* info = [[VDTDaemonInfo alloc] init];

		id program = [daemonDictionary objectForKey:@"Program"];
		info.executablePath = [program isKindOfClass:NSString.class] ? program : nil;

		if(!info.executablePath)
		{
			NSArray* programArguments = [daemonDictionary objectForKey:@"ProgramArguments"];
			if ([programArguments isKindOfClass:NSArray.class] && programArguments.count > 0 &&
				[programArguments.firstObject isKindOfClass:NSString.class])
			{
				info.executablePath = programArguments.firstObject;
			}
		}

		info.plistIdentifier = [daemonPlistURL lastPathComponent].stringByDeletingPathExtension;

		if(info.executablePath && [[NSFileManager defaultManager] fileExistsAtPath:info.executablePath] && ![info.plistIdentifier hasSuffix:@"Jetsam"] && ![info.plistIdentifier hasSuffix:@"SimulateCrash"] && ![info.plistIdentifier hasSuffix:@"_v2"]) //Filter out some useless entries
		{
			if(![self daemonList:daemonListM containsDisplayName:info.displayName])
			{
				[daemonListM addObject:info];
			}
		}
	}

	__block BOOL frameworkReadFailed = NO;
	NSDirectoryEnumerator* systemLibraryFrameworksEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:@"/System/Library/Frameworks" isDirectory:YES] includingPropertiesForKeys:nil options:0 errorHandler:^(NSURL *url, NSError *error)
	{
		(void)url; (void)error;
		frameworkReadFailed = YES;
		return NO;
	}];

	NSDirectoryEnumerator* systemLibraryPrivateFrameworksEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks" isDirectory:YES] includingPropertiesForKeys:nil options:0 errorHandler:^(NSURL *url, NSError *error)
	{
		(void)url; (void)error;
		frameworkReadFailed = YES;
		return NO;
	}];

	NSMutableArray* XPCUrls = [NSMutableArray new];

	for(NSURL* fileURL in systemLibraryFrameworksEnumerator)
	{
		if([fileURL.path hasSuffix:@".xpc"])
		{
			[XPCUrls addObject:fileURL];
		}
	}

	for(NSURL* fileURL in systemLibraryPrivateFrameworksEnumerator)
	{
		if([fileURL.path hasSuffix:@".xpc"])
		{
			[XPCUrls addObject:fileURL];
		}
	}

	if (!systemLibraryFrameworksEnumerator || !systemLibraryPrivateFrameworksEnumerator || frameworkReadFailed) return nil;
	for(NSURL* XPCUrl in XPCUrls)
	{
		NSString* XPCPath = XPCUrl.path;

		NSString* XPCName = [XPCUrl.lastPathComponent stringByReplacingOccurrencesOfString:@".xpc" withString:@""];

		NSString* XPCExecutablePath = [XPCPath stringByAppendingPathComponent:XPCName];

		if([[NSFileManager defaultManager] fileExistsAtPath:XPCExecutablePath])
		{
			VDTDaemonInfo* info = [[VDTDaemonInfo alloc] init];
			info.executablePath = XPCExecutablePath;

			if(![self daemonList:daemonListM containsDisplayName:info.displayName])
			{
				[daemonListM addObject:info];
			}
		}
	}

	NSMutableArray* additionalPotentialDaemons = [NSMutableArray new];

	// On A12 unc0ver, using contentsOfDirectoryAtURL on /usr/libexec locks the thread and leaves a kernel thread looping
	// This causes all sorts of issues and heats the device up
	// This has been fixed in unc0ver 4.0, but we still use the old solution because some people might not be updated to 4.0
	// The C API is not affected by this issue, so we just use it instead
	DIR *dir = opendir("/usr/libexec");
	if (!dir) return nil;
	int readError = 0;
	for (;;) {
		errno = 0;
		struct dirent *dp = readdir(dir);
		if (!dp) { readError = errno; break; }
		if (!strcmp(dp->d_name, ".") || !strcmp(dp->d_name, "..")) continue;
		NSString *filename = [NSString stringWithCString:dp->d_name encoding:NSUTF8StringEncoding];
		if (filename) {
			NSURL *URL = [NSURL fileURLWithPath:[@"/usr/libexec" stringByAppendingPathComponent:filename]];
			[additionalPotentialDaemons addObject:URL];
		}
	}
	if (closedir(dir) != 0 || readError != 0) return nil;

	NSArray *bin = VDTDaemonDirectory(@"/usr/bin", NO);
	NSArray *sbin = VDTDaemonDirectory(@"/usr/sbin", NO);
	if (!bin || !sbin) return nil;
	[additionalPotentialDaemons addObjectsFromArray:bin];
	[additionalPotentialDaemons addObjectsFromArray:sbin];
	

	for(NSURL* URL in additionalPotentialDaemons)
	{
		if([URL.lastPathComponent hasSuffix:@"d"])
		{
			VDTDaemonInfo* info = [[VDTDaemonInfo alloc] init];
			info.executablePath = [URL path];

			if(![self daemonList:daemonListM containsDisplayName:info.displayName])
			{
				[daemonListM addObject:info];
			}
		}
	}

	[daemonListM sortUsingComparator:^NSComparisonResult(VDTDaemonInfo* a, VDTDaemonInfo* b)  //Sort alphabetically
	{
		return [[a displayName] localizedCaseInsensitiveCompare:[b displayName]];
	}];

	return [daemonListM copy];
}

- (void)addObserver:(id<VDTDaemonListObserver>)observer
{
	NSAssert(NSThread.isMainThread, @"Main only");
	[_observers addObject:observer];
}

- (void)removeObserver:(id<VDTDaemonListObserver>)observer
{
	NSAssert(NSThread.isMainThread, @"Main only");
	[_observers removeObject:observer];
}

- (void)sendReloadToObservers
{
	NSAssert(NSThread.isMainThread, @"Main only");
	for(id<VDTDaemonListObserver> observer in _observers.allObjects)
		[observer daemonListDidUpdate:self];
}

@end
