//
//  DCThreadCreateViewController.h
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@class DCChannel;

@interface DCThreadCreateViewController : UIViewController

- (id)initWithParentChannel:(DCChannel *)channel;

@end
