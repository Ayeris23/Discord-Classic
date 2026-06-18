//
//  DCMessageLayoutBuilder.m
//  Discord Classic
//
//  Created by Ayeris on 6/15/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCMessageLayoutBuilder.h"
#import "DCServerCommunicator.h"
#import "DCUser.h"
#import "UILazyImage.h"
#import "DCChatVideoAttachment.h"
#import "DCGifInfo.h"
#import "DTCoreTextLayouter.h"
#import "DTCoreTextLayoutFrame.h"
#import "DCCacheManager.h"

@implementation DCMessageLayoutBuilder

#pragma mark - Grouping

// A message that can group UNDER its predecessor — must be a plain
// default message with no reference attachment.
+ (BOOL)isGroupableMessage:(DCMessage *)message {
    if (!message) return NO;
    if (message.messageType != DCMessageTypeDefault) return NO;
    if (message.referencedMessage != nil) return NO;
    return YES;
}

// A message that can ANCHOR a group — i.e. the next message is allowed
// to group under it. Replies qualify because Discord allows a plain
// message immediately after a reply to group under it visually.
+ (BOOL)isGroupableAnchor:(DCMessage *)message {
    if (!message) return NO;
    return (message.messageType == DCMessageTypeDefault ||
            message.messageType == DCMessageTypeReply);
}

+ (BOOL)shouldGroupMessage:(DCMessage *)message underPredecessor:(DCMessage *)predecessor {
    if (![self isGroupableMessage:message]) return NO;
    if (![self isGroupableAnchor:predecessor]) return NO;
    NSDate *messageTimestamp = message.timestamp;
    BOOL sameAuthor =
        [predecessor.author.snowflake isEqualToString:message.author.snowflake];
    BOOL closeInTime =
        ([message.timestamp timeIntervalSince1970] -
         [predecessor.timestamp timeIntervalSince1970]) < 420;
    BOOL sameDay =
        [[NSCalendar currentCalendar] rangeOfUnit:NSCalendarUnitDay
                                        startDate:&messageTimestamp
                                         interval:NULL
                                          forDate:predecessor.timestamp];
    return sameAuthor && closeInTime && sameDay;
}

#pragma mark - Message type classification

// Cell-identity routing: these message types render via the generic
// "Universal Typehandler Cell" (system messages — pins, name/icon
// changes, recipient add/remove, thread-created, etc.) rather than a
// normal or grouped message cell. Ported verbatim from the
// `specialMessageTypes` set in DCChatViewController.
+ (BOOL)isSystemMessageType:(NSInteger)messageType {
    static NSSet *systemTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        systemTypes = [NSSet setWithArray:@[ @1, @2, @3, @4, @5, @6, @7, @8, @18 ]];
    });
    return [systemTypes containsObject:@(messageType)];
}

// Author-name measurement: whether this message type shows/measures an
// author name at all. Ported verbatim from the `cond` expression in
// calculateHeightForMessage:.
//
// NOTE: this disagrees with +isSystemMessageType: for type 6 (CHANNEL
// PINNED MESSAGE) — that method says "system cell", this one says "show
// author name" for the same type. Ported as-is since I can't tell from
// the code alone whether that's intentional (a pin announcement showing
// who pinned it, inside the system cell) or a leftover inconsistency.
// Worth confirming before slice 3 (reuseIdentifier wiring) — if it's a
// bug, collapsing these into one predicate is a one-line fix here.
+ (BOOL)shouldShowAuthorNameForMessageType:(NSInteger)messageType {
    return (messageType == 6)
        || (messageType != 18 && (messageType < 1 || messageType > 8));
}

#pragma mark - Layout

- (DCMessageLayout *)layoutForMessage:(DCMessage *)message
                       previousMessage:(DCMessage *)previousMessage
                            nextMessage:(DCMessage *)nextMessage
                             tableWidth:(CGFloat)tableWidth {
    if (!message) return nil;

    BOOL grouped = [self.class shouldGroupMessage:message underPredecessor:previousMessage];
    BOOL followedByGrouped = [self.class shouldGroupMessage:nextMessage underPredecessor:message];
    BOOL hasReference = (message.messageType == DCMessageTypeReply);
    BOOL showsAuthorName = [self.class shouldShowAuthorNameForMessageType:message.messageType];

    CGFloat contentWidth = tableWidth - 63;
    CGFloat textHeight = [self textHeightForMessage:message contentWidth:contentWidth];

    DCMessageLayout *layout = [DCMessageLayout new];
    layout.messageSnowflake = message.snowflake;
    layout.tableWidth = tableWidth;
    layout.grouped = grouped;
    layout.followedByGrouped = followedByGrouped;
    layout.hasReference = hasReference;
    layout.showsAuthorName = showsAuthorName;
    layout.textHeight = textHeight;
    layout.reuseIdentifier = [self.class reuseIdentifierForMessage:message
                                                              grouped:grouped
                                                         hasReference:hasReference];
    layout.height = [self heightForMessage:message
                                     grouped:grouped
                           followedByGrouped:followedByGrouped
                             showsAuthorName:showsAuthorName
                                  textHeight:textHeight
                                  tableWidth:tableWidth];
    return layout;
}

