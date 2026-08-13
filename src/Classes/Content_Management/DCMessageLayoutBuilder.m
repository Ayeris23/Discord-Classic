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
#import "DTCoreTextConstants.h"
#import <CoreText/CoreText.h>

/*
 * Diagnostics for rare DTCoreText pathologies. This deliberately logs only
 * structural characteristics, never the message text itself.
 */
static void DCLogAttributedStringShape(DCMessage *message,
                                       CGFloat contentWidth,
                                       NSTimeInterval elapsed,
                                       NSString *reason) {
    NSAttributedString *attributed = message.attributedContent;
    NSString *plain = attributed ? [attributed string] : @"";

    __block NSUInteger attributeRuns = 0;
    __block NSUInteger attachmentRuns = 0;
    __block NSUInteger linkRuns = 0;
    __block NSUInteger fontRuns = 0;
    __block NSUInteger paragraphRuns = 0;
    __block NSUInteger headerRuns = 0;
    __block NSUInteger shadowRuns = 0;

    if (attributed.length > 0) {
        [attributed enumerateAttributesInRange:NSMakeRange(0, attributed.length)
                                       options:0
                                    usingBlock:^(NSDictionary *attrs,
                                                 NSRange range,
                                                 BOOL *stop) {
            attributeRuns++;

            if ([attrs objectForKey:NSAttachmentAttributeName]) {
                attachmentRuns++;
            }
            if ([attrs objectForKey:DTLinkAttribute]) {
                linkRuns++;
            }
            if ([attrs objectForKey:(NSString *)kCTFontAttributeName]) {
                fontRuns++;
            }
            if ([attrs objectForKey:(NSString *)kCTParagraphStyleAttributeName]) {
                paragraphRuns++;
            }
            if ([attrs objectForKey:DTHeaderLevelAttribute]) {
                headerRuns++;
            }
            if ([attrs objectForKey:DTShadowsAttribute]) {
                shadowRuns++;
            }
        }];
    }

    NSUInteger newlineCount = 0;
    NSUInteger nonASCII = 0;
    NSUInteger surrogateUnits = 0;
    NSUInteger combiningUnits = 0;
    NSUInteger zwjCount = 0;
    NSUInteger variation16Count = 0;
    NSUInteger bidiControlCount = 0;
    NSUInteger zeroWidthCount = 0;
    NSUInteger currentTokenLength = 0;
    NSUInteger longestTokenLength = 0;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSCharacterSet *nonBase = [NSCharacterSet nonBaseCharacterSet];

    for (NSUInteger i = 0; i < plain.length; i++) {
        unichar c = [plain characterAtIndex:i];

        if (c == '\n' || c == '\r') newlineCount++;
        if (c > 0x7F) nonASCII++;
        if (c >= 0xD800 && c <= 0xDFFF) surrogateUnits++;
        if ([nonBase characterIsMember:c]) combiningUnits++;
        if (c == 0x200D) zwjCount++;
        if (c == 0xFE0F) variation16Count++;

        if ((c >= 0x202A && c <= 0x202E) ||
            (c >= 0x2066 && c <= 0x2069)) {
            bidiControlCount++;
        }

        if (c == 0x200B || c == 0x200C || c == 0x200D ||
            c == 0x2060 || c == 0xFEFF) {
            zeroWidthCount++;
        }

        if ([whitespace characterIsMember:c]) {
            if (currentTokenLength > longestTokenLength) {
                longestTokenLength = currentTokenLength;
            }
            currentTokenLength = 0;
        } else {
            currentTokenLength++;
        }
    }

    if (currentTokenLength > longestTokenLength) {
        longestTokenLength = currentTokenLength;
    }

    NSLog(@"[LayoutDiag] %@ %@ %.1fms width %.0f "
          @"type %ld raw %lu content %lu attr %lu "
          @"runs %lu attachRuns %lu links %lu fonts %lu para %lu headers %lu shadows %lu "
          @"nl %lu nonASCII %lu surrogate %lu combining %lu zwj %lu vs16 %lu "
          @"bidi %lu zeroWidth %lu longestToken %lu "
          @"modelAtts %ld/%lu emojis %lu refState %ld",
          reason ?: @"shape",
          message.snowflake ?: @"?",
          elapsed * 1000.0,
          contentWidth,
          (long)message.messageType,
          (unsigned long)message.rawContent.length,
          (unsigned long)message.content.length,
          (unsigned long)attributed.length,
          (unsigned long)attributeRuns,
          (unsigned long)attachmentRuns,
          (unsigned long)linkRuns,
          (unsigned long)fontRuns,
          (unsigned long)paragraphRuns,
          (unsigned long)headerRuns,
          (unsigned long)shadowRuns,
          (unsigned long)newlineCount,
          (unsigned long)nonASCII,
          (unsigned long)surrogateUnits,
          (unsigned long)combiningUnits,
          (unsigned long)zwjCount,
          (unsigned long)variation16Count,
          (unsigned long)bidiControlCount,
          (unsigned long)zeroWidthCount,
          (unsigned long)longestTokenLength,
          (long)message.attachmentCount,
          (unsigned long)message.attachments.count,
          (unsigned long)message.emojis.count,
          (long)message.referencedMessageState);
}

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

