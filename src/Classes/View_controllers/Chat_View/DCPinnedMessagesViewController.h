//
//  DCPinnedMessagesViewController.h
//  Discord Classic
//
//  Created by Ayeris on 11/22/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@class DCChannel;

@interface DCPinnedMessagesViewController : UIViewController <UIPopoverControllerDelegate>

+ (void)presentForChannel:(DCChannel *)channel
          fromController:(UIViewController *)presenter
     sourceBarButtonItem:(UIBarButtonItem *)barButtonItem;

@end
