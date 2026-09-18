//
//  DCIPadSplitViewController.m
//  Discord Classic
//
//  Created by Ayeris on 9/16/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCIPadSplitViewController.h"
#import "DCInterfaceStyle.h"
static const CGFloat DCIPadPortraitSidebarWidth = 320.0f;

@interface DCIPadSplitViewController ()
@property (strong, nonatomic) UIView *portraitSidebarDimmingView;
@property (strong, nonatomic) UIView *portraitSidebarContainerView;
@property (strong, nonatomic) UISwipeGestureRecognizer *portraitOpenSwipeRecognizer;
@property (strong, nonatomic) UISwipeGestureRecognizer *portraitCloseSwipeRecognizer;
@property (strong, nonatomic) UIBarButtonItem *savedMasterRightBarButtonItem;
@property (strong, nonatomic) UINavigationItem *masterNavigationItemWithCloseButton;
@property (assign, nonatomic) BOOL savedMasterRightBarButtonItemValid;
@property (assign, nonatomic) BOOL portraitSidebarVisible;
@end

@implementation DCIPadSplitViewController

- (void)awakeFromNib {
    [super awakeFromNib];
    self.delegate = self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UISwipeGestureRecognizer *openSwipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(portraitOpenSwipeRecognized:)];
    openSwipe.direction = UISwipeGestureRecognizerDirectionRight;
    openSwipe.cancelsTouchesInView = NO;
    openSwipe.delegate = self;
    [self.view addGestureRecognizer:openSwipe];
    self.portraitOpenSwipeRecognizer = openSwipe;

    UISwipeGestureRecognizer *closeSwipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(portraitCloseSwipeRecognized:)];
    closeSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    closeSwipe.cancelsTouchesInView = NO;
    closeSwipe.delegate = self;
    [self.view addGestureRecognizer:closeSwipe];
    self.portraitCloseSwipeRecognizer = closeSwipe;
}

- (BOOL)isPortraitOrientation {
    return UIInterfaceOrientationIsPortrait(
        [UIApplication sharedApplication].statusBarOrientation);
}

- (UIViewController *)masterViewController {
    return self.viewControllers.count > 0
        ? [self.viewControllers objectAtIndex:0]
        : nil;
}

- (UINavigationController *)masterNavigationController {
    UIViewController *master = [self masterViewController];
    return [master isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)master
        : nil;
}

- (CGFloat)portraitSidebarWidth {
    return MIN(DCIPadPortraitSidebarWidth, self.view.bounds.size.width);
}

- (void)installCloseButton {
    UINavigationController *navigationController =
        [self masterNavigationController];
    UIViewController *topViewController = navigationController.topViewController;
    if (!topViewController || self.savedMasterRightBarButtonItemValid) {
        return;
    }

    self.savedMasterRightBarButtonItem =
        topViewController.navigationItem.rightBarButtonItem;
    self.masterNavigationItemWithCloseButton = topViewController.navigationItem;
    self.savedMasterRightBarButtonItemValid = YES;

    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc]
        initWithTitle:@"Close"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(closeButtonPressed:)];
    [closeButton setBackgroundImage:[DCInterfaceStyle barButtonBackgroundImage]
                           forState:UIControlStateNormal
                         barMetrics:UIBarMetricsDefault];
    [closeButton setBackgroundImage:[DCInterfaceStyle barButtonPressedBackgroundImage]
                           forState:UIControlStateHighlighted
                         barMetrics:UIBarMetricsDefault];
    topViewController.navigationItem.rightBarButtonItem = closeButton;
}

- (void)restoreMasterRightBarButtonItem {
    if (!self.savedMasterRightBarButtonItemValid) {
        return;
    }

    self.masterNavigationItemWithCloseButton.rightBarButtonItem =
        self.savedMasterRightBarButtonItem;

    self.savedMasterRightBarButtonItem = nil;
    self.masterNavigationItemWithCloseButton = nil;
    self.savedMasterRightBarButtonItemValid = NO;
}

