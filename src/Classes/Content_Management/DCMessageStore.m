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
#import "DCCacheManager.h"
#import "DCTools.h"

@interface DCMessageStore ()
@property (nonatomic, strong) NSMutableDictionary *channelWindows; // channelID -> DCChannelWindow
@property (nonatomic, strong) NSMutableDictionary *checkpointGenerations; // channelID -> NSNumber
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
        _checkpointGenerations = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray *)loadBeforeForChannel:(DCChannel *)channel
                    beforeMessage:(DCMessage *)anchor
                            limit:(int)limit {
    if (!channel) return nil;

    NSArray *older = [channel getMessages:limit beforeMessage:anchor];

    // A short page marks the start of channel history.
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

    const int forwardLimit = [DCTools isOriginalIPad] ? 18 : 50;

    NSArray *fetched = [channel getMessages:forwardLimit afterMessage:anchor];
    if (!fetched || fetched.count == 0) {
        return nil; // nothing newer than the anchor
    }

    DCMessageDelta *delta = [DCMessageDelta new];

    if (fetched.count >= forwardLimit) {
        // Cap hit: there may be a gap between the anchor and the present, and
        // paginating forward to bridge it is too costly on this hardware. The
        // user is returning to live, so re-anchor at the present instead.
        delta.requiresFullReload  = YES;
        delta.replacementMessages = [channel getMessages:forwardLimit beforeMessage:nil] ?: @[];
    } else {
        delta.candidateMessages = fetched;
    }
    return delta;
}

- (DCChannelWindow *)windowForChannel:(NSString *)channelSnowflake {
    if (!channelSnowflake) return nil;
    DCChannelWindow *window = self.channelWindows[channelSnowflake];
    if (!window) {
        CFAbsoluteTime windowLoadStart = CFAbsoluteTimeGetCurrent();
        window = [[DCCacheManager sharedInstance]
            loadMessageWindowForChannel:channelSnowflake];
        if (window) {
            NSLog(@"[ColdStartPerf] Message window %@ restore: %.3fs",
                   channelSnowflake,
                   CFAbsoluteTimeGetCurrent() - windowLoadStart);
        }
        if (window) {
            NSLog(@"[ColdStart] Restored %lu cached messages for channel %@",
                  (unsigned long)window.messages.count, channelSnowflake);
        } else {
            window = [[DCChannelWindow alloc] initWithChannelSnowflake:channelSnowflake];
        }
        self.channelWindows[channelSnowflake] = window;
    }
    return window;
}

- (void)scheduleCheckpointForWindow:(DCChannelWindow *)window {
    if (!window.channelSnowflake.length) return;
    if (window.messages.count == 0) {
        [[DCCacheManager sharedInstance]
            invalidateMessageWindowForChannel:window.channelSnowflake];
        return;
    }

    NSString *channelID = [window.channelSnowflake copy];
    NSUInteger generation = [[self.checkpointGenerations objectForKey:channelID]
        unsignedIntegerValue] + 1;
    [self.checkpointGenerations setObject:[NSNumber numberWithUnsignedInteger:generation]
                                   forKey:channelID];

    // Coalesce checkpoints more aggressively on the most constrained device.
    NSTimeInterval checkpointDelay = [DCTools isOriginalIPad] ? 6.0 : 1.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(checkpointDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUInteger current = [[self.checkpointGenerations objectForKey:channelID]
            unsignedIntegerValue];
        if (current != generation) return;

        DCChannelWindow *currentWindow = [self.channelWindows objectForKey:channelID];
        if (currentWindow) [self checkpointWindow:currentWindow];
    });
}

- (void)checkpointWindow:(DCChannelWindow *)window {
    if (!window.channelSnowflake.length) return;
    [[DCCacheManager sharedInstance] saveMessageWindow:window];
}

- (void)checkpointAllWindows {
    NSArray *windows = [[self.channelWindows allValues] copy];
    for (DCChannelWindow *window in windows) {
        [self checkpointWindow:window];
    }
}

- (void)removeWindowForChannel:(NSString *)channelSnowflake {
    if (!channelSnowflake) return;
    [self.channelWindows removeObjectForKey:channelSnowflake];
    [self.checkpointGenerations removeObjectForKey:channelSnowflake];
    [[DCCacheManager sharedInstance]
        invalidateMessageWindowForChannel:channelSnowflake];
}

- (void)removeAllWindows {
    [self.channelWindows removeAllObjects];
    [self.checkpointGenerations removeAllObjects];
    [[DCCacheManager sharedInstance] invalidateAllMessageWindows];
}

@end