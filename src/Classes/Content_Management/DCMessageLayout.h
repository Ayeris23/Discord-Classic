//
//  DCMessageLayout.h
//  Discord Classic
//
//  Created by Ayeris on 6/15/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>

// Immutable description of how a single message renders at a specific
// table width, given its immediate neighbors. Produced by
// DCMessageLayoutBuilder and cached by DCCacheManager.
//
// Deliberately holds no reference to the DCMessage itself — callers
// already have it from self.messages, and the layout cache should not be
// the thing keeping evicted messages alive on top of whatever the
// window-eviction work in Step 4d is already trying to bound.
@interface DCMessageLayout : NSObject

@property (nonatomic, copy) NSString *messageSnowflake;

// The table width this layout was built for. Part of what makes two
// layout instances "the same" for cell-reuse identity comparisons later.
@property (nonatomic, assign) CGFloat tableWidth;

// Whether this message groups under its predecessor (no avatar/author
// name/timestamp shown).
@property (nonatomic, assign) BOOL grouped;

// Whether the NEXT message groups under THIS one. Affects this message's
// own height (see DCMessageLayoutBuilder) — this is the value that used
// to live behind the "_hasGrouped" cache-key suffix.
@property (nonatomic, assign) BOOL followedByGrouped;

// Whether this message carries a reply reference — resolved or
// unresolved, both count.
@property (nonatomic, assign) BOOL hasReference;

// The fully computed cell height for messageSnowflake at tableWidth.
@property (nonatomic, assign) CGFloat height;

// One of "Grouped Message Cell", "Reply Message Cell",
// "Universal Typehandler Cell", "Message Cell".
@property (nonatomic, copy) NSString *reuseIdentifier;

// Per-width text content height — the result of laying out
// message.attributedContent at this layout's content width. Exposed so
// cell configuration can size the content text view and position
// attachments without re-running the text layout pass that -height
// already performed.
@property (nonatomic, assign) CGFloat textHeight;

// Whether this message type shows/measures an author name (see
// +shouldShowAuthorNameForMessageType: in DCMessageLayoutBuilder).
@property (nonatomic, assign) BOOL showsAuthorName;

@end