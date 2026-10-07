#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

@interface VDTHeaderCell : PSTableCell
@end

PSSpecifier *VDTHeaderSpecifier(NSString *title, NSString *subtitle, NSString *symbol);
