// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#import "VDTCheckResultCell.h"
#import "VDTStyle.h"
#import "VDTLocalization.h"

PSSpecifier *VDTCheckResultSpecifier(NSDictionary *model, BOOL detailed) {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil
        detail:nil cell:PSStaticTextCell edit:nil];
    [row setProperty:VDTCheckResultCell.class forKey:@"cellClass"];
    [row setProperty:@YES forKey:@"vdtCheckResult"];
    [row setProperty:@(detailed) forKey:@"vdtCheckDetailed"];
    [row setProperty:[model copy] forKey:@"vdtCheckModel"];
    return row;
}
@interface VDTCheckResultCell ()
@property(nonatomic, strong) UILabel *checkTitle;
@property(nonatomic, strong) UILabel *checkState;
@property(nonatomic, strong) UILabel *checkSummary;
@property(nonatomic, strong) UILabel *checkTime;
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
    self.checkSummary = [UILabel new]; self.checkTime = [UILabel new];
    for (UILabel *label in @[self.checkTitle, self.checkState, self.checkSummary, self.checkTime]) {
        label.numberOfLines = 0;
        label.adjustsFontForContentSizeCategory = YES;
        label.isAccessibilityElement = NO;
    }
    self.checkTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.checkState.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.checkSummary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.checkTime.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.checkTitle.textColor = UIColor.labelColor;
    self.checkSummary.textColor = UIColor.secondaryLabelColor;
    self.checkTime.textColor = UIColor.secondaryLabelColor;
    [self.checkTitle setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [self.checkState setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.heading = [[UIStackView alloc] initWithArrangedSubviews:@[self.checkTitle, self.checkState]];
    self.heading.spacing = 12;
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[self.heading, self.checkSummary, self.checkTime]];
    column.axis = UILayoutConstraintAxisVertical; column.spacing = 5;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [column.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [column.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:13],
        [column.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-13]
    ]];
    [self updateHeadingLayout];
    [self updateCheck:specifier];
    return self;
}
- (void)updateHeadingLayout {
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.heading.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.heading.alignment = large ? UIStackViewAlignmentFill : UIStackViewAlignmentFirstBaseline;
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    self.checkState.textAlignment = large ? NSTextAlignmentNatural : (rtl ? NSTextAlignmentLeft : NSTextAlignmentRight);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateHeadingLayout];
}
- (void)updateCheck:(PSSpecifier *)specifier {
    NSDictionary *model = [specifier propertyForKey:@"vdtCheckModel"];
    if (![model isKindOfClass:NSDictionary.class]) model = @{};
    BOOL detailed = [[specifier propertyForKey:@"vdtCheckDetailed"] boolValue];
    self.checkTitle.text = model[@"title"];
    self.checkState.text = model[@"state"];
    self.checkSummary.text = model[detailed ? @"details" : @"summary"];
    self.checkTime.text = model[@"timestamp"];
    self.checkTime.hidden = detailed;
    NSString *tone = model[@"tone"];
    self.checkState.textColor = [tone isEqual:@"ok"] ? VDTAccentColor() :
        ([tone isEqual:@"warning"] ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor);
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = [@[self.checkTitle.text ?: @"", self.checkState.text ?: @"",
        self.checkSummary.text ?: @"", detailed ? @"" : (self.checkTime.text ?: @"")] componentsJoinedByString:@", "];
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateCheck:specifier];
}
@end

@implementation VDTCheckDetailsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VDTLoc(self.class, @"Check details");
    VDTStyleTable(self.table);
}
- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:VDTLoc(self.class, @"Historical receipt, not live monitoring. Refresh only reloads saved results.") forKey:@"footerText"];
        [rows addObject:group];
        id models = [self.specifier propertyForKey:@"vdtCheckModels"];
        if ([models isKindOfClass:NSArray.class])
            for (id model in models)
                if ([model isKindOfClass:NSDictionary.class]) [rows addObject:VDTCheckResultSpecifier(model, YES)];
        _specifiers = rows;
    }
    return _specifiers;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([[[self specifierAtIndexPath:indexPath] propertyForKey:@"vdtCheckResult"] boolValue]) return UITableViewAutomaticDimension;
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    VDTStyleCell(cell); return cell;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous && ![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory])
        [self.table reloadData];
}
@end
