//
//  DCChatTableCell.m
//  Discord Classic
//
//  Created by bag.xml on 4/7/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCChatTableCell.h"
#include "DCChatVideoAttachment.h"
#import "DCChatGifAttachment.h"
#import "UILazyImageView.h"

@implementation DCChatTableCell

- (void)awakeFromNib {
    self.profileImage.backgroundColor = [UIColor clearColor];
    self.profileImage.opaque = NO;
    self.referencedProfileImage.backgroundColor = [UIColor clearColor];
    self.referencedProfileImage.opaque = NO;
    self.referencedMessage.backgroundColor = [UIColor clearColor];
    
    self.contentTextView.frame = self.contentTextView.frame;
    self.contentTextView.backgroundColor = [UIColor clearColor];
    self.contentTextView.shouldLayoutCustomSubviews = NO;
    self.contentTextView.numberOfLines = 0;
    self.contentTextView.shouldDrawLinks = YES;
    self.contentTextView.userInteractionEnabled = YES;
    self.contentTextView.relayoutMask = DTAttributedTextContentViewRelayoutOnWidthChanged;
}

- (void)prepareForReuse {
    // iOS 5 lacks didEndDisplayingCell:, so reuse is the reliable release point for decoded media.
    for (UIView *subview in [NSArray arrayWithArray:self.subviews]) {
        if ([subview isKindOfClass:[UILazyImageView class]]) {
            [(UILazyImageView *)subview releaseChatThumbnailForResidency];
        } else if ([subview isKindOfClass:[DCChatVideoAttachment class]]) {
            [(DCChatVideoAttachment *)subview releaseThumbnailForResidency];
        } else if ([subview isKindOfClass:[DCChatGifAttachment class]]) {
            [(DCChatGifAttachment *)subview releaseThumbnailForResidency];
        }
    }

    [super prepareForReuse];
}

@end