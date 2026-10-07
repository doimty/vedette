#import "VDTStyle.h"

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
    table.estimatedRowHeight = 56;
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
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
}
