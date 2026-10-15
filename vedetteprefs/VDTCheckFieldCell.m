// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckFieldCell.h"
#import "VDTCheckResultCell.h"

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
@property(nonatomic, strong) UIStackView *fieldStack;
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
    self.fieldStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.fieldLabel, self.fieldValue]];
    self.fieldStack.spacing = 12;
    self.fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.fieldLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:self.fieldStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.fieldStack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.fieldStack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.fieldStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
        [self.fieldStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11]
    ]];
    [self updateField:specifier];
    return self;
}
- (void)updateForWidth:(CGFloat)width {
    CGFloat available = MAX(0, width - 32);
    CGFloat needed = [self.fieldLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width
        + [self.fieldValue sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width + 12;
    BOOL vertical = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)
        || (available > 0 && needed > available);
    self.fieldStack.axis = vertical ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.fieldStack.alignment = vertical ? UIStackViewAlignmentFill : UIStackViewAlignmentFirstBaseline;
    self.fieldStack.spacing = vertical ? 5 : 12;
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    self.fieldValue.textAlignment = vertical ? NSTextAlignmentNatural : (rtl ? NSTextAlignmentLeft : NSTextAlignmentRight);
}
- (void)updateField:(PSSpecifier *)specifier {
    id raw = [specifier propertyForKey:@"vdtCheckField"];
    NSDictionary *field = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
    self.fieldLabel.text = [field[@"label"] isKindOfClass:NSString.class] ? field[@"label"] : @"";
    self.fieldValue.text = [field[@"value"] isKindOfClass:NSString.class] ? field[@"value"] : @"";
    self.fieldValue.textColor = VDTCheckStateColor(field[@"tone"]);
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", self.fieldLabel.text, self.fieldValue.text];
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
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    self.fieldLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.fieldValue.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [self updateForWidth:self.contentView.bounds.size.width];
}
@end
