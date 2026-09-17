//
//  DCIPadSplitViewController.m
//  Discord Classic
//
//  Created by Ayeris on 9/16/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCIPadSplitViewController.h"

@implementation DCIPadSplitViewController

- (void)awakeFromNib {
    [super awakeFromNib];
    self.delegate = self;
}

- (BOOL)splitViewController:(UISplitViewController *)splitViewController
    shouldHideViewController:(UIViewController *)viewController
               inOrientation:(UIInterfaceOrientation)orientation {
    return NO;
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
