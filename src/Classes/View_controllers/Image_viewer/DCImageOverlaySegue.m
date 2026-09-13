//
//  DCImageOverlaySegue.m
//  Discord Classic
//
//  Created by Ayeris on 9/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCImageOverlaySegue.h"
#import "DCImageViewController.h"

@interface DCImageViewController (DCImageOverlayHosting)
- (void)dc_prepareForOverlayPresentationInWindow:(UIWindow *)window
                               previousKeyWindow:(UIWindow *)previousKeyWindow
                                     dimmingView:(UIView *)dimmingView;
@end

@implementation DCImageOverlaySegue

- (void)perform {
    UIViewController *sourceViewController = self.sourceViewController;
    DCImageViewController *imageViewController =
        [self.destinationViewController isKindOfClass:[DCImageViewController class]]
            ? (DCImageViewController *)self.destinationViewController
            : nil;
    if (!imageViewController) return;

    UIApplication *application = [UIApplication sharedApplication];
    UIWindow *sourceWindow = sourceViewController.view.window ?: application.keyWindow;
    if (!sourceWindow) return;

    UIWindow *previousKeyWindow = application.keyWindow ?: sourceWindow;
    UIWindow *overlayWindow = [[UIWindow alloc] initWithFrame:sourceWindow.frame];
    overlayWindow.backgroundColor = [UIColor clearColor];
    overlayWindow.opaque = NO;
    overlayWindow.windowLevel = sourceWindow.windowLevel + 1.0f;

    UIView *imageViewerView = imageViewController.view;
    imageViewerView.backgroundColor = [UIColor clearColor];
    imageViewerView.opaque = NO;

    UIView *dimmingView = [[UIView alloc] initWithFrame:imageViewerView.bounds];
    dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dimmingView.backgroundColor = [UIColor blackColor];
    [imageViewerView insertSubview:dimmingView atIndex:0];

    overlayWindow.rootViewController = imageViewController;
    [imageViewController dc_prepareForOverlayPresentationInWindow:overlayWindow
                                                previousKeyWindow:previousKeyWindow
                                                      dimmingView:dimmingView];

    dimmingView.alpha = 0.0f;
    imageViewerView.alpha = 0.0f;
    [overlayWindow makeKeyAndVisible];

    [UIView animateWithDuration:0.16 animations:^{
        dimmingView.alpha = 1.0f;
        imageViewerView.alpha = 1.0f;
    }];
}

@end
