#import <UIKit/UIKit.h>
@class PSListController;

CGFloat VDTCompactRowHeight(UITableView *table);
CGFloat VDTCompactSectionHeight(PSListController *controller, NSInteger section, BOOL footer);
UIView *VDTCompactSectionView(PSListController *controller, UITableView *table, NSInteger section, BOOL footer);

UIColor *VDTAccentColor(void);
UIImage *VDTSettingsSymbol(NSString *name);
void VDTStyleTable(UITableView *table);
void VDTStyleCell(UITableViewCell *cell);
