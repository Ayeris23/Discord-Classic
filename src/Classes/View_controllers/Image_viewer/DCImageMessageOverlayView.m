//
//  DCImageMessageOverlayView.m
//  Discord Classic
//
//  Created by Ayeris on 9/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCImageMessageOverlayView.h"
#import "DCChatTableCell.h"
#import "DCMessage.h"
#import "DCMessageLayout.h"
#import "DCMessageLayoutBuilder.h"
#import "DCMarkdownParser.h"
#import "DCServerCommunicator.h"
#import "DCChannel.h"
#import "DCGuild.h"
#import "DCUser.h"
#import "DCTools.h"

static const CGFloat DCImageMessageOverlayCollapsedHeight = 53.0f;
static const CGFloat DCImageMessageOverlayBottomPadding = 6.0f;

@interface DCImageMessageOverlayView ()
@property (nonatomic, retain) DCMessage *message;
@property (nonatomic, retain) DCChatTableCell *collapsedCell;
@property (nonatomic, retain) DCChatTableCell *expandedCell;
@property (nonatomic, retain) UIScrollView *expandedScrollView;
@property (nonatomic, retain) DCMessageLayoutBuilder *layoutBuilder;
@property (nonatomic, assign, getter=isExpanded) BOOL expanded;
@property (nonatomic, assign) BOOL canExpand;
@property (nonatomic, assign) CGFloat expandedNaturalHeight;
@property (nonatomic, retain) UITapGestureRecognizer *tapRecognizer;
@end

@implementation DCImageMessageOverlayView

- (id)initWithMessage:(DCMessage *)message frame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.message = message;
    self.layoutBuilder = [[DCMessageLayoutBuilder alloc] init];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.58f];

    self.collapsedCell = [self dc_newMessageCell];
    self.expandedCell = [self dc_newMessageCell];

    if (self.collapsedCell) {
        [self addSubview:self.collapsedCell];
    }

    UIScrollView *expandedScrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
    expandedScrollView.backgroundColor = [UIColor clearColor];
    expandedScrollView.opaque = NO;
    expandedScrollView.showsVerticalScrollIndicator = YES;
    expandedScrollView.alwaysBounceVertical = NO;
    expandedScrollView.alpha = 0.0f;
    expandedScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.expandedScrollView = expandedScrollView;
    [self addSubview:expandedScrollView];
    if (self.expandedCell) {
        [expandedScrollView addSubview:self.expandedCell];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dc_didTapOverlay:)];
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = YES;
    self.tapRecognizer = tap;
    [self addGestureRecognizer:tap];

    [self layoutForSuperviewBounds:CGRectMake(0.0f, 0.0f, frame.size.width, frame.origin.y + frame.size.height)];
    return self;
}

- (DCChatTableCell *)dc_newMessageCell {
    NSArray *objects = [[NSBundle mainBundle] loadNibNamed:@"DCChatTableCell"
                                                     owner:nil
                                                   options:nil];
    DCChatTableCell *cell = nil;
    for (id object in objects) {
        if ([object isKindOfClass:[DCChatTableCell class]]) {
            cell = object;
            break;
        }
    }
    if (!cell) return nil;

    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
    cell.contentTextView.userInteractionEnabled = NO;
    cell.contentTextView.shouldDrawLinks = NO;
    cell.referencedProfileImage.hidden = YES;
    cell.referencedAuthorLabel.hidden = YES;
    cell.referencedMessage.hidden = YES;
    cell.separatorLow.hidden = YES;
    cell.separatorHigh.hidden = YES;
    cell.universalImageView.hidden = YES;
    return cell;
}

- (NSAttributedString *)dc_attributedContent {
    NSAttributedString *content = self.message.attributedContent;
    if (!content && self.message.content.length) {
        content = [[DCMarkdownParser sharedParser]
            attributedStringFromMarkdown:self.message.content];
    }
    if (content.length) return content;

    return [[DCMarkdownParser sharedParser]
        attributedStringFromMarkdown:@"Image attachment"];
}

- (void)dc_configureHeaderForCell:(DCChatTableCell *)cell width:(CGFloat)width {
    if (!cell) return;

    DCGuild *guild = DCServerCommunicator.sharedInstance.selectedChannel.parentGuild;
    NSString *displayName = [self.message.author displayNameInGuild:guild] ?: @"";
    NSString *timestamp = self.message.prettyTimestamp ?: @"";

    UIImage *avatar = [DCTools cachedUserAvatar:self.message.author inGuild:guild];
    cell.profileImage.image = avatar ?: self.message.author.profileImage;
    cell.avatarDecoration.image = nil;
    cell.authorLabel.text = displayName;
    cell.timestampLabel.text = timestamp;

    CGFloat authorOriginX = 55.0f;
    CGFloat gap = 8.0f;
    CGFloat rightPadding = 8.0f;
    CGSize timestampSize = [timestamp sizeWithFont:cell.timestampLabel.font];
    CGSize nameSize = [displayName sizeWithFont:cell.authorLabel.font];
    CGFloat maxRightEdge = MAX(authorOriginX, width - rightPadding);
    CGFloat naturalTimestampX = authorOriginX + nameSize.width + gap;
    CGFloat maxTimestampX = MAX(authorOriginX, maxRightEdge - timestampSize.width);
    CGFloat actualTimestampX = MIN(naturalTimestampX, maxTimestampX);
    CGFloat actualNameWidth = MAX(0.0f, actualTimestampX - authorOriginX - gap);

    cell.authorLabel.frame = CGRectMake(authorOriginX,
                                        cell.authorLabel.frame.origin.y,
                                        actualNameWidth,
                                        cell.authorLabel.frame.size.height);
    cell.timestampLabel.frame = CGRectMake(actualTimestampX,
                                           cell.timestampLabel.frame.origin.y,
                                           timestampSize.width,
                                           cell.timestampLabel.frame.size.height);
}

