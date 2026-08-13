//
//  DCMessageLayoutBuilder.h
//  Discord Classic
//
//  Created by Ayeris on 6/15/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DCMessage.h"
#import "DCMessageLayout.h"

@interface DCMessageLayoutBuilder : NSObject

// The single definition of "does `message` group under `predecessor`".
// Used both for a message's own `grouped` (predecessor = the previous
// message) and, with the roles shifted by one, for that predecessor's
// `followedByGrouped` (predecessor = this message, message = the next
// one). Returns NO if either argument is nil — a missing neighbor
// (window edge, or not loaded yet) is treated as "cannot group against
// this," which self-corrects once the real neighbor loads and the
// previous/next-snowflake cache key changes.
+ (BOOL)shouldGroupMessage:(DCMessage *)message underPredecessor:(DCMessage *)predecessor;

// Builds the full layout for `message` given its immediate neighbors in
// the model (oldest-first order: previousMessage is older,
// nextMessage is newer) and the current table width.
// previousMessage/nextMessage may be nil at window edges.
- (DCMessageLayout *)layoutForMessage:(DCMessage *)message
                       previousMessage:(DCMessage *)previousMessage
                            nextMessage:(DCMessage *)nextMessage
                             tableWidth:(CGFloat)tableWidth;

// Pre-warms the layout cache for a batch of messages at both portrait
// and landscape widths. Safe to call from a background queue.
// Pass the full ordered batch (oldest-first); neighbor relationships
// within the batch are computed internally.
- (void)prewarmLayoutCacheForMessages:(NSArray *)messages;

// Pre-warm one or more exact layouts at the width the table will actually use.
// These preserve the authoritative DTCoreText sizing path; they only change
// when the work runs (before publication rather than inside UITableView).
- (void)prewarmLayoutCacheForMessage:(DCMessage *)message
                        previousMessage:(DCMessage *)previousMessage
                            nextMessage:(DCMessage *)nextMessage
                             tableWidth:(CGFloat)tableWidth;

- (void)prewarmLayoutCacheForMessages:(NSArray *)messages
                      previousMessage:(DCMessage *)previousMessage
                          nextMessage:(DCMessage *)nextMessage
                           tableWidth:(CGFloat)tableWidth;

@end