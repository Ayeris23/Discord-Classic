//
//  DCViewController.m
//  Discord Classic
//
//  Created by bag.xml on 3/4/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCViewController.h"
#import "DCGuildListViewController.h"
#import "DCServerCommunicator.h"
#import "DCImageViewController.h"
#import "DCInterfaceStyle.h"

@implementation DCViewController

+ (void)initialize {
    if (self != [DCViewController class]) {
        return;
    }

    UIBarButtonItem *navigationBarButtons =
        [UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class],
                                                [DCViewController class],
                                                nil];

    [navigationBarButtons
        setBackButtonBackgroundImage:[DCInterfaceStyle navigationBackButtonBackgroundImage]
                            forState:UIControlStateNormal
                          barMetrics:UIBarMetricsDefault];
    [navigationBarButtons
        setBackButtonBackgroundImage:[DCInterfaceStyle navigationBackButtonPressedBackgroundImage]
                            forState:UIControlStateHighlighted
                          barMetrics:UIBarMetricsDefault];
}

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad ||
        [DCImageViewController isImageViewerActive]) {
        return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
    }
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad ||
        [DCImageViewController isImageViewerActive]) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return UIInterfaceOrientationMaskPortrait;
}

@end
