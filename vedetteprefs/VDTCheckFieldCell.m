// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckFieldCell.h"
#import "VDTCheckResultCell.h"
#import "VDTCheckFieldLayout.h"

PSSpecifier *VDTCheckFieldSpecifier(NSDictionary *field) {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil
        detail:nil cell:PSStaticTextCell edit:nil];
    [row setProperty:VDTCheckFieldCell.class forKey:@"cellClass"];
    [row setProperty:@YES forKey:@"vdtCheckFieldRow"];
    [row setProperty:[field copy] forKey:@"vdtCheckField"];
    return row;
}
@interface VDTCheckFieldCell ()
@property(nonatomic, strong) UILabel *fieldLabel;
@property(nonatomic, strong) UILabel *fieldValue;
@property(nonatomic, strong) UIImageView *stateIcon;
@property(nonatomic, strong) UIStackView *labelStack;
@property(nonatomic, strong) UIStackView *fieldStack;
@property(nonatomic, copy) NSString *fieldIdentifier;
@end
@implementation VDTCheckFieldCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.hidden = YES; self.detailTextLabel.hidden = YES;
    self.fieldLabel = [UILabel new]; self.fieldValue = [UILabel new];
    for (UILabel *label in @[self.fieldLabel, self.fieldValue]) {
        label.numberOfLines = 0;
        label.adjustsFontForContentSizeCategory = YES;
        label.isAccessibilityElement = NO;
    }
    self.fieldLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.fieldLabel.textColor = UIColor.secondaryLabelColor;
    self.fieldValue.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.stateIcon = [UIImageView new];
    self.stateIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.stateIcon.isAccessibilityElement = NO;
    self.stateIcon.hidden = YES;
    NSLayoutConstraint *iconWidth = [self.stateIcon.widthAnchor constraintEqualToConstant:16];
    iconWidth.priority = 999;
    iconWidth.active = YES;
    [self.stateIcon.heightAnchor constraintEqualToConstant:16].active = YES;
    self.labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.stateIcon, self.fieldLabel]];
    self.labelStack.axis = UILayoutConstraintAxisHorizontal;
    self.labelStack.alignment = UIStackViewAlignmentCenter;
    self.labelStack.spacing = 6;
    self.fieldStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.labelStack, self.fieldValue]];
    self.fieldStack.spacing = 12;
    self.fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.labelStack setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [self.fieldValue setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.contentView.preservesSuperviewLayoutMargins = YES;
    [self.contentView addSubview:self.fieldStack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.fieldStack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.fieldStack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [self.fieldStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
        [self.fieldStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11]
    ]];
    [self updateField:specifier];
    return self;
}
- (void)updateForWidth:(CGFloat)width {
    NSDirectionalEdgeInsets margins = self.contentView.directionalLayoutMargins;
    CGFloat available = MAX(0, width - margins.leading - margins.trailing);
    CGFloat iconWidth = self.stateIcon.hidden ? 0 : 22;
    CGFloat labelWidth = [self.fieldLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width;
    CGFloat valueWidth = [self.fieldValue sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width;
    BOOL hasLineBreak = [self.fieldValue.text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound;
    BOOL vertical = VDTCheckFieldNeedsVertical(available, labelWidth, valueWidth, iconWidth, hasLineBreak,
        UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory));
    self.fieldStack.axis = vertical ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.fieldStack.alignment = vertical ? UIStackViewAlignmentFill : UIStackViewAlignmentFirstBaseline;
    self.fieldStack.spacing = vertical ? 5 : 12;
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    self.fieldValue.textAlignment = vertical ? NSTextAlignmentNatural : (rtl ? NSTextAlignmentLeft : NSTextAlignmentRight);
}
- (void)updateFonts {
    self.fieldLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    BOOL code = [@[@"checkedTarget", @"rawReadback", @"instance"] containsObject:self.fieldIdentifier ?: @""];
    self.fieldValue.font = code ? [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular]]
        : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.fieldValue.lineBreakMode = code ? NSLineBreakByCharWrapping : NSLineBreakByWordWrapping;
}
- (void)updateField:(PSSpecifier *)specifier {
    id raw = [specifier propertyForKey:@"vdtCheckField"];
    NSDictionary *field = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
    self.fieldIdentifier = [field[@"id"] isKindOfClass:NSString.class] ? field[@"id"] : @"";
    self.fieldLabel.text = [field[@"label"] isKindOfClass:NSString.class] ? field[@"label"] : @"";
    self.fieldValue.text = [field[@"value"] isKindOfClass:NSString.class] ? field[@"value"] : @"";
    NSString *tone = [field[@"tone"] isKindOfClass:NSString.class] ? field[@"tone"] : @"plain";
    NSString *symbol = nil;
    if ([self.fieldIdentifier isEqual:@"state"] && [tone isEqual:@"warning"])
        symbol = @"exclamationmark.triangle.fill";
    self.stateIcon.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    self.stateIcon.hidden = !self.stateIcon.image;
    self.stateIcon.tintColor = VDTCheckStateColor(tone);
    self.fieldValue.textColor = VDTCheckStateColor(tone);
    [self updateFonts];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = self.fieldLabel.text;
    self.accessibilityValue = self.fieldValue.text;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;
    [self updateForWidth:self.contentView.bounds.size.width];
}
- (void)layoutSubviews {
    [super layoutSubviews]; [self updateForWidth:self.contentView.bounds.size.width];
}
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size withHorizontalFittingPriority:(UILayoutPriority)horizontal
    verticalFittingPriority:(UILayoutPriority)vertical {
    [self updateForWidth:size.width];
    return [super systemLayoutSizeFittingSize:size withHorizontalFittingPriority:horizontal verticalFittingPriority:vertical];
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier]; [self updateField:specifier];
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.fieldIdentifier = @"";
    self.fieldLabel.text = @"";
    self.fieldValue.text = @"";
    self.stateIcon.image = nil;
    self.stateIcon.hidden = YES;
    self.accessibilityLabel = nil;
    self.accessibilityValue = nil;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateFonts];
    [self updateForWidth:self.contentView.bounds.size.width];
}
@end
