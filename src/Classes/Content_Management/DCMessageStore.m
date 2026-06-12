//
//  DCMessageStore.m
//  Discord Classic
//
//  Created by Ayeris on 6/7/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCMessageStore.h"
#import "DCChannel.h"
#import "DCMessage.h"

@interface DCMessageStore ()
@property (nonatomic, strong) NSMutableDictionary *channelWindows; // channelID -> DCChannelWindow
@end

@implementation DCMessageDelta
@end

@implementation DCMessageStore

+ (instancetype)sharedInstance {
    static DCMessageStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [DCMessageStore new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _channelWindows = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray *)loadBeforeForChannel:(DCChannel *)channel
                    beforeMessage:(DCMessage *)anchor
                            limit:(int)limit {
    if (!channel) return nil;

    NSArray *older = [channel getMessages:limit beforeMessage:anchor];

    // If a full page came back there's probably more history before it; a short
    // page means we've reached the start of the channel. Read by proximity
    // loading in the next slice to know when to stop fetching backward.
    DCChannelWindow *window = [self windowForChannel:channel.snowflake];
    window.hasMoreBefore = (older.count >= (NSUInteger)limit);

    return older;
}

- (NSArray *)loadAfterForChannel:(DCChannel *)channel
                    afterMessage:(DCMessage *)message
                           limit:(int)limit {
    if (!channel) return nil;
    NSArray *newer = [channel getMessages:limit afterMessage:message];
    DCChannelWindow *window = [self windowForChannel:channel.snowflake];
    window.hasMoreAfter = (newer.count >= limit);
    return newer;
}

- (DCMessageDelta *)reconcileForwardForChannel:(DCChannel *)channel
                                  afterMessage:(DCMessage *)anchor {
    if (!channel || !anchor) return nil;

    static const int kForwardLimit = 50;

    NSArray *fetched = [channel getMessages:kForwardLimit afterMessage:anchor];
    if (!fetched || fetched.count == 0) {
        return nil; // nothing newer than the anchor
    }

    DCMessageDelta *delta = [DCMessageDelta new];

    if (fetched.count >= kForwardLimit) {
        // Cap hit: there may be a gap between the anchor and the present, and
        // paginating forward to bridge it is too costly on this hardware. The
        // user is returning to live, so re-anchor at the present instead.
        delta.requiresFullReload  = YES;
        delta.replacementMessages = [channel getMessages:kForwardLimit beforeMessage:nil] ?: @[];
    } else {
        delta.candidateMessages = fetched;
    }
    return delta;
}

- (DCChannelWindow *)windowForChannel:(NSString *)channelSnowflake {
    if (!channelSnowflake) return nil;
    DCChannelWindow *window = self.channelWindows[channelSnowflake];
    if (!window) {
        window = [[DCChannelWindow alloc] initWithChannelSnowflake:channelSnowflake];
        self.channelWindows[channelSnowflake] = window;
    }
    return window;
}

- (void)removeWindowForChannel:(NSString *)channelSnowflake {
    if (!channelSnowflake) return;
    [self.channelWindows removeObjectForKey:channelSnowflake];
}

- (void)removeAllWindows {
    [self.channelWindows removeAllObjects];
}

@end