// Type 6 retains the existing behavior of showing an author name in its system cell.
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

    /*
     * The text glyph/frame layout depends on the final attributed string and
     * content width, but NOT on message neighbors.  Grouping does depend on
     * neighbors, which is why DCMessageLayout itself keeps the composite key.
     * Keep the expensive DTCoreText frame in a second, neighbor-independent
     * cache so sliding the 80-message window does not reshape the same text.
     */
    DCCacheManager *cacheManager = [DCCacheManager sharedInstance];
    DTCoreTextLayoutFrame *textLayoutFrame =
        [cacheManager textLayoutFrameForSnowflake:message.snowflake
                                     contentWidth:contentWidth
                                  editedTimestamp:message.editedTimestamp];

    if (!textLayoutFrame && message.attributedContent) {
        CFAbsoluteTime textFrameStart = CFAbsoluteTimeGetCurrent();
        textLayoutFrame =
            [self textLayoutFrameForMessage:message contentWidth:contentWidth];
        NSTimeInterval textFrameTime = CFAbsoluteTimeGetCurrent() - textFrameStart;
        if (textLayoutFrame) {
            [cacheManager setTextLayoutFrame:textLayoutFrame
                                  forSnowflake:message.snowflake
                                   contentWidth:contentWidth
                                editedTimestamp:message.editedTimestamp];
        }
        if (textFrameTime >= 0.008) {
            NSLog(@"[ChatPerf] text frame BUILD %@ %.1fms at %.0fpt",
                  message.snowflake ?: @"?",
                  textFrameTime * 1000.0,
                  contentWidth);
        }
        if (textFrameTime >= 0.020) {
            DCLogAttributedStringShape(message,
                                       contentWidth,
                                       textFrameTime,
                                       @"SLOW TEXT FRAME");
        }
    }

    CGFloat textHeight = textLayoutFrame ? ceil(CGRectGetHeight(textLayoutFrame.frame)) : 0;

    if (message.attributedContent.length > 0 && textHeight <= 0.0f) {
        DCLogAttributedStringShape(message,
                                   contentWidth,
                                   0,
                                   @"ZERO TEXT HEIGHT");
    }

    if (message.attributedContent.length == 0 &&
        (message.content.length > 0 || message.rawContent.length > 0) &&
        (message.messageType == DCMessageTypeDefault ||
         message.messageType == DCMessageTypeReply)) {
        NSLog(@"[LayoutDiag] MISSING/EMPTY ATTRIBUTED CONTENT %@ "
              @"type %ld raw %lu content %lu attrObject %@ atts %ld/%lu",
              message.snowflake ?: @"?",
              (long)message.messageType,
              (unsigned long)message.rawContent.length,
              (unsigned long)message.content.length,
              message.attributedContent ? @"present" : @"nil",
              (long)message.attachmentCount,
              (unsigned long)message.attachments.count);
    }

    DCMessageLayout *layout = [DCMessageLayout new];
    layout.messageSnowflake = message.snowflake;
    layout.tableWidth = tableWidth;
    layout.grouped = grouped;
    layout.followedByGrouped = followedByGrouped;
    layout.hasReference = hasReference;
    layout.showsAuthorName = showsAuthorName;
    layout.textHeight = textHeight;
    layout.textLayoutFrame = textLayoutFrame;
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
    BOOL hasReference = message.messageType == DCMessageTypeReply;
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
                + (hasReference ? 16 : 0),
            (showsAuthorName ? authorNameSize.height : 0) + (hasVisibleContent ? [UIFont systemFontOfSize:14].lineHeight : 0) + padding
        );
    }

    int attachmentHeight = [self attachmentHeightForMessage:message tableWidth:tableWidth];

    return contentHeight + attachmentHeight + (attachmentHeight ? 11 : 0);
}