- (void)closeButtonPressed:(id)sender {
    [self hidePortraitSidebarAnimated:YES];
}

- (void)portraitOpenSwipeRecognized:(UISwipeGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded &&
        [self isPortraitOrientation] &&
        !self.portraitSidebarVisible) {
        [self showPortraitSidebarAnimated:YES];
    }
}

- (void)portraitCloseSwipeRecognized:(UISwipeGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded &&
        [self isPortraitOrientation] &&
        self.portraitSidebarVisible) {
        [self hidePortraitSidebarAnimated:YES];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.portraitOpenSwipeRecognizer) {
        return [self isPortraitOrientation] && !self.portraitSidebarVisible;
    }
    if (gestureRecognizer == self.portraitCloseSwipeRecognizer) {
        return [self isPortraitOrientation] && self.portraitSidebarVisible;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return gestureRecognizer == self.portraitOpenSwipeRecognizer ||
           otherGestureRecognizer == self.portraitOpenSwipeRecognizer ||
           gestureRecognizer == self.portraitCloseSwipeRecognizer ||
           otherGestureRecognizer == self.portraitCloseSwipeRecognizer;
}

- (void)dimmingViewTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self hidePortraitSidebarAnimated:YES];
    }
}

- (UIView *)buildDimmingView {
    UIView *view = [[UIView alloc] initWithFrame:self.view.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.4f];
    view.alpha = 0.0f;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(dimmingViewTapped:)];
    [view addGestureRecognizer:tap];
    return view;
}

- (UIView *)buildPortraitSidebarContainerWithFrame:(CGRect)frame {
    UIView *view = [[UIView alloc] initWithFrame:frame];
    view.clipsToBounds = YES;
    view.backgroundColor = [UIColor clearColor];
    return view;
}

- (void)layoutVisiblePortraitSidebar {
    if (!self.portraitSidebarVisible || ![self isPortraitOrientation]) {
        return;
    }

    UIView *dimmingView = self.portraitSidebarDimmingView;
    UIView *containerView = self.portraitSidebarContainerView;
    UIView *masterView = [self masterViewController].view;
    if (!dimmingView || !containerView || !masterView) {
        return;
    }

    dimmingView.frame = self.view.bounds;

    if (dimmingView.superview != self.view) {
        [self.view addSubview:dimmingView];
    }
    if (containerView.superview != self.view) {
        [self.view addSubview:containerView];
    }
    if (masterView.superview != containerView) {
        [containerView addSubview:masterView];
    }

    masterView.frame = containerView.bounds;
    masterView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    masterView.hidden = NO;
    masterView.alpha = 1.0f;

    [self.view bringSubviewToFront:dimmingView];
    [self.view bringSubviewToFront:containerView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutVisiblePortraitSidebar];
}

