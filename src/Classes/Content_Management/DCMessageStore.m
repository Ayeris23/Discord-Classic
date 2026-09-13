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

static NSComparisonResult DCCompareMessageSnowflakes(NSString *left, NSString *right) {
    if (left.length < right.length) return NSOrderedAscending;
    if (left.length > right.length) return NSOrderedDescending;
    return [left compare:right options:NSLiteralSearch];
}

static NSString *DCMessageSourceChannelID(DCMessage *message) {
    id channelID = [message.sourceJSON objectForKey:@"channel_id"];
    return [channelID isKindOfClass:[NSString class]] ? channelID : nil;
}

static NSArray *DCNormalizeFetchedMessages(NSArray *messages,
                                           NSString *channelID,
                                           DCMessage *anchor,
                                           BOOL newerThanAnchor) {
    if (!messages) return nil;
    if (messages.count == 0) return [NSArray array];

    NSString *anchorID = anchor.snowflake;
    NSMutableDictionary *bySnowflake =
        [NSMutableDictionary dictionaryWithCapacity:messages.count];

    for (id value in messages) {
        if (![value isKindOfClass:[DCMessage class]]) continue;

        DCMessage *message = value;
        NSString *messageID = message.snowflake;
        if (!messageID.length) continue;

        NSString *sourceChannelID = DCMessageSourceChannelID(message);
        if (channelID.length && sourceChannelID.length &&
            ![sourceChannelID isEqualToString:channelID]) {
            NSLog(@"[DCMessageStore] Dropping message %@ from channel %@ while loading %@",
                  messageID, sourceChannelID, channelID);
            continue;
        }

        if (anchorID.length) {
            NSComparisonResult relative =
                DCCompareMessageSnowflakes(messageID, anchorID);
            if ((newerThanAnchor && relative != NSOrderedDescending) ||
                (!newerThanAnchor && relative != NSOrderedAscending)) {
                NSLog(@"[DCMessageStore] Dropping out-of-range message %@ around anchor %@",
                      messageID, anchorID);
                continue;
            }
        }

        [bySnowflake setObject:message forKey:messageID];
    }

    NSArray *normalized = [bySnowflake allValues];
    return [normalized sortedArrayUsingComparator:^NSComparisonResult(DCMessage *left,
                                                                       DCMessage *right) {
        return DCCompareMessageSnowflakes(left.snowflake, right.snowflake);
    }];
}

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
    return DCNormalizeFetchedMessages(older, channel.snowflake, anchor, NO);
}

- (NSArray *)loadAfterForChannel:(DCChannel *)channel
                    afterMessage:(DCMessage *)message
                           limit:(int)limit {
    if (!channel) return nil;

    NSArray *newer = [channel getMessages:limit afterMessage:message];
    return DCNormalizeFetchedMessages(newer, channel.snowflake, message, YES);
}

- (DCMessageDelta *)reconcileForwardForChannel:(DCChannel *)channel
                                  afterMessage:(DCMessage *)anchor {
    if (!channel || !anchor) return nil;

    const int forwardLimit = [DCTools isOriginalIPad] ? 18 : 50;

    NSArray *rawFetched = [channel getMessages:forwardLimit afterMessage:anchor];
    if (!rawFetched || rawFetched.count == 0) {
        return nil;
    }

    NSArray *fetched =
        DCNormalizeFetchedMessages(rawFetched, channel.snowflake, anchor, YES);
    if (fetched.count == 0) return nil;

    DCMessageDelta *delta = [DCMessageDelta new];

    if (rawFetched.count >= (NSUInteger)forwardLimit) {
        // Cap hit: there may be a gap between the anchor and the present, and
        // paginating forward to bridge it is too costly on this hardware. The
        // user is returning to live, so re-anchor at the present instead.
        NSArray *replacement = [channel getMessages:forwardLimit beforeMessage:nil];
        if (!replacement) return nil;

        delta.requiresFullReload = YES;
        delta.replacementMessages =
            DCNormalizeFetchedMessages(replacement, channel.snowflake, nil, NO) ?: @[];
    } else {
        delta.candidateMessages = fetched;
    }
    return delta;
}

- (DCChannelWindow *)windowForChannel:(NSString *)channelSnowflake {
    if (!channelSnowflake) return nil;

    DCChannelWindow *window = nil;
    @synchronized (self) {
        window = [self.channelWindows objectForKey:channelSnowflake];
    }
    if (window) return window;

    CFAbsoluteTime windowLoadStart = CFAbsoluteTimeGetCurrent();
    DCChannelWindow *loadedWindow = [[DCCacheManager sharedInstance]
        loadMessageWindowForChannel:channelSnowflake];
    if (loadedWindow) {
        NSLog(@"[ColdStartPerf] Message window %@ restore: %.3fs",
              channelSnowflake,
              CFAbsoluteTimeGetCurrent() - windowLoadStart);
        NSLog(@"[ColdStart] Restored %lu cached messages for channel %@",
              (unsigned long)loadedWindow.messages.count, channelSnowflake);
    } else {
        loadedWindow = [[DCChannelWindow alloc]
            initWithChannelSnowflake:channelSnowflake];
    }

    @synchronized (self) {
        window = [self.channelWindows objectForKey:channelSnowflake];
        if (!window) {
            [self.channelWindows setObject:loadedWindow forKey:channelSnowflake];
            window = loadedWindow;
        }
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
    NSUInteger generation = 0;
    @synchronized (self) {
        generation = [[self.checkpointGenerations objectForKey:channelID]
            unsignedIntegerValue] + 1;
        [self.checkpointGenerations
            setObject:[NSNumber numberWithUnsignedInteger:generation]
               forKey:channelID];
    }

    // Coalesce checkpoints more aggressively on the most constrained device.
    NSTimeInterval checkpointDelay = [DCTools isOriginalIPad] ? 6.0 : 1.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(checkpointDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUInteger current = 0;
        DCChannelWindow *currentWindow = nil;
        @synchronized (self) {
            current = [[self.checkpointGenerations objectForKey:channelID]
                unsignedIntegerValue];
            currentWindow = [self.channelWindows objectForKey:channelID];
        }
        if (current != generation) return;
        if (currentWindow) [self checkpointWindow:currentWindow];
    });
}

- (void)checkpointWindow:(DCChannelWindow *)window {
    if (!window.channelSnowflake.length) return;
    [[DCCacheManager sharedInstance] saveMessageWindow:window];
}

- (void)checkpointAllWindows {
    NSArray *windows = nil;
    @synchronized (self) {
        windows = [[self.channelWindows allValues] copy];
    }
    for (DCChannelWindow *window in windows) {
        [self checkpointWindow:window];
    }
}

- (void)removeWindowForChannel:(NSString *)channelSnowflake {
    if (!channelSnowflake) return;
    @synchronized (self) {
        [self.channelWindows removeObjectForKey:channelSnowflake];
        [self.checkpointGenerations removeObjectForKey:channelSnowflake];
    }
    [[DCCacheManager sharedInstance]
        invalidateMessageWindowForChannel:channelSnowflake];
}

- (void)removeAllWindows {
    @synchronized (self) {
        [self.channelWindows removeAllObjects];
        [self.checkpointGenerations removeAllObjects];
    }
    [[DCCacheManager sharedInstance] invalidateAllMessageWindows];
}

@end