- (CGFloat)dc_naturalExpandedHeightForWidth:(CGFloat)width {
    CGFloat tableWidth = MAX(80.0f, width);
    DCMessageLayout *layout = [self.layoutBuilder layoutForMessage:self.message
                                                   previousMessage:nil
                                                       nextMessage:nil
                                                        tableWidth:tableWidth];
    CGFloat textHeight = layout.textHeight;
    if (textHeight <= 0.0f) textHeight = 18.0f;
    return MAX(DCImageMessageOverlayCollapsedHeight,
               28.0f + textHeight + DCImageMessageOverlayBottomPadding);
}

- (void)dc_configureCell:(DCChatTableCell *)cell
                   width:(CGFloat)width
                expanded:(BOOL)expanded {
    if (!cell) return;

    CGFloat naturalHeight = expanded
        ? [self dc_naturalExpandedHeightForWidth:width]
        : DCImageMessageOverlayCollapsedHeight;

    cell.frame = CGRectMake(0.0f, 0.0f, width, naturalHeight);
    cell.contentView.frame = cell.bounds;
    [self dc_configureHeaderForCell:cell width:width];

    CGFloat contentWidth = MAX(0.0f, width - 63.0f);
    NSAttributedString *attributedContent = [self dc_attributedContent];
    cell.contentTextView.layoutFrame = nil;
    cell.contentTextView.attributedString = attributedContent;
    cell.contentTextView.hidden = NO;
    cell.contentTextView.lineBreakMode = expanded
        ? NSLineBreakByWordWrapping
        : NSLineBreakByTruncatingTail;
    cell.contentTextView.numberOfLines = expanded ? 0 : 1;

    CGFloat textHeight = expanded
        ? MAX(18.0f, naturalHeight - 28.0f - DCImageMessageOverlayBottomPadding)
        : 21.0f;
    cell.contentTextView.frame = CGRectMake(55.0f, 28.0f, contentWidth, textHeight);
    [cell.contentTextView setNeedsLayout];
}

- (void)layoutForSuperviewBounds:(CGRect)bounds {
    CGFloat width = bounds.size.width;
    if (width <= 0.0f) return;

    self.expandedNaturalHeight = [self dc_naturalExpandedHeightForWidth:width];
    self.canExpand = self.expandedNaturalHeight > DCImageMessageOverlayCollapsedHeight + 1.0f;
    if (!self.canExpand) _expanded = NO;
    self.tapRecognizer.enabled = self.canExpand;

    CGFloat maxExpandedHeight = MAX(DCImageMessageOverlayCollapsedHeight,
                                    bounds.size.height - 64.0f);
    CGFloat visibleHeight = self.expanded
        ? MIN(self.expandedNaturalHeight, maxExpandedHeight)
        : DCImageMessageOverlayCollapsedHeight;

    self.frame = CGRectMake(0.0f,
                            bounds.size.height - visibleHeight,
                            width,
                            visibleHeight);

    [self dc_configureCell:self.collapsedCell width:width expanded:NO];
    [self dc_configureCell:self.expandedCell width:width expanded:YES];

    self.collapsedCell.frame = CGRectMake(0.0f,
                                          0.0f,
                                          width,
                                          DCImageMessageOverlayCollapsedHeight);

    self.expandedScrollView.frame = self.bounds;
    self.expandedCell.frame = CGRectMake(0.0f,
                                         0.0f,
                                         width,
                                         self.expandedNaturalHeight);
    self.expandedScrollView.contentSize = CGSizeMake(width, self.expandedNaturalHeight);
    self.expandedScrollView.alwaysBounceVertical =
        self.expandedNaturalHeight > visibleHeight + 0.5f;
    self.collapsedCell.alpha = self.expanded ? 0.0f : 1.0f;
    self.expandedScrollView.alpha = self.expanded ? 1.0f : 0.0f;
    self.backgroundColor = [UIColor colorWithWhite:0.0f
                                              alpha:0.58f];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (expanded && !self.canExpand) return;
    if (_expanded == expanded) return;

    _expanded = expanded;
    CGRect hostBounds = self.superview ? self.superview.bounds :
        CGRectMake(0.0f, 0.0f, self.frame.size.width, CGRectGetMaxY(self.frame));

    CGFloat maxExpandedHeight = MAX(DCImageMessageOverlayCollapsedHeight,
                                    hostBounds.size.height - 64.0f);
    CGFloat targetHeight = expanded
        ? MIN(self.expandedNaturalHeight, maxExpandedHeight)
        : DCImageMessageOverlayCollapsedHeight;
    CGRect targetFrame = CGRectMake(0.0f,
                                    hostBounds.size.height - targetHeight,
                                    hostBounds.size.width,
                                    targetHeight);

    NSTimeInterval duration = animated ? 0.24 : 0.0;
    void (^changes)(void) = ^{
        self.frame = targetFrame;
        self.expandedScrollView.frame = self.bounds;
        self.collapsedCell.alpha = expanded ? 0.0f : 1.0f;
        self.expandedScrollView.alpha = expanded ? 1.0f : 0.0f;
        self.backgroundColor = [UIColor colorWithWhite:0.0f
                                                  alpha:0.58f];
    };

    if (duration > 0.0) {
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseInOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)dc_didTapOverlay:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded || !self.canExpand) return;
    [self setExpanded:!self.expanded animated:YES];
}

@end