- (void)showPortraitSidebarAnimated:(BOOL)animated {
    if (![self isPortraitOrientation] || self.portraitSidebarVisible) {
        return;
    }

    UIView *masterView = [self masterViewController].view;
    if (!masterView) {
        return;
    }

    CGFloat width = [self portraitSidebarWidth];
    CGRect finalFrame = CGRectMake(0.0f,
                                   0.0f,
                                   width,
                                   self.view.bounds.size.height);
    CGRect hiddenFrame = finalFrame;
    hiddenFrame.origin.x = -width;

    UIView *dimmingView = [self buildDimmingView];
    UIView *containerView = [self buildPortraitSidebarContainerWithFrame:
        animated ? hiddenFrame : finalFrame];
    self.portraitSidebarDimmingView = dimmingView;
    self.portraitSidebarContainerView = containerView;
    self.portraitSidebarVisible = YES;

    [self.view addSubview:dimmingView];
    [self.view addSubview:containerView];
    [containerView addSubview:masterView];
    masterView.frame = containerView.bounds;
    masterView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    masterView.hidden = NO;
    masterView.alpha = 1.0f;

    [self installCloseButton];
    [self layoutVisiblePortraitSidebar];

    void (^changes)(void) = ^{
        containerView.frame = finalFrame;
        masterView.frame = containerView.bounds;
        dimmingView.alpha = 1.0f;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)finishHidingPortraitSidebar {
    UIView *masterView = [self masterViewController].view;

    self.portraitSidebarVisible = NO;
    [self.portraitSidebarDimmingView removeFromSuperview];
    [self.portraitSidebarContainerView removeFromSuperview];
    self.portraitSidebarDimmingView = nil;
    self.portraitSidebarContainerView = nil;
    [self restoreMasterRightBarButtonItem];

    if ([self isPortraitOrientation]) {
        masterView.hidden = YES;
        [self.view addSubview:masterView];
        [self.view sendSubviewToBack:masterView];
    }
}

- (void)hidePortraitSidebarAnimated:(BOOL)animated {
    if (!self.portraitSidebarVisible) {
        return;
    }

    UIView *containerView = self.portraitSidebarContainerView;
    UIView *dimmingView = self.portraitSidebarDimmingView;
    CGRect hiddenFrame = containerView.frame;
    hiddenFrame.origin.x = -hiddenFrame.size.width;

    void (^changes)(void) = ^{
        containerView.frame = hiddenFrame;
        dimmingView.alpha = 0.0f;
    };

    void (^completion)(BOOL) = ^(BOOL finished) {
        [self finishHidingPortraitSidebar];
    };

    if (animated) {
        [UIView animateWithDuration:0.20
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseIn
                         animations:changes
                         completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

- (BOOL)isPortraitSidebarVisible {
    return self.portraitSidebarVisible;
}

- (BOOL)splitViewController:(UISplitViewController *)splitViewController
    shouldHideViewController:(UIViewController *)viewController
               inOrientation:(UIInterfaceOrientation)orientation {
    return UIInterfaceOrientationIsPortrait(orientation);
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                 duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation
                                     duration:duration];

    if (!UIInterfaceOrientationIsLandscape(toInterfaceOrientation)) {
        return;
    }

    UIView *masterView = [self masterViewController].view;
    if (!masterView) {
        return;
    }

    if (self.portraitSidebarVisible) {
        CGRect masterFrame = [self.portraitSidebarContainerView
            convertRect:masterView.frame
              toView:self.view];

        [masterView removeFromSuperview];
        [self.view addSubview:masterView];
        masterView.frame = masterFrame;

        [self.portraitSidebarContainerView removeFromSuperview];
        self.portraitSidebarContainerView = nil;
        self.portraitSidebarVisible = NO;
        [self restoreMasterRightBarButtonItem];
    }

    masterView.hidden = NO;
    masterView.alpha = 1.0f;
    [self.view setNeedsLayout];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                         duration:(NSTimeInterval)duration {
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation
                                            duration:duration];

    UIView *masterView = [self masterViewController].view;
    if (UIInterfaceOrientationIsLandscape(toInterfaceOrientation)) {
        self.portraitSidebarDimmingView.alpha = 0.0f;
    } else {
        masterView.alpha = 0.0f;
    }
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];

    if ([self isPortraitOrientation]) {
        UIView *masterView = [self masterViewController].view;
        masterView.alpha = 1.0f;
        if (!self.portraitSidebarVisible) {
            masterView.hidden = YES;
        }
        return;
    }

    UIView *masterView = [self masterViewController].view;
    self.portraitSidebarVisible = NO;
    [self.portraitSidebarDimmingView removeFromSuperview];
    [self.portraitSidebarContainerView removeFromSuperview];
    self.portraitSidebarDimmingView = nil;
    self.portraitSidebarContainerView = nil;
    [self restoreMasterRightBarButtonItem];

    masterView.hidden = NO;
    masterView.alpha = 1.0f;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

@end
