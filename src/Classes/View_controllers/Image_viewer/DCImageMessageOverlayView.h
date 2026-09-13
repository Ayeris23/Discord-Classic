//
//  DCImageMessageOverlayView.h
//  Discord Classic
//
//  Created by Ayeris on 9/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@class DCMessage;

@interface DCImageMessageOverlayView : UIView

@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;
@property (nonatomic, readonly) BOOL canExpand;

- (id)initWithMessage:(DCMessage *)message frame:(CGRect)frame;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)layoutForSuperviewBounds:(CGRect)bounds;

@end
