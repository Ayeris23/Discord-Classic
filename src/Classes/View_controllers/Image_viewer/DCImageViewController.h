//
//  DCImageViewController.h
//  Discord Classic
//
//  Created by Trevir on 11/17/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>
#import "APLSlideMenuViewController.h"

@class DCMessage;

extern NSString * const DCImageViewerUnderlyingGeometryDidChangeNotification;

@interface DCImageViewController : UIViewController<UIScrollViewDelegate, UIActionSheetDelegate,
        MFMailComposeViewControllerDelegate, MFMessageComposeViewControllerDelegate>

+ (BOOL)isImageViewerActive;

@property (weak, nonatomic) IBOutlet UIImageView *imageView;
@property (strong, nonatomic) IBOutlet UIScrollView *scrollView;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *share;
@property (nonatomic, assign) BOOL chromeVisible;
@property (weak, nonatomic) IBOutlet UINavigationBar *navBar;
@property (strong, nonatomic) NSURL *fullResURL;
@property (strong, nonatomic) UIImage *previewImage;
@property (strong, nonatomic) DCMessage *sourceMessage;

@end
