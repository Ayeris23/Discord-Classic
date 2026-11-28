//
//  DCPrivateChannelTableCell.m
//  Discord Classic
//
//  Created by XML on 28/12/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCPrivateChannelTableCell.h"
#import "DCFontManager.h"
#import "DCLabel.h"
#import <math.h>

@interface DCPrivateChannelTableCell ()
@property (strong, nonatomic) UIFont *baseNameFont;
- (void)installLegacyNameLabel;
@end

@implementation DCPrivateChannelTableCell


- (void)awakeFromNib {
    [super awakeFromNib];
    if ([[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"]) {
        [self installLegacyNameLabel];
    }
    self.mentionBadge = [MentionBadge badgeWithCount:0];
    [self.contentView addSubview:self.mentionBadge];
}

- (void)installLegacyNameLabel {
    UILabel *original = self.nameLabel;
    UIView *parent = original.superview;
    if (!parent || [original isKindOfClass:[DCLabel class]]) return;

    DCLabel *label = [[DCLabel alloc] initWithFrame:original.frame];
    label.autoresizingMask = original.autoresizingMask;
    label.contentMode = original.contentMode;
    label.opaque = original.opaque;
    label.clipsToBounds = original.clipsToBounds;
    label.backgroundColor = original.backgroundColor;
    label.alpha = original.alpha;
    label.hidden = original.hidden;
    label.tag = original.tag;
    label.userInteractionEnabled = original.userInteractionEnabled;
    label.font = original.font;
    label.textColor = original.textColor;
    label.highlightedTextColor = original.highlightedTextColor;
    label.shadowColor = original.shadowColor;
    label.shadowOffset = original.shadowOffset;
    label.textAlignment = original.textAlignment;
    label.lineBreakMode = original.lineBreakMode;
    label.baselineAdjustment = original.baselineAdjustment;
    label.numberOfLines = original.numberOfLines;
    label.adjustsFontSizeToFitWidth = original.adjustsFontSizeToFitWidth;
    label.highlighted = original.highlighted;
    label.enabled = original.enabled;
    label.text = original.text;
    label.isAccessibilityElement = original.isAccessibilityElement;
    label.accessibilityTraits = original.accessibilityTraits;

    [parent insertSubview:label aboveSubview:original];
    self.nameLabel = label;
    [original removeFromSuperview];
}

- (void)setDisplayName:(NSString *)displayName {
    if (!self.baseNameFont) self.baseNameFont = self.nameLabel.font;
    [[DCFontManager sharedManager] setText:displayName forLabel:self.nameLabel
                                 baseFont:self.baseNameFont];
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