+ (NSString *)reuseIdentifierForMessage:(DCMessage *)message
                                 grouped:(BOOL)grouped
                            hasReference:(BOOL)hasReference {
    if (grouped && ![self isSystemMessageType:message.messageType]) {
        return @"Grouped Message Cell";
    }
    if (hasReference) {
        return @"Reply Message Cell";
    }
    if ([self isSystemMessageType:message.messageType]) {
        return @"Universal Typehandler Cell";
    }
    return @"Message Cell";
}

#pragma mark - Height

// Ported from calculateHeightForMessage:tableWidth:followedByGrouped:.
// Two changes from the original:
//   - `message.isGrouped` -> `grouped` (the builder's own computation,
//     not message state)
//   - `cond` -> +shouldShowAuthorNameForMessageType:
- (CGFloat)heightForMessage:(DCMessage *)message
                    grouped:(BOOL)grouped
          followedByGrouped:(BOOL)followedByGrouped
            showsAuthorName:(BOOL)showsAuthorName
                 textHeight:(CGFloat)textHeight
                 tableWidth:(CGFloat)tableWidth {
    CGFloat contentWidth = tableWidth - 63;

    CGSize authorNameSize = CGSizeZero;
    if (!grouped && showsAuthorName) {
        authorNameSize = CGSizeMake(0, [UIFont boldSystemFontOfSize:15].lineHeight);
    }

    CGSize contentSize = CGSizeMake(contentWidth, textHeight);

    NSCharacterSet *invisibleChars = [NSCharacterSet characterSetWithCharactersInString:@"\u00A0\u200B\n\r\t "];
    BOOL hasVisibleContent = [[message.content stringByTrimmingCharactersInSet:invisibleChars] length] > 0
        || message.emojis.count > 0;

    CGFloat contentHeight;
    if (grouped) {
        contentHeight = MAX(contentSize.height, 18) + 4;
    } else {
        CGFloat padding = followedByGrouped ? 10 : 14;
        contentHeight = MAX(
            (showsAuthorName ? authorNameSize.height : 0)
                + (message.attachmentCount ? (hasVisibleContent ? contentSize.height : 0) : MAX(contentSize.height, 18))
                + padding
                + (message.referencedMessage != nil ? 16 : 0),
            (showsAuthorName ? authorNameSize.height : 0) + (hasVisibleContent ? [UIFont systemFontOfSize:14].lineHeight : 0) + padding
        );
    }

    int attachmentHeight = [self attachmentHeightForMessage:message tableWidth:tableWidth];

    return contentHeight + attachmentHeight + (attachmentHeight ? 11 : 0);
}

- (void)prewarmLayoutCacheForMessages:(NSArray *)messages {
    if (!messages.count) return;

    UIUserInterfaceIdiom idiom = [UIDevice currentDevice].userInterfaceIdiom;
    CGFloat screenWidth    = UIScreen.mainScreen.bounds.size.width;
    CGFloat screenHeight   = UIScreen.mainScreen.bounds.size.height;
    CGFloat portraitWidth  = MIN(screenWidth, screenHeight);
    CGFloat landscapeWidth = MAX(screenWidth, screenHeight);

    for (NSInteger i = 0; i < (NSInteger)messages.count; i++) {
        DCMessage *message = messages[i];
        if (!message.snowflake) continue;

        BOOL hasUnloaded = NO;
        for (id attachment in message.attachments) {
            if ([attachment isKindOfClass:[NSArray class]] ||
                ([attachment isKindOfClass:[DCGifInfo class]] &&
                 !((DCGifInfo *)attachment).staticThumbnail)) {
                hasUnloaded = YES;
                break;
            }
        }
        if (hasUnloaded) continue;

        DCMessage *prev = (i > 0) ? messages[i - 1] : nil;
        DCMessage *next = (i + 1 < (NSInteger)messages.count) ? messages[i + 1] : nil;

        [self prewarmForMessage:message
                           prev:prev
                           next:next
                          width:portraitWidth];

        if (idiom == UIUserInterfaceIdiomPad) {
            [self prewarmForMessage:message
                               prev:prev
                               next:next
                              width:landscapeWidth];
        }
    }
}

- (void)prewarmForMessage:(DCMessage *)message
                     prev:(DCMessage *)prev
                     next:(DCMessage *)next
                    width:(CGFloat)width {
    if ([[DCCacheManager sharedInstance] layoutForSnowflake:message.snowflake
                                                 tableWidth:width
                                          previousSnowflake:prev.snowflake
                                              nextSnowflake:next.snowflake
                                            editedTimestamp:message.editedTimestamp]) {
        return; // already cached
    }

    DCMessageLayout *layout = [self layoutForMessage:message
                                     previousMessage:prev
                                         nextMessage:next
                                          tableWidth:width];

    [[DCCacheManager sharedInstance] setLayout:layout
                                    forSnowflake:message.snowflake
                                      tableWidth:width
                               previousSnowflake:prev.snowflake
                                   nextSnowflake:next.snowflake
                                 editedTimestamp:message.editedTimestamp];
}

