//
//  DCConnectionPopup.h
//  Discord Classic
//
//  Created by Ayeris on 9/16/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface DCConnectionPopup : NSObject

+ (DCConnectionPopup *)sharedPopup;
- (void)showWithTitle:(NSString *)title;
- (void)dismiss;
- (void)setHostView:(UIView *)hostView;
- (void)clearHostView:(UIView *)hostView;

@end
