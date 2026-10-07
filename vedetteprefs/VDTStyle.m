#import "VDTStyle.h"
#import "VDTCompactMetrics.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

UIColor *VDTAccentColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.42 green:0.82 blue:0.76 alpha:1]
            : [UIColor colorWithRed:0.08 green:0.43 blue:0.40 alpha:1];
    }];
}

UIImage *VDTSettingsSymbol(NSString *name) {
    return [UIImage systemImageNamed:name withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightRegular]];
}

void VDTStyleTable(UITableView *table) {
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;
    table.tintColor = VDTAccentColor();
    table.estimatedRowHeight = 44;
    table.estimatedSectionHeaderHeight = 24;
    table.estimatedSectionFooterHeight = 32;
    if (@available(iOS 15.0, *)) table.sectionHeaderTopPadding = 0;
    table.rowHeight = UITableViewAutomaticDimension;
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
}

void VDTStyleCell(UITableViewCell *cell) {
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.tintColor = VDTAccentColor();
    cell.imageView.tintColor = VDTAccentColor();
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    // Compact ordinary rows; full identity remains in the detail header.
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
}

CGFloat VDTCompactRowHeight(UITableView *table) {
    CGFloat scaled = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledValueForValue:44 compatibleWithTraitCollection:table.traitCollection];
    return (CGFloat)VDTCompactRowMetric(scaled);
}

static NSString *VDTSectionText(PSListController *controller, NSInteger section, BOOL footer) {
    if (section < 0 || section >= [controller numberOfGroups]) return @"";
    PSSpecifier *group = [controller specifierAtIndex:[controller indexOfGroup:section]];
    id text = footer ? [group propertyForKey:@"footerText"] : group.name;
    return [text isKindOfClass:NSString.class] ? text : @"";
}

// Own optional delegate implementation, never sends an optional selector to super.
CGFloat VDTCompactSectionHeight(PSListController *controller, NSInteger section, BOOL footer) {
    if (VDTSectionText(controller, section, footer).length) return UITableViewAutomaticDimension;
    return footer ? 4 : (section == 0 ? 8 : 12);
}

@interface VDTCompactSectionLabel : UITableViewHeaderFooterView
@property(nonatomic, strong) UILabel *caption;
@end

@implementation VDTCompactSectionLabel
- (instancetype)initWithReuseIdentifier:(NSString *)identifier {
    self = [super initWithReuseIdentifier:identifier];
    if (!self) return nil;
    self.backgroundView = [UIView new];
    self.backgroundView.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.caption = [UILabel new];
    self.caption.translatesAutoresizingMaskIntoConstraints = NO;
    self.caption.numberOfLines = 0;
    self.caption.adjustsFontForContentSizeCategory = YES;
    self.caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.caption.textColor = UIColor.secondaryLabelColor;
    [self.contentView addSubview:self.caption];
    UILayoutGuide *guide = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.caption.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.caption.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.caption.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.caption.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]
    ]];
    return self;
}
@end

UIView *VDTCompactSectionView(PSListController *controller, UITableView *table, NSInteger section, BOOL footer) {
    NSString *text = VDTSectionText(controller, section, footer);
    if (!text.length) return nil;
    NSString *identifier = footer ? @"VDTCompactFooter" : @"VDTCompactHeader";
    VDTCompactSectionLabel *view = (VDTCompactSectionLabel *)[table dequeueReusableHeaderFooterViewWithIdentifier:identifier];
    if (!view) view = [[VDTCompactSectionLabel alloc] initWithReuseIdentifier:identifier];
    view.contentView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(footer ? 4 : 8, 32, 4, 32);
    view.caption.text = text;
    view.caption.accessibilityTraits = footer ? UIAccessibilityTraitStaticText : UIAccessibilityTraitHeader;
    return view;
}