// Per-width text layout pass — this is the fix for (A), "iPad shows
// portrait heights in landscape". Previously calculateHeightForMessage:
// read message.textHeight, a single value computed once in DCTools.m at
// UIScreen.mainScreen.bounds width (fixed/portrait on iOS 5–7 regardless
// of current orientation). Now computed fresh for `contentWidth`, which
// varies with `tableWidth`, and gets cached per-width automatically via
// DCMessageLayout's composite cache key in the next slice.
//
// The original's "store as ceil(h)+2, then read back as >2 ? value-2 : 0"
// round trip is arithmetically a no-op: ceil(h)+2 > 2 <=> ceil(h) > 0,
// and (ceil(h)+2)-2 == ceil(h); since CGRectGetHeight is never negative,
// both branches collapse to just ceil(h). Flagging the simplification in
// case I've missed why the +2/-2 was there.
- (CGFloat)textHeightForMessage:(DCMessage *)message contentWidth:(CGFloat)contentWidth {
    if (!message.attributedContent) return 0;
    DTCoreTextLayouter *layouter = [[DTCoreTextLayouter alloc]
        initWithAttributedString:message.attributedContent];
    CGRect layoutRect = CGRectMake(0, 0, contentWidth, CGFLOAT_HEIGHT_UNKNOWN);
    DTCoreTextLayoutFrame *layoutFrame = [layouter layoutFrameWithRect:layoutRect
                                                                  range:NSMakeRange(0, 0)];
    return ceil(CGRectGetHeight(layoutFrame.frame));
}

// Ported verbatim from calculateHeightForMessage:, including its int
// truncation behavior on newWidth/newHeight — preserved deliberately so
// this port doesn't shift any cached height by a point as a side effect.
// CGFloat-vs-int cleanup, if wanted, is a separate follow-up.
- (int)attachmentHeightForMessage:(DCMessage *)message tableWidth:(CGFloat)tableWidth {
    int attachmentHeight = 0;
    for (id attachment in message.attachments) {
        if ([attachment isKindOfClass:[UILazyImage class]]) {
            UILazyImage *lazyImg = attachment;
            CGSize sourceSize = CGSizeZero;
            if (lazyImg.naturalSize.width > 0 && lazyImg.naturalSize.height > 0) {
                sourceSize = lazyImg.naturalSize;
            } else if (lazyImg.image) {
                sourceSize = lazyImg.image.size;
            } else {
                continue;
            }
            CGFloat aspectRatio = sourceSize.width / sourceSize.height;
            int newWidth  = message.isSticker ? 160 : (int)(200 * aspectRatio);
            int newHeight = message.isSticker ? 160 : 200;
            if (newWidth > tableWidth - 66) {
                newWidth  = tableWidth - 66;
                newHeight = newWidth / aspectRatio;
            }
            attachmentHeight += newHeight;
        } else if ([attachment isKindOfClass:[DCChatVideoAttachment class]]) {
            DCChatVideoAttachment *video = attachment;
            CGFloat aspectRatio = (video.thumbnail.image && video.thumbnail.image.size.height > 0)
                ? video.thumbnail.image.size.width / video.thumbnail.image.size.height
                : 16.0f / 9.0f;
            int newWidth  = 200 * aspectRatio;
            int newHeight = 200;
            if (newWidth > tableWidth - 66) {
                newWidth  = tableWidth - 66;
                newHeight = newWidth / aspectRatio;
            }
            attachmentHeight += newHeight;
        } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
            DCGifInfo *gifInfo = attachment;
            if (!gifInfo.staticThumbnail) continue;
            CGFloat aspectRatio = gifInfo.staticThumbnail.size.width / gifInfo.staticThumbnail.size.height;
            int newWidth  = (int)(200 * aspectRatio);
            int newHeight = 200;
            if (newWidth > tableWidth - 66) {
                newWidth  = tableWidth - 66;
                newHeight = newWidth / aspectRatio;
            }
            attachmentHeight += newHeight;
        } else if ([attachment isKindOfClass:[NSArray class]]) {
            NSArray *dimensions = attachment;
            if (dimensions.count == 2) {
                int width  = [dimensions[0] intValue];
                int height = [dimensions[1] intValue];
                if (width <= 0 || height <= 0) continue;
                CGFloat aspectRatio = (CGFloat)width / height;
                int newWidth  = 200 * aspectRatio;
                int newHeight = 200;
                if (newWidth > tableWidth - 66) {
                    newWidth  = tableWidth - 66;
                    newHeight = newWidth / aspectRatio;
                }
                attachmentHeight += newHeight;
            }
        }
    }
    return attachmentHeight;
}

@end