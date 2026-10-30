// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultCell.h"
#import "VDTCheckDetailsController.h"
#import "VDTStyle.h"
#import "VDTLocalization.h"

UIColor *VDTCheckStateColor(NSString *tone) {
    if ([tone isEqual:@"ok"]) return VDTAccentColor();
    if ([tone isEqual:@"plain"]) return UIColor.labelColor;
    if ([tone isEqual:@"warning"]) return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:1 green:0.624 blue:0.039 alpha:1]
            : [UIColor colorWithRed:0.604 green:0.302 blue:0 alpha:1];
    }];
    return UIColor.secondaryLabelColor;
}
PSSpecifier *VDTCheckResultSpecifier(NSDictionary *model) {
    NSString *title = [model[@"title"] isKindOfClass:NSString.class] ? model[@"title"] : @"";
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title target:nil set:nil get:nil
        detail:VDTCheckDetailsController.class cell:PSLinkCell edit:nil];
    [row setProperty:VDTCheckResultCell.class forKey:@"cellClass"];
    [row setProperty:@YES forKey:@"vdtCheckResult"];
    [row setProperty:[model copy] forKey:@"vdtCheckModel"];
    return row;
}
@interface VDTCheckResultCell ()
@property(nonatomic, strong) UILabel *checkTitle;
@property(nonatomic, strong) UILabel *checkState;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UIView *statusSpacer;
@property(nonatomic, strong) UIStackView *statusStack;
@property(nonatomic, strong) UIStackView *heading;
@end
@implementation VDTCheckResultCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    self.contentView.preservesSuperviewLayoutMargins = YES;
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.checkTitle = [UILabel new]; self.checkState = [UILabel new];
    for (UILabel *label in @[self.checkTitle, self.checkState]) {
        label.numberOfLines = 0;
        label.adjustsFontForContentSizeCategory = YES;
        label.isAccessibilityElement = NO;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    }
    self.checkTitle.textColor = UIColor.labelColor;
    [self.checkTitle setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [self.checkState setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.statusIcon = [UIImageView new];
    self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIcon.isAccessibilityElement = NO;
    self.statusIcon.hidden = YES;
    NSLayoutConstraint *iconWidth = [self.statusIcon.widthAnchor constraintEqualToConstant:16];
    iconWidth.priority = 999;
    iconWidth.active = YES;
    [self.statusIcon.heightAnchor constraintEqualToConstant:16].active = YES;
    self.statusSpacer = [UIView new];
    self.statusSpacer.isAccessibilityElement = NO;
    [self.statusSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.checkState setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    self.statusStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusSpacer, self.statusIcon, self.checkState]];
    self.statusStack.axis = UILayoutConstraintAxisHorizontal;
    self.statusStack.alignment = UIStackViewAlignmentCenter;
    self.statusStack.spacing = 6;
    self.heading = [[UIStackView alloc] initWithArrangedSubviews:@[self.checkTitle, self.statusStack]];
    self.heading.spacing = 12;
    UIStackView *column = self.heading;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:column];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [column.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
        [column.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11]
    ]];
    [self updateHeadingLayout];
    [self updateCheck:specifier];
    return self;
}
- (void)updateHeadingForWidth:(CGFloat)width {
    CGFloat available = MAX(0, width - self.contentView.directionalLayoutMargins.leading
        - self.contentView.directionalLayoutMargins.trailing);
    CGFloat needed = [self.checkTitle sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width
        + [self.checkState sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width
        + (self.statusIcon.hidden ? 6 : 28) + 12;
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)
        || (available > 0 && needed > available);
    self.heading.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.heading.alignment = large ? UIStackViewAlignmentFill : UIStackViewAlignmentFirstBaseline;
    self.heading.spacing = large ? 5 : 12;
    self.statusSpacer.hidden = large;
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    self.checkState.textAlignment = large ? NSTextAlignmentNatural : (rtl ? NSTextAlignmentLeft : NSTextAlignmentRight);
}
- (void)updateHeadingLayout { [self updateHeadingForWidth:self.contentView.bounds.size.width]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateHeadingLayout];
}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size withHorizontalFittingPriority:(UILayoutPriority)horizontal
    verticalFittingPriority:(UILayoutPriority)vertical {
    // UIKit reserves space for its native disclosure accessory. Use that
    // measured reservation when estimating whether the heading must wrap.
    CGFloat accessoryWidth = self.contentView.bounds.size.width > 0
        ? MAX(0, self.bounds.size.width - self.contentView.bounds.size.width) : 0;
    [self updateHeadingForWidth:MAX(0, size.width - accessoryWidth)];
    return [super systemLayoutSizeFittingSize:size withHorizontalFittingPriority:horizontal verticalFittingPriority:vertical];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    for (UILabel *label in @[self.checkTitle, self.checkState])
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [self updateHeadingLayout];
}
- (void)updateCheck:(PSSpecifier *)specifier {
    NSDictionary *model = [specifier propertyForKey:@"vdtCheckModel"];
    if (![model isKindOfClass:NSDictionary.class]) model = @{};
    self.checkTitle.text = [model[@"title"] isKindOfClass:NSString.class] ? model[@"title"] : @"";
    self.checkState.text = [model[@"compactState"] isKindOfClass:NSString.class] ? model[@"compactState"] : @"";
    NSString *tone = [model[@"compactTone"] isKindOfClass:NSString.class] ? model[@"compactTone"] : @"neutral";
    NSString *symbol = [tone isEqual:@"warning"] ? @"exclamationmark.triangle.fill" : nil;
    self.statusIcon.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    self.statusIcon.hidden = !self.statusIcon.image;
    self.statusIcon.tintColor = VDTCheckStateColor(tone);
    self.checkState.textColor = VDTCheckStateColor(tone);
    [self updateHeadingLayout];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = self.checkTitle.text;
    self.accessibilityValue = self.checkState.text;
    self.accessibilityHint = VDTLoc(self.class, @"Check details");
    self.accessibilityTraits = UIAccessibilityTraitButton;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.checkTitle.text = @""; self.checkState.text = @"";
    self.statusIcon.image = nil; self.statusIcon.hidden = YES;
    self.accessibilityLabel = nil; self.accessibilityValue = nil;
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateCheck:specifier];
}
@end
