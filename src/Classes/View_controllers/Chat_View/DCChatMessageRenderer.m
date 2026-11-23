//
//  DCChatMessageRenderer.m
//  Discord Classic
//
//  Created by Ayeris on 11/22/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCChatMessageRenderer.h"
#import "DCChatTableCell.h"
#import "DCChatVideoAttachment.h"
#import "DCChatGifAttachment.h"
#import "DCChatSpoilerView.h"
#import "DCGifInfo.h"
#import "DCMessage.h"
#import "DCMessageLayoutBuilder.h"
#import "DCUser.h"
#import "DCChannel.h"
#import "DCGuild.h"
#import "DCInterfaceStyle.h"
#import "DCMarkdownParser.h"
#import "DCTools.h"
#import "TRMalleableFrameView.h"
#import "UILazyImage.h"
#import "UILazyImageView.h"
#import "DTLinkButton.h"
#import "QuickLook/QuickLook.h"
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>

@implementation DCChatReferencePresentation
@end

static const CGFloat DCForwardedContentInset = 10.0f;
static const CGFloat DCForwardedHeaderHeight = 16.0f;
static const CGFloat DCForwardedVerticalInset = 18.0f;
static const CGFloat DCChatBodyOriginX = 55.0f;
static const NSInteger DCForwardedLineTag = 9472;
static const NSInteger DCForwardedHeaderTag = 9473;
static const NSInteger DCMessageJumpHighlightTag = 9478;

static UIFont *DCForwardedHeaderFont(void) {
    UIFont *font = [UIFont fontWithName:@"HelveticaNeue-BoldItalic" size:12.0f];
    return font ?: [UIFont boldSystemFontOfSize:12.0f];
}

static void DCConfigureForwardedCellChrome(DCChatTableCell *cell,
                                           DCMessage *message,
                                           DCMessageLayout *layout,
                                           CGFloat tableWidth,
                                           UIColor *headerColor) {
    UIView *line = [cell.contentView viewWithTag:DCForwardedLineTag];
    UILabel *forwardedHeader = (UILabel *)[cell.contentView viewWithTag:DCForwardedHeaderTag];

    cell.profileImage.hidden = NO;
    cell.avatarDecoration.hidden = NO;
    cell.timestampLabel.hidden = NO;
    cell.authorLabel.hidden = NO;
    cell.authorLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    CGRect authorFrame = cell.authorLabel.frame;
    authorFrame.origin.x = DCChatBodyOriginX;
    cell.authorLabel.frame = authorFrame;

    if (!message.isForwarded) {
        if (line) line.hidden = YES;
        if (forwardedHeader) forwardedHeader.hidden = YES;
        return;
    }

    if (!line) {
        line = [[UIView alloc] initWithFrame:CGRectZero];
        line.tag = DCForwardedLineTag;
        line.userInteractionEnabled = NO;
        [cell.contentView addSubview:line];
    }
    line.hidden = NO;
    line.backgroundColor = headerColor;

    if (!forwardedHeader) {
        forwardedHeader = [[UILabel alloc] initWithFrame:CGRectZero];
        forwardedHeader.tag = DCForwardedHeaderTag;
        forwardedHeader.backgroundColor = [UIColor clearColor];
        forwardedHeader.userInteractionEnabled = NO;
        forwardedHeader.font = DCForwardedHeaderFont();
        forwardedHeader.text = @"↪ Forwarded";
        [cell.contentView addSubview:forwardedHeader];
    }
    forwardedHeader.hidden = NO;
    forwardedHeader.textColor = headerColor;
    forwardedHeader.font = DCForwardedHeaderFont();
    forwardedHeader.text = @"↪ Forwarded";
    forwardedHeader.frame = CGRectMake(DCChatBodyOriginX + DCForwardedContentInset,
                                       28.0f,
                                       MAX(0.0f, tableWidth - DCChatBodyOriginX
                                           - DCForwardedContentInset - 8.0f),
                                       DCForwardedHeaderHeight);

    CGFloat lineY = 28.0f;
    CGFloat lineHeight = MAX(2.0f, layout.height - lineY - 7.0f);
    line.frame = CGRectMake(DCChatBodyOriginX, lineY, 3.0f, lineHeight);
}

@implementation DCChatMessageRenderer

