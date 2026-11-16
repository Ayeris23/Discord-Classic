//
//  DCPrivateChannelTableCell.m
//  Discord Classic
//
//  Created by XML on 28/12/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCPrivateChannelTableCell.h"
#import <math.h>

@implementation DCPrivateChannelTableCell


- (void)awakeFromNib {
    [super awakeFromNib];
    self.mentionBadge = [MentionBadge badgeWithCount:0];
    [self.contentView addSubview:self.mentionBadge];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat contentWidth = CGRectGetWidth(self.contentView.bounds);
    if (contentWidth <= 0.0f) return;

    CGFloat rightEdge = contentWidth - 10.0f;
    if (!self.mentionBadge.hidden) {
        CGSize badgeSize = [self.mentionBadge sizeThatFits:CGSizeZero];
        self.mentionBadge.frame = CGRectMake(
            contentWidth - badgeSize.width - 10.0f,
            (CGRectGetHeight(self.contentView.bounds) - badgeSize.height) * 0.5f - 1.0f,
            badgeSize.width, badgeSize.height);
        rightEdge = CGRectGetMinX(self.mentionBadge.frame) - 8.0f;
    }

    CGRect labelFrame = self.nameLabel.frame;
    CGFloat labelWidth = MAX(0.0f, rightEdge - CGRectGetMinX(labelFrame));
    if (fabs(CGRectGetWidth(labelFrame) - labelWidth) > 0.5f) {
        labelFrame.size.width = labelWidth;
        self.nameLabel.frame = labelFrame;
    }
}

@end
