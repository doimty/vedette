#import "VDTAboutListController.h"
#import <Preferences/PSSpecifier.h>
#import "VDTLocalization.h"
#import "VDTStyle.h"

@implementation VDTAboutListController

- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        PSSpecifier *credits = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, @"Credits")
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [credits setProperty:VDTLoc(self.class, @"Vedette by udevs. App lists use AltList; daemon discovery is based on Choicy. This interface is maintained by doimty.") forKey:@"footerText"];
        [items addObject:credits];
        NSArray *links = @[
            @[@"Project source", @"chevron.left.forwardslash.chevron.right", @"https://github.com/doimty/vedette"],
            @[@"Support original developer", @"heart", @"https://www.paypal.me/udevs"],
            @[@"Twitter", @"bubble.left", @"https://twitter.com/udevs9"],
            @[@"Reddit", @"bubble.left.and.bubble.right", @"https://www.reddit.com/user/h4roldj"]
        ];
        for (NSArray *link in links) {
            PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:VDTLoc(self.class, link[0])
                target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            [item setProperty:link[2] forKey:@"url"];
            [item setProperty:VDTSettingsSymbol(link[1]) forKey:@"iconImage"];
            [item setButtonAction:@selector(openProjectLink:)];
            [items addObject:item];
        }
        PSSpecifier *license = [PSSpecifier emptyGroupSpecifier];
        [license setProperty:VDTLoc(self.class, @"Licensed under GPLv3, except components with their own notices. Enabled badges describe saved rules, not measured CPU usage.") forKey:@"footerText"];
        [items addObject:license];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VDTLoc(self.class, @"About Vedette");
    self.view.tintColor = VDTAccentColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    VDTStyleTable(self.table);
}

- (void)openProjectLink:(PSSpecifier *)specifier {
    NSURL *url = [NSURL URLWithString:[specifier propertyForKey:@"url"]];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // PSListController may omit optional willDisplayCell on iOS 15.
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    VDTStyleCell(cell);
    return cell;
}
@end
