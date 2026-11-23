//
//  DCChatMessageRenderer.h
//  Discord Classic
//
//  Created by Ayeris on 11/22/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>
#import "DTAttributedTextContentView.h"

@class DCChatTableCell;
@class DCMessage;
@class DCMessageLayout;
@class DCUser;
@class DCGuild;
@class DCChannel;

// Presentation-only reply data also supports the chat's background prewarm cache.
@interface DCChatReferencePresentation : NSObject
@property (nonatomic, copy) NSString *sourceText;
@property (nonatomic, retain) NSAttributedString *attributedText;
@end

// The renderer owns cell binding; its context owns navigation, media presentation,
// avatar policy, and actions. Other message lists can implement this interface.
@protocol DCChatMessageRenderingContext <NSObject, DTAttributedTextContentViewDelegate>
@property (nonatomic, readonly) DCMessage *replyingToMessage;
@property (nonatomic, readonly) DCMessage *editingMessage;
@property (nonatomic, readonly) NSCache *referencePresentationCache;
@property (nonatomic, readonly) BOOL readOnlyMessageListMode;

- (DCChannel *)messageRenderingChannel;
- (UIImage *)avatarImageForUser:(DCUser *)user;
- (void)ensureAvatarForUser:(DCUser *)user;
- (NSString *)referencePreviewTextForMessage:(DCMessage *)message;
- (void)configureForwardSourceTagForCell:(DCChatTableCell *)cell
                                  message:(DCMessage *)message
                                   layout:(DCMessageLayout *)layout
                               tableWidth:(CGFloat)tableWidth
                                    color:(UIColor *)color;
- (BOOL)chatMediaSubviewShouldBeResident:(UIView *)subview;
- (BOOL)shouldDeferChatMediaHydration;
- (void)configureMessageListActionForCell:(DCChatTableCell *)cell
                             layoutHeight:(CGFloat)height;
- (void)tappedReferencedMessage:(UIButton *)sender;
- (void)profileImageTapped:(UITapGestureRecognizer *)recognizer;
- (void)tappedImage:(UITapGestureRecognizer *)recognizer;
- (void)tappedVideo:(UITapGestureRecognizer *)recognizer;
@end

@interface DCChatMessageRenderer : NSObject
- (DCChatTableCell *)cellForMessage:(DCMessage *)message
                             layout:(DCMessageLayout *)layout
                          tableView:(UITableView *)tableView
                                row:(NSInteger)row
                            context:(id<DCChatMessageRenderingContext>)context;
@end