- (void)prewarmLayoutCacheForMessage:(DCMessage *)message
                        previousMessage:(DCMessage *)previousMessage
                            nextMessage:(DCMessage *)nextMessage
                             tableWidth:(CGFloat)tableWidth {
    if (!message || !message.snowflake.length || tableWidth <= 0.0f) return;

    // Attachment metadata supplies row geometry; defer only when dimensions are unknown.
    BOOL hasUnknownGeometry = NO;
    for (id attachment in message.attachments) {
        if ([attachment isKindOfClass:[NSArray class]]) {
            NSArray *dimensions = attachment;
            if (dimensions.count != 2 ||
                [dimensions[0] floatValue] <= 0 ||
                [dimensions[1] floatValue] <= 0) {
                hasUnknownGeometry = YES;
                break;
            }
        } else if ([attachment isKindOfClass:[UILazyImage class]]) {
            UILazyImage *image = attachment;
            if ((image.naturalSize.width <= 0 || image.naturalSize.height <= 0) &&
                (!image.image || image.image.size.width <= 0 || image.image.size.height <= 0)) {
                hasUnknownGeometry = YES;
                break;
            }
        } else if ([attachment isKindOfClass:[DCChatVideoAttachment class]]) {
            DCChatVideoAttachment *video = attachment;
            if ((video.naturalSize.width <= 0 || video.naturalSize.height <= 0) &&
                (!video.thumbnailImage ||
                 video.thumbnailImage.size.width <= 0 ||
                 video.thumbnailImage.size.height <= 0)) {
                hasUnknownGeometry = YES;
                break;
            }
        } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
            DCGifInfo *gif = attachment;
            if ((gif.naturalSize.width <= 0 || gif.naturalSize.height <= 0) &&
                (!gif.staticThumbnail ||
                 gif.staticThumbnail.size.width <= 0 ||
                 gif.staticThumbnail.size.height <= 0)) {
                hasUnknownGeometry = YES;
                break;
            }
        }
    }
    if (hasUnknownGeometry) return;

    [self prewarmForMessage:message
                       prev:previousMessage
                       next:nextMessage
                      width:tableWidth];
}

- (void)prewarmLayoutCacheForMessages:(NSArray *)messages
                      previousMessage:(DCMessage *)previousBoundary
                          nextMessage:(DCMessage *)nextBoundary
                           tableWidth:(CGFloat)tableWidth {
    if (!messages.count || tableWidth <= 0.0f) return;

    for (NSInteger i = 0; i < (NSInteger)messages.count; i++) {
        DCMessage *message = messages[i];
        if (!message.snowflake.length) continue;

        DCMessage *prev = (i > 0) ? messages[i - 1] : previousBoundary;
        DCMessage *next = (i + 1 < (NSInteger)messages.count) ? messages[i + 1] : nextBoundary;

        [self prewarmLayoutCacheForMessage:message
                           previousMessage:prev
                               nextMessage:next
                                tableWidth:tableWidth];
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
        return;
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

- (void)prewarmLayoutCacheForMessages:(NSArray *)messages {
    if (!messages.count) return;

    UIUserInterfaceIdiom idiom = [UIDevice currentDevice].userInterfaceIdiom;
    CGFloat screenWidth    = UIScreen.mainScreen.bounds.size.width;
    CGFloat screenHeight   = UIScreen.mainScreen.bounds.size.height;
    CGFloat portraitWidth  = MIN(screenWidth, screenHeight);
    CGFloat landscapeWidth = MAX(screenWidth, screenHeight);

    [self prewarmLayoutCacheForMessages:messages
                        previousMessage:nil
                            nextMessage:nil
                             tableWidth:portraitWidth];

    if (idiom == UIUserInterfaceIdiomPad) {
        [self prewarmLayoutCacheForMessages:messages
                            previousMessage:nil
                                nextMessage:nil
                                 tableWidth:landscapeWidth];
    }
}

// Build and cache text layout at the exact table width.
- (DTCoreTextLayoutFrame *)textLayoutFrameForMessage:(DCMessage *)message
                                               contentWidth:(CGFloat)contentWidth {
    if (!message.attributedContent || contentWidth <= 0.0f) return nil;

    // This is the same authoritative DTCoreText layout operation that
    // previously produced only a CGFloat height.  Keep the resulting frame
    // so the DTAttributedLabel can draw/rebuild link/emoji custom views from
    // the exact prewarmed glyph layout instead of laying the string out again
    // on the main thread when the cell is configured.
    DTCoreTextLayouter *layouter = [[DTCoreTextLayouter alloc]
        initWithAttributedString:message.attributedContent];
    CGRect layoutRect = CGRectMake(0, 0, contentWidth, CGFLOAT_HEIGHT_UNKNOWN);
    return [layouter layoutFrameWithRect:layoutRect range:NSMakeRange(0, 0)];
}

// Preserve calculateHeightForMessage:'s integer truncation so cached heights remain stable.
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
            CGSize sourceSize = CGSizeZero;
            if (video.naturalSize.width > 0 && video.naturalSize.height > 0) {
                sourceSize = video.naturalSize;
            } else if (video.thumbnailImage) {
                sourceSize = video.thumbnailImage.size;
            } else {
                sourceSize = CGSizeMake(16, 9);
            }
            CGFloat aspectRatio = sourceSize.width / sourceSize.height;
            int newWidth  = 200 * aspectRatio;
            int newHeight = 200;
            if (newWidth > tableWidth - 66) {
                newWidth  = tableWidth - 66;
                newHeight = newWidth / aspectRatio;
            }
            attachmentHeight += newHeight;
        } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
            DCGifInfo *gifInfo = attachment;
            CGSize sourceSize = CGSizeZero;
            if (gifInfo.naturalSize.width > 0 && gifInfo.naturalSize.height > 0) {
                sourceSize = gifInfo.naturalSize;
            } else if (gifInfo.staticThumbnail) {
                sourceSize = gifInfo.staticThumbnail.size;
            } else {
                continue;
            }
            CGFloat aspectRatio = sourceSize.width / sourceSize.height;
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