// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultCell.h"
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
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil
        detail:nil cell:PSStaticTextCell edit:nil];
    [row setProperty:VDTCheckResultCell.class forKey:@"cellClass"];
    [row setProperty:@YES forKey:@"vdtCheckResult"];
    [row setProperty:[model copy] forKey:@"vdtCheckModel"];
    return row;
}
@interface VDTCheckResultCell ()
@property(nonatomic, strong) UILabel *checkTitle;
@property(nonatomic, strong) UILabel *checkState;
@property(nonatomic, strong) UIStackView *heading;
@end
@implementation VDTCheckResultCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
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
    self.heading = [[UIStackView alloc] initWithArrangedSubviews:@[self.checkTitle, self.checkState]];
    self.heading.spacing = 12;
    UIStackView *column = self.heading;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [column.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [column.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
        [column.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11]
    ]];
    [self updateHeadingLayout];
    [self updateCheck:specifier];
    return self;
}
- (void)updateHeadingForWidth:(CGFloat)width {
    CGFloat available = MAX(0, width - 32);
    CGFloat needed = [self.checkTitle sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width
        + [self.checkState sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width + self.heading.spacing;
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)
        || (available > 0 && needed > available);
    self.heading.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.heading.alignment = large ? UIStackViewAlignmentFill : UIStackViewAlignmentFirstBaseline;
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
    [self updateHeadingForWidth:size.width];
    return [super systemLayoutSizeFittingSize:size withHorizontalFittingPriority:horizontal verticalFittingPriority:vertical];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateHeadingLayout];
}
- (void)updateCheck:(PSSpecifier *)specifier {
    NSDictionary *model = [specifier propertyForKey:@"vdtCheckModel"];
    if (![model isKindOfClass:NSDictionary.class]) model = @{};
    self.checkTitle.text = model[@"title"];
    self.checkState.text = model[@"compactState"];
    self.checkState.textColor = VDTCheckStateColor(model[@"compactTone"]);
    [self updateHeadingLayout];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = [@[self.checkTitle.text ?: @"", self.checkState.text ?: @""] componentsJoinedByString:@", "];
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateCheck:specifier];
}
@end
