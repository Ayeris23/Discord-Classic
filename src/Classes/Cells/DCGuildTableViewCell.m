//
//  DCGuildTableViewCell.m
//  Discord Classic
//
//  Created by XML on 22/12/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCGuildTableViewCell.h"
#import <math.h>

@implementation DCGuildTableViewCell

- (void)awakeFromNib {
    [super awakeFromNib];

    // Guild chrome and the 40pt source icon are precomposited into guildAvatar.
    for (UIView *view in self.contentView.subviews) {
        if (view == self.guildAvatar || ![view isKindOfClass:[UIImageView class]])
            continue;
        CGRect frame = view.frame;
        if (fabs(frame.origin.x - 6.0f) < 0.5f &&
            fabs(frame.origin.y - 5.0f) < 0.5f &&
            fabs(frame.size.width - 48.0f) < 0.5f &&
            fabs(frame.size.height - 48.0f) < 0.5f) {
            view.hidden = YES;
            break;
        }
    }

    // guildAvatar displays the complete 48pt tile.
    self.guildAvatar.frame = CGRectMake(6.0f, 5.0f, 48.0f, 48.0f);

    self.mentionBadge = [MentionBadge badgeWithCount:0];
    [self.contentView addSubview:self.mentionBadge];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
}

@end
