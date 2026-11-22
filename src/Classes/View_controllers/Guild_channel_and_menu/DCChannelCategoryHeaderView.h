//
//  DCChannelCategoryHeaderView.h
//  Discord Classic
//

#import "DCMemberListSectionHeaderView.h"

@interface DCChannelCategoryHeaderView : DCMemberListSectionHeaderView

@property (nonatomic, copy) NSString *categoryID;
@property (nonatomic, assign) NSInteger section;
@property (nonatomic, assign, getter=isCollapsed) BOOL collapsed;

@end
