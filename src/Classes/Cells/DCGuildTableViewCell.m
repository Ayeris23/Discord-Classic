//
//  DCGuildTableViewCell.m
//  Discord Classic
//
//  Created by XML on 22/12/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCGuildTableViewCell.h"
#import <math.h>

@interface DCGuildTableViewCell ()
@property (strong, nonatomic) MentionBadge *folderBadgeTransition;
@end

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

- (CGRect)frameForMentionBadge:(MentionBadge *)badge {
    CGSize size = [badge sizeThatFits:CGSizeZero];
    CGRect avatarFrame = CGRectInset(self.guildAvatar.frame, 4.0f, 4.0f);
    return CGRectMake(CGRectGetMaxX(avatarFrame) - size.width + 8.0f,
                      CGRectGetMaxY(avatarFrame) - size.height + 8.0f,
                      size.width, size.height);
}

- (void)cancelFolderBadgeAnimation {
    if (self.folderBadgeTransition) {
        [self.folderBadgeTransition.layer removeAllAnimations];
        [self.folderBadgeTransition removeFromSuperview];
        self.folderBadgeTransition = nil;
    }
    self.mentionBadge.hidden = (self.mentionBadge.mentionCount == 0);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self cancelFolderBadgeAnimation];
}

- (void)animateFolderBadgeWithCount:(NSInteger)count opened:(BOOL)opened {
    [self cancelFolderBadgeAnimation];
    count = MAX((NSInteger)0, count);
    self.mentionBadge.mentionCount = opened ? 0 : count;
    if (!count || !self.mentionBadge || !self.guildAvatar) {
        [self setNeedsLayout];
        return;
    }

    MentionBadge *movingBadge = [MentionBadge badgeWithCount:count];
    movingBadge.userInteractionEnabled = NO;
    movingBadge.frame = [self frameForMentionBadge:movingBadge];
    if (!opened) {
        self.mentionBadge.hidden = YES;
        CGRect frame = movingBadge.frame;
        frame.origin.y += 14.0f;
        movingBadge.frame = frame;
        movingBadge.alpha = 0.0f;
    }
    [self.contentView addSubview:movingBadge];
    self.folderBadgeTransition = movingBadge;

    __weak DCGuildTableViewCell *weakSelf = self;
    [UIView animateWithDuration:0.30f
                          delay:0.0f
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        CGRect frame = movingBadge.frame;
        frame.origin.y += opened ? 14.0f : -14.0f;
        movingBadge.frame = frame;
        movingBadge.alpha = opened ? 0.0f : 1.0f;
    } completion:^(BOOL finished) {
        DCGuildTableViewCell *cell = weakSelf;
        if (!cell || cell.folderBadgeTransition != movingBadge) return;
        [movingBadge removeFromSuperview];
        cell.folderBadgeTransition = nil;
        cell.mentionBadge.hidden = (cell.mentionBadge.mentionCount == 0);
        [cell setNeedsLayout];
        [cell layoutIfNeeded];
    }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.mentionBadge.hidden) return;
    self.mentionBadge.frame = [self frameForMentionBadge:self.mentionBadge];
}

@end
