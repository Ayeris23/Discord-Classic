//
//  DCIPadSplitViewController.h
//  Discord Classic
//
//  Created by Ayeris on 9/16/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCIPadSplitViewController : UISplitViewController <UISplitViewControllerDelegate, UIGestureRecognizerDelegate>

- (void)showPortraitSidebarAnimated:(BOOL)animated;
- (void)hidePortraitSidebarAnimated:(BOOL)animated;
- (BOOL)isPortraitSidebarVisible;

@end
