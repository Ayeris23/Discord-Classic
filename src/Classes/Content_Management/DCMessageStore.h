//
//  DCMessageStore.h
//  Discord Classic
//
//  Created by Ayeris on 6/7/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DCChannelWindow.h"

@class DCChannel;
@class DCMessage;

// The result of a reconcile. Carries fetched candidates for the caller to
// dedup + apply on the main thread, or a full replacement set when the gap
// was too large to bridge incrementally.
@interface DCMessageDelta : NSObject
@property (nonatomic, strong) NSArray *candidateMessages;   // forward-fetched, pre-dedup
@property (nonatomic, assign) BOOL requiresFullReload;      // cap-fallback / re-anchor
@property (nonatomic, strong) NSArray *replacementMessages; // full set when reloading
@end

@interface DCMessageStore : NSObject

+ (instancetype)sharedInstance;

// Returns the window for a channel, lazily creating an empty one on first
// access. Every snowflake for a channel lives inside that channel's window —
// the store is keyed entirely by channel ID.
- (DCChannelWindow *)windowForChannel:(NSString *)channelSnowflake;

// Drop a single channel's window from RAM and disk.
- (void)removeWindowForChannel:(NSString *)channelSnowflake;

// Drop everything (e.g. logout), including persistent window snapshots.
- (void)removeAllWindows;

// Debounced persistence for live mutations; immediate persistence is used when
// switching channels/backgrounding so the last visible state is durable.
- (void)scheduleCheckpointForWindow:(DCChannelWindow *)window;
- (void)checkpointWindow:(DCChannelWindow *)window;
- (void)checkpointAllWindows;

// Fetch what's newer than `anchor` in `channel`. Synchronous network — call
// from a background queue. Does NOT mutate the window or touch the array the
// table reads; the caller dedups + applies on main. Returns nil when there's
// nothing new.
- (DCMessageDelta *)reconcileForwardForChannel:(DCChannel *)channel
                                  afterMessage:(DCMessage *)anchor;

// Loads up to `limit` messages older than `anchor` (pass nil for the newest
// page). Returns them grouped + ascending, same as a cold load, and updates
// the channel window's hasMoreBefore. Synchronous network — call from a
// background queue.
- (NSArray *)loadBeforeForChannel:(DCChannel *)channel
                    beforeMessage:(DCMessage *)anchor
                            limit:(int)limit;

- (NSArray *)loadAfterForChannel:(DCChannel *)channel
                    afterMessage:(DCMessage *)message
                           limit:(int)limit;
@end