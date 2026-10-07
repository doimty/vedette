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

#import "CHPDaemonListController.h"

#import "CHPDaemonInfo.h"
#import "CHPDaemonList.h"
#import "../VDTProcessConfiguration.h"
#import "../VDTListPresentation.h"
#import "../VDTLocalization.h"

@interface PSListController()
- (id)controllerForSpecifier:(PSSpecifier*)specifier;
@end

@implementation CHPDaemonListController

- (void)viewDidLoad
{
	[super viewDidLoad];
	[self applySearchControllerHideWhileScrolling:NO];
	[[CHPDaemonList sharedInstance] addObserver:self];

	if(![CHPDaemonList sharedInstance].loaded)
	{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			[[CHPDaemonList sharedInstance] updateDaemonListIfNeeded];
		});
	}
	else
	{
		[self updateSuggestedDaemons];
	}

}

- (void)dealloc
{
	[[CHPDaemonList sharedInstance] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	// Keep the active query; a changed switch may move a row to another group.
	[self reloadSpecifiers];
}

- (NSString*)topTitle
{
	return VDTLoc(self.class, @"Daemons");
}

- (NSString*)plistName
{
	return nil;
}

- (NSMutableArray*)specifiers
{
	if (!_specifiers)
	{
		NSMutableArray *rows = [NSMutableArray new];
		if (![CHPDaemonList sharedInstance].loaded)
		{
			PSSpecifier *loading = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Loading…")
				target:self set:nil get:nil detail:nil
				cell:[PSTableCell cellTypeFromString:@"PSSpinnerCell"] edit:nil];
			[rows addObject:loading];
			_specifiers = rows;
		}
		else
		{
			_showsAllDaemons = YES;
			NSArray<CHPDaemonInfo *> *daemonList = [CHPDaemonList sharedInstance].daemonList;
			for (CHPDaemonInfo *info in daemonList)
			{
				NSString *name = [info displayName];
				if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
				PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
					target:self set:nil get:@selector(previewStringForSpecifier:)
					detail:[VDTProcessConfiguration class] cell:PSLinkListCell edit:nil];
				[specifier setProperty:@(VDTConfigTypeDaemon) forKey:@"configurationType"];
				[specifier setProperty:@YES forKey:@"enabled"];
				// Keep the original basename identity, including Apple daemons.
				[specifier setProperty:[info displayName] forKey:@"daemonName"];
				[specifier setProperty:info forKey:@"daemonInfo"];
				[rows addObject:specifier];
			}
			NSString *query = [_searchKey copy] ?: @"";
			_specifiers = VDTGroupedListSpecifiers(rows, @"daemonName", VDTConfigTypeDaemon,
				self.class, ^BOOL(PSSpecifier *specifier) {
					return query.length == 0 || [specifier.name localizedStandardContainsString:query];
				}, query.length ? @"No Results" : @"No Daemons");
		}
	}
	return _specifiers;
}

- (id)previewStringForSpecifier:(PSSpecifier*)specifier
{
	return VDTListConfigurationEnabled([specifier propertyForKey:@"daemonName"], VDTConfigTypeDaemon, nil)
		? VDTLoc(self.class, @"Configuration enabled") : @"";
}

- (void)reloadValueOfSelectedSpecifier
{
	// The previous index path may now belong to another group, or to no row.
	[self reloadSpecifiers];
}

- (void)updateSuggestedDaemons
{
	NSMutableSet* suggestedDaemons = [NSMutableSet new];

	for(CHPDaemonInfo* info in [CHPDaemonList sharedInstance].daemonList)
	{
		if([info.linkedFrameworkIdentifiers containsObject:@"com.apple.UIKit"])
		{
			[suggestedDaemons addObject:[info displayName]];
		}
	}

	_suggestedDaemons = [suggestedDaemons copy];
}

- (void)daemonListDidUpdate:(CHPDaemonList*)list
{
	// The enumerator currently delivers on main; also tolerate an off-main caller.
	if (![NSThread isMainThread])
	{
		dispatch_async(dispatch_get_main_queue(), ^{ [self daemonListDidUpdate:list]; });
		return;
	}
	[self updateSuggestedDaemons];
	[self reloadSpecifiers];
}

- (id)controllerForSpecifier:(PSSpecifier*)specifier
{
    if (@available(iOS 11.0, *)){
    }else{
		[UIView performWithoutAnimation:^
		{
			_searchController.active = NO;
		}];
	}

	return [super controllerForSpecifier:specifier];
}

@end
