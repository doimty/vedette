// GPLv3, like Vedette. Native header-cell composition informed by the
// GPLv3 Kayoko / PullOver X preferences from mlgm66; see UI_REFERENCES.md.
// Vedette implementation: scalable type and unbounded, measured text height.
#import "VDTHeaderCell.h"
#import "VDTStyle.h"

static UIFont *VDTTitleFont(void) {
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
        scaledFontForFont:[UIFont systemFontOfSize:22 weight:UIFontWeightSemibold]];
}
static UIFont *VDTSubtitleFont(void) {
    return [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
}

PSSpecifier *VDTHeaderSpecifier(NSString *title, NSString *subtitle, NSString *symbol) {
    PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:@"" target:nil set:nil get:nil
        detail:nil cell:PSStaticTextCell edit:nil];
    [header setProperty:VDTHeaderCell.class forKey:@"cellClass"];
    [header setProperty:@YES forKey:@"vdtHeader"];
    [header setProperty:title ?: @"" forKey:@"headerTitle"];
    [header setProperty:subtitle ?: @"" forKey:@"headerSubtitle"];
    [header setProperty:symbol ?: @"shield.lefthalf.filled" forKey:@"headerSymbol"];
    return header;
}

@interface VDTHeaderCell ()
@property(nonatomic, strong) UILabel *brandTitle;
@property(nonatomic, strong) UILabel *brandSubtitle;
@property(nonatomic, strong) UIImageView *brandIcon;
@end

@implementation VDTHeaderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.hidden = YES;
    self.brandIcon = [UIImageView new];
    self.brandIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.brandIcon.layer.cornerRadius = 11;
    self.brandIcon.clipsToBounds = YES;
    self.brandIcon.isAccessibilityElement = NO;
    [self.brandIcon.widthAnchor constraintEqualToConstant:48].active = YES;
    [self.brandIcon.heightAnchor constraintEqualToConstant:48].active = YES;
    self.brandTitle = [UILabel new];
    self.brandSubtitle = [UILabel new];
    self.brandTitle.font = VDTTitleFont();
    self.brandSubtitle.font = VDTSubtitleFont();
    for (UILabel *label in @[self.brandTitle, self.brandSubtitle]) {
        label.numberOfLines = 0;
        label.adjustsFontForContentSizeCategory = YES;
    }
    self.brandTitle.textColor = UIColor.labelColor;
    self.brandTitle.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.brandSubtitle.textColor = UIColor.secondaryLabelColor;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[self.brandTitle, self.brandSubtitle]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 4;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.brandIcon, text]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20],
        [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20]
    ]];
    [self updateHeader:specifier];
    return self;
}

- (void)updateHeader:(PSSpecifier *)specifier {
    self.brandTitle.text = [specifier propertyForKey:@"headerTitle"];
    self.brandSubtitle.text = [specifier propertyForKey:@"headerSubtitle"];
    NSString *symbol = [specifier propertyForKey:@"headerSymbol"];
    UIImage *image = nil;
    if ([symbol isEqualToString:@"vedette"]) {
        image = [UIImage imageNamed:@"Vedette" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];
    }
    self.brandIcon.image = image ?: VDTSettingsSymbol(symbol);
    self.brandIcon.tintColor = VDTAccentColor();
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateHeader:specifier];
}
@end