- (DCChatTableCell *)cellForMessage:(DCMessage *)messageAtRowIndex
                             layout:(DCMessageLayout *)layout
                          tableView:(UITableView *)tableView
                                row:(NSInteger)row
                            context:(id<DCChatMessageRenderingContext>)context {
    if (!messageAtRowIndex || !layout || !context) return nil;
    DCGuild *renderingGuild = [context messageRenderingChannel].parentGuild;
    DCChatTableCell *cell = nil;
    @autoreleasepool {
            CFAbsoluteTime cellPerfStart = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime cellPerfContentStart = 0;
            CFAbsoluteTime cellPerfContentEnd = 0;
            CFAbsoluteTime cellPerfAttachmentsStart = 0;
            CFAbsoluteTime cellPerfAttachmentsEnd = 0;
            CFAbsoluteTime cellPerfDequeueStart = 0;
            CFAbsoluteTime cellPerfDequeueEnd = 0;
            CFAbsoluteTime cellPerfAvatarStart = 0;
            CFAbsoluteTime cellPerfAvatarEnd = 0;
            CFAbsoluteTime cellPerfCleanupStart = 0;
            CFAbsoluteTime cellPerfCleanupEnd = 0;
            CFAbsoluteTime cellPerfReferenceParseStart = 0;
            CFAbsoluteTime cellPerfReferenceParseEnd = 0;
            NSTimeInterval cellPerfReferenceBindTime = 0;
            CFAbsoluteTime cellPerfHeaderStart = 0;
            CFAbsoluteTime cellPerfHeaderEnd = 0;
            CFAbsoluteTime cellPerfPostContentStart = 0;
            CFAbsoluteTime cellPerfPostContentEnd = 0;
            static UIColor *replyHighlightColor = nil;
            static UIColor *pingColor = nil;
            static UIColor *normalColor = nil;
            static UIColor *referenceColor = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                replyHighlightColor = [UIColor colorWithRed:55/255.0f green:59/255.0f blue:64/255.0f alpha:1.0f];
                pingColor           = [UIColor colorWithRed:46/255.0f green:45/255.0f blue:40/255.0f alpha:1.0f];
                normalColor         = [UIColor colorWithRed:40/255.0f green:41/255.0f blue:46/255.0f alpha:1.0f];
                referenceColor      = [UIColor colorWithRed:128/255.0f green:128/255.0f blue:128/255.0f alpha:1.0f];
            });

            cellPerfDequeueStart = CFAbsoluteTimeGetCurrent();
            cell = (DCChatTableCell *)[tableView dequeueReusableCellWithIdentifier:layout.reuseIdentifier];
            cellPerfDequeueEnd = CFAbsoluteTimeGetCurrent();

            UIView *oldJumpHighlight = [cell viewWithTag:DCMessageJumpHighlightTag];
            [oldJumpHighlight removeFromSuperview];

            cell.transform =
                CGAffineTransformMakeScale(1.0f, -1.0f);

            BOOL sameMessage =
                cell.messageSnowflake.length &&
                [cell.messageSnowflake
                    isEqualToString:messageAtRowIndex.snowflake];

            BOOL sameLayout =
                cell.configuredLayout == layout;

            BOOL isReplyTarget =
                context.replyingToMessage &&
                [context.replyingToMessage.snowflake isEqualToString:messageAtRowIndex.snowflake];

            BOOL isEditTarget =
                context.editingMessage &&
                [context.editingMessage.snowflake isEqualToString:messageAtRowIndex.snowflake];

            // Make the cells append avatars themselves
            cellPerfAvatarStart = CFAbsoluteTimeGetCurrent();
            [context ensureAvatarForUser:messageAtRowIndex.author];

            DCMessage *reference = messageAtRowIndex.referencedMessage;

            BOOL referenceResolved = reference && reference.author &&
                (messageAtRowIndex.referencedMessageState ==
                    DCMessageReferenceStateResolved ||
                 messageAtRowIndex.referencedMessageState ==
                    DCMessageReferenceStateNone);

            if (reference.author) {
                [context ensureAvatarForUser:reference.author];
            }
            cellPerfAvatarEnd = CFAbsoluteTimeGetCurrent();

            DCConfigureForwardedCellChrome(cell,
                                           messageAtRowIndex,
                                           layout,
                                           tableView.width,
                                           cell.timestampLabel.textColor ?: referenceColor);

            [context configureForwardSourceTagForCell:cell
                                              message:messageAtRowIndex
                                               layout:layout
                                           tableWidth:tableView.width
                                                color:cell.timestampLabel.textColor ?: referenceColor];

            /*
             * Fast path:
             * If this reusable cell is already configured for this exact message and
             * layout, refresh lightweight volatile fields only and skip the expensive
             * markdown/layout/image attachment rebuild.
             */
            if (sameMessage && sameLayout && !isReplyTarget && !isEditTarget) {
                cell.profileImage.image = [context avatarImageForUser:messageAtRowIndex.author];

                DCGuild *guild =
                    renderingGuild;

                if (!layout.grouped) {
                    cell.authorLabel.text =
                        [messageAtRowIndex.author displayNameInGuild:guild];
                    cell.authorLabel.textColor =
                        [DCInterfaceStyle roleColorForUser:messageAtRowIndex.author inGuild:guild];
                }

                if (messageAtRowIndex.referencedMessage) {
                    cell.referencedProfileImage.image =
                        [context avatarImageForUser:messageAtRowIndex.referencedMessage.author];

                    if (layout.hasReference) {
                        cell.referencedAuthorLabel.text =
                            [messageAtRowIndex.referencedMessage.author
                                displayNameInGuild:guild];
                        cell.referencedAuthorLabel.textColor =
                            [DCInterfaceStyle roleColorForUser:messageAtRowIndex.referencedMessage.author
                                                      inGuild:guild];
                    }
                } else {
                    cell.referencedProfileImage.image = nil;
                    cell.referencedAuthorLabel.text = nil;
                }

                /*
                 * A cell may have been fully rebuilt while it was the active
                 * reply/edit target.  Once that state clears, the same-message
                 * fast path must also restore its steady-state background or it
                 * can retain the old highlight indefinitely.
                 */
                cell.contentView.backgroundColor =
                    messageAtRowIndex.pingingUser ? pingColor : normalColor;

                // Preserve the visible media view's hydrated thumbnail.
                if (context.readOnlyMessageListMode) {
                    [context configureMessageListActionForCell:cell layoutHeight:layout.height];
                }
                return cell;
            }
            cell.configuredLayout = nil;
            cellPerfCleanupStart = CFAbsoluteTimeGetCurrent();
            // cleanup loop
            for (UIView *subView in [NSArray arrayWithArray:cell.subviews]) {
                @autoreleasepool {
                    if ([subView isKindOfClass:[DCChatGifAttachment class]]) {
                        [(DCChatGifAttachment *)subView releaseThumbnailForResidency];
                        [subView removeFromSuperview];
                    } else if ([subView isKindOfClass:[UILazyImageView class]]) {
                        [(UILazyImageView *)subView releaseChatThumbnailForResidency];
                        [subView removeFromSuperview];
                    } else if ([subView isKindOfClass:[DCChatVideoAttachment class]]) {
                        [(DCChatVideoAttachment *)subView releaseThumbnailForResidency];
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[QLPreviewController class]]) {
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[UIButton class]] && 
                        ![subView isKindOfClass:[DTLinkButton class]]) {
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[UIActivityIndicatorView class]]) {
                        [subView removeFromSuperview];
                    }
                }
            }

            [cell.contentTextView removeAllCustomViewsForLinks];
            [cell.referencedMessage removeAllCustomViewsForLinks];
            cellPerfCleanupEnd = CFAbsoluteTimeGetCurrent();

            if (layout.hasReference) {
                NSString *referenceText =
                    [context referencePreviewTextForMessage:messageAtRowIndex] ?:
                    @"Unable to load message";
                NSString *referenceAuthorName = @"";
                CGFloat referenceAuthorWidth = 80.0f;

                if (referenceResolved) {
                    referenceAuthorName = [reference.author displayNameInGuild:renderingGuild] ?: @"";

                    CGSize nameSize = [referenceAuthorName sizeWithFont: [UIFont boldSystemFontOfSize:10.0f]];

                    referenceAuthorWidth = 80.0f + nameSize.width;

                    CGFloat maximumAuthorWidth = MAX(80.0f, tableView.width - 80.0f);

                    referenceAuthorWidth = MIN(referenceAuthorWidth, maximumAuthorWidth);
                }

                CFAbsoluteTime referenceBindStart = CFAbsoluteTimeGetCurrent();
                cell.referencedAuthorLabel.text = referenceAuthorName;
                cell.referencedAuthorLabel.textColor = referenceResolved
                    ? [DCInterfaceStyle roleColorForUser:reference.author
                                                 inGuild:renderingGuild]
                    : [UIColor whiteColor];
                cell.referencedProfileImage.image = referenceResolved ? [context avatarImageForUser:reference.author] : nil;

                CGFloat referenceWidth = MAX(0.0f, tableView.width - referenceAuthorWidth);

                // Clear stale reply layout and set final geometry before binding new text.
                cell.referencedMessage.layoutFrame = nil;
                cell.referencedMessage.attributedString = nil;
                cell.referencedMessage.frame =
                    CGRectMake(referenceAuthorWidth,
                               cell.referencedMessage.y,
                               referenceWidth,
                               cell.referencedMessage.height);
                cellPerfReferenceBindTime +=
                    (CFAbsoluteTimeGetCurrent() - referenceBindStart);

                cellPerfReferenceParseStart = CFAbsoluteTimeGetCurrent();
                NSAttributedString *referencedContent = nil;
                DCChatReferencePresentation *cachedReference =
                    [context.referencePresentationCache objectForKey:messageAtRowIndex.snowflake];
                if (cachedReference &&
                    [cachedReference.sourceText isEqualToString:referenceText]) {
                    referencedContent = cachedReference.attributedText;
                }

                if (!referencedContent) {
                    referencedContent =
                        [[DCMarkdownParser sharedParser]
                            attributedStringFromMarkdown:referenceText
                                             maxFontSize:10.0f
                                                   color:referenceColor
                                                 inGuild:renderingGuild];
                    if (referencedContent && messageAtRowIndex.snowflake.length) {
                        DCChatReferencePresentation *presentation =
                            [[DCChatReferencePresentation alloc] init];
                        presentation.sourceText = referenceText;
                        presentation.attributedText = referencedContent;
                        [context.referencePresentationCache setObject:presentation
                                                            forKey:messageAtRowIndex.snowflake];
                    }
                }
                cellPerfReferenceParseEnd = CFAbsoluteTimeGetCurrent();

                CFAbsoluteTime referenceStringBindStart = CFAbsoluteTimeGetCurrent();
                cell.referencedMessage.attributedString = referencedContent;
                cellPerfReferenceBindTime +=
                    (CFAbsoluteTimeGetCurrent() - referenceStringBindStart);

                /*
                 * Deleted and unavailable references should not behave like
                 * navigable messages.
                 */
                if (referenceResolved && reference.snowflake.length) {

                    UIButton *referencedMessageButton = [UIButton buttonWithType: UIButtonTypeCustom];

                    referencedMessageButton.frame =
                        CGRectMake(
                            cell.referencedProfileImage.x,
                            cell.referencedMessage.y,
                            cell.referencedMessage.x +
                                cell.referencedMessage.width -
                                cell.referencedProfileImage.x,
                            cell.referencedMessage.height);

                    referencedMessageButton.exclusiveTouch = YES;

                    [referencedMessageButton addTarget:context action: @selector(tappedReferencedMessage:) forControlEvents: UIControlEventTouchUpInside];

                    [cell addSubview: referencedMessageButton];
                }
            }

            cellPerfHeaderStart = CFAbsoluteTimeGetCurrent();
            if (!layout.grouped) {
                NSString *displayName = [messageAtRowIndex.author 
                    displayNameInGuild:renderingGuild];
                
                // Calculate natural sizes
                CGSize timestampSize = [messageAtRowIndex.prettyTimestamp 
                    sizeWithFont:cell.timestampLabel.font];
                CGSize nameSize = [displayName sizeWithFont:cell.authorLabel.font];
                
                CGFloat authorOriginX = cell.authorLabel.x;
                CGFloat gap = 8.0; // gap between name and timestamp
                CGFloat rightPadding = 8.0;
                CGFloat maxRightEdge = tableView.width - rightPadding;
                
                // Natural timestamp position — right after the name
                CGFloat naturalTimestampX = authorOriginX + nameSize.width + gap;
                
                // Maximum allowed timestamp X so it doesn't go off screen
                CGFloat maxTimestampX = maxRightEdge - timestampSize.width;
                
                // Timestamp sits at natural position unless that would push it too far
                CGFloat actualTimestampX = MIN(naturalTimestampX, maxTimestampX);
                
                // Author label is capped to whatever space is left before the timestamp
                CGFloat actualNameWidth = MAX(0, actualTimestampX - authorOriginX - gap);
                
                cell.authorLabel.text = displayName;
                cell.authorLabel.textColor =
                    [DCInterfaceStyle roleColorForUser:messageAtRowIndex.author
                                              inGuild:renderingGuild];
                cell.authorLabel.frame = CGRectMake(authorOriginX,
                                                    cell.authorLabel.y,
                                                    actualNameWidth,
                                                    cell.authorLabel.height);
                
                cell.timestampLabel.text = messageAtRowIndex.prettyTimestamp;
                cell.timestampLabel.frame = CGRectMake(actualTimestampX,
                                                       cell.timestampLabel.y,
                                                       timestampSize.width,
                                                       cell.timestampLabel.height);
            }

            cell.universalImageView.image = nil;
            if (messageAtRowIndex.messageType == DCMessageTypeRecipientAdd || messageAtRowIndex.messageType == DCMessageTypeUserJoin) {
                cell.universalImageView.image = [DCInterfaceStyle universalAddImage];
            } else if (messageAtRowIndex.messageType == DCMessageTypeRecipientRemove) {
                cell.universalImageView.image = [DCInterfaceStyle universalRemoveImage];
            } else if (messageAtRowIndex.messageType == DCMessageTypeChannelNameChange || messageAtRowIndex.messageType == DCMessageTypeChannelIconChange) {
                cell.universalImageView.image = [DCInterfaceStyle universalEditImage];
            } else if (messageAtRowIndex.messageType == DCMessageTypeChannelPinnedMessage) {
                cell.universalImageView.image = [DCInterfaceStyle universalPinImage];
            } else if (messageAtRowIndex.messageType == DCMessageTypeGuildBoost || messageAtRowIndex.messageType == DCMessageTypeThreadCreated) {
                cell.universalImageView.image = [DCInterfaceStyle universalBoostImage];
            }
            cellPerfHeaderEnd = CFAbsoluteTimeGetCurrent();

            CGFloat forwardedInset = messageAtRowIndex.isForwarded
                ? DCForwardedContentInset : 0.0f;
            CGFloat forwardedVerticalInset = messageAtRowIndex.isForwarded
                ? DCForwardedVerticalInset : 0.0f;
            BOOL isSystemCell = [layout.reuseIdentifier isEqualToString:@"Universal Typehandler Cell"];
            CGFloat baseContentOriginY = isSystemCell ? 9.0f
                : (layout.grouped ? 2.0f : (layout.hasReference ? 46.0f : 28.0f));
            CGFloat contentOriginX = DCChatBodyOriginX + forwardedInset;
            CGFloat contentOriginY = baseContentOriginY + forwardedVerticalInset;
            float contentWidth = tableView.width - 63 - forwardedInset;

            // Set content
            cellPerfContentStart = CFAbsoluteTimeGetCurrent();

            cell.contentTextView.delegate = context;
            cell.contentTextView.userInteractionEnabled = YES;

            NSCharacterSet *invisibleChars = [NSCharacterSet characterSetWithCharactersInString:@"\u00A0\u200B\n\r\t "];
            BOOL hasVisibleContent = [[messageAtRowIndex.content stringByTrimmingCharactersInSet:invisibleChars] length] > 0 
                || messageAtRowIndex.emojis.count > 0;
            CGFloat textHeight = layout.textHeight;

            if (!hasVisibleContent) {
                // Drop the previous message's DTCoreText frame before changing
                // the string/frame.  Otherwise DTAttributedLabel eagerly
                // relayouts the NEW string using the OLD cell geometry.
                cell.contentTextView.layoutFrame = nil;
                cell.contentTextView.attributedString = nil;
                cell.contentTextView.hidden = YES;
                cell.contentTextView.frame = CGRectMake(
                    contentOriginX,
                    contentOriginY,
                    contentWidth,
                    0
                );
            } else {
                if (!messageAtRowIndex.attributedContent && messageAtRowIndex.content.length > 0) {
                    messageAtRowIndex.attributedContent = [[DCMarkdownParser sharedParser]
                        attributedStringFromMarkdown:messageAtRowIndex.content
                                              inGuild:renderingGuild];
                }

                cell.contentTextView.hidden = NO;

                // Reuse the prepared DTCoreText frame; clear stale geometry before binding it.
                cell.contentTextView.layoutFrame = nil;
                cell.contentTextView.attributedString = messageAtRowIndex.attributedContent;
                cell.contentTextView.frame = CGRectMake(
                    contentOriginX,
                    contentOriginY,
                    contentWidth,
                    textHeight
                );
                cell.contentTextView.layoutFrame = layout.textLayoutFrame;

                // Link buttons and custom emoji views still need to be built
                // from the prepared frame.  This traverses the already-laid-out
                // glyph runs; it no longer asks DTCoreText to shape/layout the
                // text again.
                [cell.contentTextView layoutSubviewsInRect:CGRectInfinite];
            }
            cellPerfContentEnd = CFAbsoluteTimeGetCurrent();
            cellPerfPostContentStart = CFAbsoluteTimeGetCurrent();
            UIImage *authorAvatar = [context avatarImageForUser:messageAtRowIndex.author];
            if (cell.profileImage.image != authorAvatar) {
                cell.profileImage.image = authorAvatar;
            }
            if (cell.profileImage.gestureRecognizers.count == 0) {
                cell.profileImage.userInteractionEnabled = YES;
                UITapGestureRecognizer *profileTap = [[UITapGestureRecognizer alloc]
                    initWithTarget:context action:@selector(profileImageTapped:)];
                profileTap.numberOfTapsRequired = 1;
                [cell.profileImage addGestureRecognizer:profileTap];
            }
            if ((context.replyingToMessage
                     && [context.replyingToMessage.snowflake
                         isEqualToString:messageAtRowIndex.snowflake])
                || (context.editingMessage
                    && [context.editingMessage.snowflake
                        isEqualToString:messageAtRowIndex.snowflake])) {
                cell.contentView.backgroundColor = replyHighlightColor;
            } else if (messageAtRowIndex.pingingUser) {
                cell.contentView.backgroundColor = pingColor;
            } else {
                cell.contentView.backgroundColor = normalColor;
            }

            CGFloat imageViewOffset;
            if (layout.grouped) {
                imageViewOffset = MAX(textHeight, 18) + 4;
            } else {
                CGFloat authorHeight = layout.showsAuthorName ? [UIFont boldSystemFontOfSize:15].lineHeight : 0;
                imageViewOffset = MAX(
                    authorHeight
                        + (messageAtRowIndex.attachmentCount ? (hasVisibleContent ? textHeight : 0) : MAX(textHeight, 18))
                        + 10
                        + (layout.hasReference ? 16 : 0),
                    authorHeight + (hasVisibleContent ? [UIFont systemFontOfSize:14].lineHeight : 0) + 10
                );
            }
            if (messageAtRowIndex.isForwarded) {
                imageViewOffset += DCForwardedVerticalInset;
            }
            cellPerfPostContentEnd = CFAbsoluteTimeGetCurrent();

            cellPerfAttachmentsStart = CFAbsoluteTimeGetCurrent();
            BOOL allowAttachmentHydration =
                ![context shouldDeferChatMediaHydration];
            CGFloat attachmentOriginX = DCChatBodyOriginX + forwardedInset;
            CGFloat attachmentMaximumWidth =
                tableView.width - 66 - forwardedInset;
            for (id attachment in messageAtRowIndex.attachments) {
                @autoreleasepool {
                    if ([attachment isKindOfClass:[UILazyImage class]]) {
                        UILazyImageView *imageView = [UILazyImageView new];
                        UILazyImage *lazyImage     = attachment;
                        CGSize sourceSize = CGSizeZero;
                        if (lazyImage.naturalSize.width > 0 && lazyImage.naturalSize.height > 0) {
                            sourceSize = lazyImage.naturalSize;
                        } else if (lazyImage.image) {
                            sourceSize = lazyImage.image.size;
                        }
                        if (sourceSize.width <= 0 || sourceSize.height <= 0) continue;
                        CGFloat aspectRatio = sourceSize.width / sourceSize.height;
                        int newWidth  = messageAtRowIndex.isSticker ? 160 : (int)(200 * aspectRatio);
                        int newHeight = messageAtRowIndex.isSticker ? 160 : 200;
                        if (newWidth > attachmentMaximumWidth) {
                            newWidth  = attachmentMaximumWidth;
                            newHeight = newWidth / aspectRatio;
                        }
                        imageView.frame = CGRectMake(
                            attachmentOriginX, imageViewOffset, newWidth, newHeight
                        );
                        imageView.imageURL = lazyImage.imageURL;
                        imageViewOffset += newHeight;

                        imageView.contentMode = UIViewContentModeScaleAspectFit;

                        UITapGestureRecognizer *singleTap =
                            [[UITapGestureRecognizer alloc]
                                initWithTarget:context
                                        action:@selector(tappedImage:)];
                        singleTap.numberOfTapsRequired   = 1;
                        imageView.userInteractionEnabled = YES;

                        [imageView addGestureRecognizer:singleTap];
                        if (lazyImage.spoiler) {
                            DCChatSpoilerView *spoiler = [[DCChatSpoilerView alloc]
                                initWithFrame:imageView.bounds
                                  spoilerKey:lazyImage.spoilerKey
                                 placeholder:lazyImage.spoilerPlaceholder];
                            imageView.spoilerView = spoiler;
                            [singleTap requireGestureRecognizerToFail:spoiler.revealTapRecognizer];
                        }

                        [cell addSubview:imageView];
                        if ([context chatMediaSubviewShouldBeResident:imageView]) {
                            [imageView prepareChatThumbnailForDisplaySize:
                                CGSizeMake(newWidth, newHeight)
                                                        allowLoading:
                                                            allowAttachmentHydration];
                        }
                    } else if ([attachment
                                   isKindOfClass:[DCChatVideoAttachment class]]) {
                        DCChatVideoAttachment *video = attachment;

                        NSArray *existingRecognizers = [NSArray arrayWithArray:video.gestureRecognizers];
                        for (UIGestureRecognizer *gr in existingRecognizers) {
                            [video removeGestureRecognizer:gr];
                        }
                        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc]
                            initWithTarget:context action:@selector(tappedVideo:)];
                        singleTap.numberOfTapsRequired = 1;
                        [video addGestureRecognizer:singleTap];

                        CGSize videoSize = CGSizeZero;
                        if (video.naturalSize.width > 0 && video.naturalSize.height > 0) {
                            videoSize = video.naturalSize;
                        } else if (video.thumbnailImage) {
                            videoSize = video.thumbnailImage.size;
                        } else {
                            videoSize = CGSizeMake(16, 9);
                        }
                        CGFloat aspectRatio = videoSize.width / videoSize.height;
                        int newWidth  = 200 * aspectRatio;
                        int newHeight = 200;
                        if (newWidth > attachmentMaximumWidth) {
                            newWidth  = attachmentMaximumWidth;
                            newHeight = newWidth / aspectRatio;
                        }
                        [video setFrame:CGRectMake(attachmentOriginX, imageViewOffset, newWidth, newHeight)];
                        if (video.spoiler) {
                            if (!video.spoilerView) {
                                video.spoilerView = [[DCChatSpoilerView alloc]
                                    initWithFrame:video.bounds
                                      spoilerKey:video.spoilerKey
                                     placeholder:video.spoilerPlaceholder];
                            }
                            [video.spoilerView refreshRevealState];
                            [singleTap requireGestureRecognizerToFail:
                                video.spoilerView.revealTapRecognizer];
                        }

                        imageViewOffset += newHeight;

                        [cell addSubview:video];
                        if ([context chatMediaSubviewShouldBeResident:video]) {
                            [video prepareForDisplayAllowLoading:
                                allowAttachmentHydration];
                        }
                    } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
                        DCGifInfo *gifInfo = (DCGifInfo *)attachment;
                        CGSize gifSize = CGSizeZero;
                        if (gifInfo.naturalSize.width > 0 && gifInfo.naturalSize.height > 0) {
                            gifSize = gifInfo.naturalSize;
                        } else {
                            gifSize = CGSizeMake(16.0f, 9.0f);
                        }

                        CGFloat aspectRatio = gifSize.width / gifSize.height;
                        int newWidth  = (int)(200 * aspectRatio);
                        int newHeight = 200;
                        if (newWidth > attachmentMaximumWidth) {
                            newWidth  = attachmentMaximumWidth;
                            newHeight = newWidth / aspectRatio;
                        }

                        DCChatGifAttachment *gif = [[DCChatGifAttachment alloc]
                            initWithFrame:CGRectMake(attachmentOriginX, imageViewOffset, newWidth, newHeight)];
                        gif.gifURL = gifInfo.gifURL;
                        gif.videoBacked = gifInfo.videoBacked;
                        gif.imageURL = gifInfo.thumbnailURL;
                        if (gifInfo.spoiler) {
                            DCChatSpoilerView *spoiler = [[DCChatSpoilerView alloc]
                                initWithFrame:gif.bounds
                                  spoilerKey:gifInfo.spoilerKey
                                 placeholder:gifInfo.spoilerPlaceholder];
                            gif.spoilerView = spoiler;
                            for (UIGestureRecognizer *recognizer in gif.gestureRecognizers) {
                                if ([recognizer isKindOfClass:[UITapGestureRecognizer class]]) {
                                    [recognizer requireGestureRecognizerToFail:spoiler.revealTapRecognizer];
                                }
                            }
                        }
                        imageViewOffset += newHeight;
                        [cell addSubview:gif];
                        if ([context chatMediaSubviewShouldBeResident:gif]) {
                            [gif prepareForDisplayAllowLoading:
                                allowAttachmentHydration];
                        }
                    } else if ([attachment isKindOfClass:[QLPreviewController class]]) {
                        QLPreviewController *preview = attachment;

                        imageViewOffset += 210;

                        [cell addSubview:preview.view];
                    } else if ([attachment isKindOfClass:[NSArray class]]) {
                        NSArray *dimensions = attachment;
                        if (dimensions.count == 2) {
                            int width  = [dimensions[0] intValue];
                            int height = [dimensions[1] intValue];
                            if (width <= 0 || height <= 0) {
                                continue;
                            }
                            CGFloat aspectRatio = (CGFloat)width / height;
                            int newWidth        = 200 * aspectRatio;
                            int newHeight       = 200;
                            if (newWidth > attachmentMaximumWidth) {
                                newWidth  = attachmentMaximumWidth;
                                newHeight = newWidth / aspectRatio;
                            }
                            UIActivityIndicatorView *activityIndicator =
                                [[UIActivityIndicatorView alloc]
                                    initWithActivityIndicatorStyle:
                                        UIActivityIndicatorViewStyleWhite];
                            activityIndicator.center = CGPointMake(
                                attachmentOriginX + (newWidth * 0.5f),
                                imageViewOffset + (newHeight * 0.5f));
                            imageViewOffset += newHeight + 11;

                            [cell addSubview:activityIndicator];
                            [activityIndicator startAnimating];
                        }
                    }
                }
            }
        cellPerfAttachmentsEnd = CFAbsoluteTimeGetCurrent();

        /*
         * Diagnostics only: a retained live message with attributed text must
         * never reach a visible row with a zero text layout. Likewise, an
         * attachmentCount with an empty attachment model would indicate that
         * media geometry was published after layout prewarm (the old video
         * race). Do not repair either condition here; preserve evidence.
         */
        if (layout.textHeight <= 0.0f &&
            (messageAtRowIndex.attributedContent.length > 0 ||
             messageAtRowIndex.content.length > 0 ||
             messageAtRowIndex.rawContent.length > 0)) {
            NSLog(@"[LayoutDiag] VISIBLE ZERO-TEXT LAYOUT %@ "
                  @"row %ld rowH %.0f raw %lu content %lu attr %lu "
                  @"attrObject %@ atts %lu/%ld frame %@",
                  messageAtRowIndex.snowflake ?: @"?",
                  (long)row,
                  layout.height,
                  (unsigned long)messageAtRowIndex.rawContent.length,
                  (unsigned long)messageAtRowIndex.content.length,
                  (unsigned long)messageAtRowIndex.attributedContent.length,
                  messageAtRowIndex.attributedContent ? @"present" : @"nil",
                  (unsigned long)messageAtRowIndex.attachments.count,
                  (long)messageAtRowIndex.attachmentCount,
                  layout.textLayoutFrame ? @"cached" : @"missing");
        }

        if (messageAtRowIndex.attachmentCount > 0 &&
            messageAtRowIndex.attachments.count == 0) {
            NSLog(@"[LayoutDiag] VISIBLE ATTACHMENT MODEL MISMATCH %@ "
                  @"row %ld rowH %.0f attachmentCount %ld arrayCount %lu",
                  messageAtRowIndex.snowflake ?: @"?",
                  (long)row,
                  layout.height,
                  (long)messageAtRowIndex.attachmentCount,
                  (unsigned long)messageAtRowIndex.attachments.count);
        }

        CFAbsoluteTime cellPerfEnd = CFAbsoluteTimeGetCurrent();
        NSTimeInterval cellPerfTotal = cellPerfEnd - cellPerfStart;
        if (cellPerfTotal >= 0.005) {
            NSTimeInterval contentTime =
                (cellPerfContentEnd > cellPerfContentStart)
                    ? (cellPerfContentEnd - cellPerfContentStart) : 0;
            NSTimeInterval attachmentTime =
                (cellPerfAttachmentsEnd > cellPerfAttachmentsStart)
                    ? (cellPerfAttachmentsEnd - cellPerfAttachmentsStart) : 0;
            NSTimeInterval otherTime = MAX(0, cellPerfTotal - contentTime - attachmentTime);
            NSLog(@"[ChatPerf] cell %@ total %.1fms content %.1fms attachments %.1fms "
                  @"other %.1fms textH %.0f rowH %.0f atts %lu/%ld ref %d frame %@",
                  messageAtRowIndex.snowflake ?: @"?",
                  cellPerfTotal * 1000.0,
                  contentTime * 1000.0,
                  attachmentTime * 1000.0,
                  otherTime * 1000.0,
                  layout.textHeight,
                  layout.height,
                  (unsigned long)messageAtRowIndex.attachments.count,
                  (long)messageAtRowIndex.attachmentCount,
                  layout.hasReference,
                  layout.textLayoutFrame ? @"cached" : @"missing");

            if (cellPerfTotal >= 0.020 || otherTime >= 0.020) {
                NSTimeInterval dequeueTime =
                    (cellPerfDequeueEnd > cellPerfDequeueStart)
                        ? (cellPerfDequeueEnd - cellPerfDequeueStart) : 0;
                NSTimeInterval avatarTime =
                    (cellPerfAvatarEnd > cellPerfAvatarStart)
                        ? (cellPerfAvatarEnd - cellPerfAvatarStart) : 0;
                NSTimeInterval cleanupTime =
                    (cellPerfCleanupEnd > cellPerfCleanupStart)
                        ? (cellPerfCleanupEnd - cellPerfCleanupStart) : 0;
                NSTimeInterval referenceParseTime =
                    (cellPerfReferenceParseEnd > cellPerfReferenceParseStart)
                        ? (cellPerfReferenceParseEnd - cellPerfReferenceParseStart) : 0;
                NSTimeInterval referenceBindTime = cellPerfReferenceBindTime;
                NSTimeInterval headerTime =
                    (cellPerfHeaderEnd > cellPerfHeaderStart)
                        ? (cellPerfHeaderEnd - cellPerfHeaderStart) : 0;
                NSTimeInterval postContentTime =
                    (cellPerfPostContentEnd > cellPerfPostContentStart)
                        ? (cellPerfPostContentEnd - cellPerfPostContentStart) : 0;

                NSTimeInterval accounted = dequeueTime + avatarTime + cleanupTime +
                    referenceParseTime + referenceBindTime + headerTime +
                    contentTime + postContentTime + attachmentTime;
                NSTimeInterval residual = MAX(0, cellPerfTotal - accounted);

                NSLog(@"[ChatPerf] cell detail %@ dequeue %.1f avatar %.1f cleanup %.1f "
                      @"refParse %.1f refBind %.1f header %.1f content %.1f post %.1f "
                      @"attachments %.1f residual %.1f ref %d",
                      messageAtRowIndex.snowflake ?: @"?",
                      dequeueTime * 1000.0,
                      avatarTime * 1000.0,
                      cleanupTime * 1000.0,
                      referenceParseTime * 1000.0,
                      referenceBindTime * 1000.0,
                      headerTime * 1000.0,
                      contentTime * 1000.0,
                      postContentTime * 1000.0,
                      attachmentTime * 1000.0,
                      residual * 1000.0,
                      layout.hasReference);
            }
        }

        cell.messageSnowflake =
            [messageAtRowIndex.snowflake copy];

        cell.configuredLayout = layout;
    }
    cell.transform = CGAffineTransformMakeScale(1.0f, -1.0f);
    if (context.readOnlyMessageListMode) {
        [context configureMessageListActionForCell:cell layoutHeight:layout.height];
    }
    return cell;
}

@end
