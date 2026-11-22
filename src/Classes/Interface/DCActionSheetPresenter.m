#import "DCActionSheetPresenter.h"

@implementation DCActionSheetPresenter

+ (void)showActionSheet:(UIActionSheet *)sheet
              fromView:(UIView *)sourceView
                inView:(UIView *)containerView
              animated:(BOOL)animated {
    if (!sheet || !containerView) return;

    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) {
        [sheet showInView:containerView];
        return;
    }

    CGRect anchorRect = CGRectNull;
    if (sourceView && sourceView.window && containerView.window &&
        sourceView.window == containerView.window) {
        anchorRect = [sourceView convertRect:sourceView.bounds toView:containerView];
        UIView *ancestor = sourceView;
        while (ancestor && ancestor != containerView.window) {
            if (ancestor.hidden || ancestor.alpha <= 0.01f) {
                anchorRect = CGRectNull;
                break;
            }
            if (ancestor.clipsToBounds) {
                CGRect visible = [ancestor convertRect:ancestor.bounds
                                                 toView:containerView];
                anchorRect = CGRectIntersection(anchorRect, visible);
                if (CGRectIsNull(anchorRect) || CGRectIsEmpty(anchorRect)) break;
            }
            ancestor = ancestor.superview;
        }
        anchorRect = CGRectIntersection(anchorRect, containerView.bounds);
    }

    if (CGRectIsNull(anchorRect) || CGRectIsEmpty(anchorRect)) {
        CGPoint middle = CGPointMake(CGRectGetMidX(containerView.bounds),
                                     CGRectGetMidY(containerView.bounds));
        anchorRect = CGRectMake(middle.x, middle.y, 1.0f, 1.0f);
    }

    [sheet showFromRect:anchorRect inView:containerView animated:animated];
}

@end
