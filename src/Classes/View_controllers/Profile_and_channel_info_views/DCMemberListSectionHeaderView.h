//
//  DCMemberListSectionHeaderView.h
//  Discord Classic
//

#import <UIKit/UIKit.h>

@interface DCMemberListSectionHeaderView : UIView

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) CGFloat titleInset;

+ (CGFloat)headerHeight;

@end
