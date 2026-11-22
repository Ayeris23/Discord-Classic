#import <UIKit/UIKit.h>

@interface DCActionSheetPresenter : NSObject
+ (void)showActionSheet:(UIActionSheet *)sheet
              fromView:(UIView *)sourceView
                inView:(UIView *)containerView
              animated:(BOOL)animated;
@end
