//
//  DCChannelWindow.m
//  Discord Classic
//
//  Created by Ayeris on 6/7/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCChannelWindow.h"
#import "DCMessage.h"

@interface DCChannelWindow ()
@property (nonatomic, strong, readwrite) NSMutableArray *messages;
@end

static NSComparisonResult DCChannelWindowCompareSnowflakes(NSString *left, NSString *right) {
    if (left.length < right.length) return NSOrderedAscending;
    if (left.length > right.length) return NSOrderedDescending;
    return [left compare:right options:NSLiteralSearch];
}

@implementation DCChannelWindow

- (instancetype)initWithChannelSnowflake:(NSString *)snowflake {
    self = [super init];

    if (self) {
        _channelSnowflake = [snowflake copy];
        _messages = [NSMutableArray array];

        _atPresentTime = YES;
        _hasMoreBefore = YES;
        _hasMoreAfter = NO;

        _savedContentOffsetY = 0.0f;
        _hasSavedContentOffset = NO;
    }

    return self;
}

- (BOOL)repairMessageOrderIfNeeded {
    if (self.messages.count == 0) return NO;

    NSString *previousID = nil;
    BOOL needsRepair = NO;

    for (DCMessage *message in self.messages) {
        NSString *messageID = message.snowflake;
        if (!messageID.length ||
            (previousID.length &&
             DCChannelWindowCompareSnowflakes(previousID, messageID) != NSOrderedAscending)) {
            needsRepair = YES;
            break;
        }
        previousID = messageID;
    }

    if (!needsRepair) return NO;

    NSMutableDictionary *bySnowflake =
        [NSMutableDictionary dictionaryWithCapacity:self.messages.count];

    for (DCMessage *message in self.messages) {
        if (message.snowflake.length) {
            [bySnowflake setObject:message forKey:message.snowflake];
        }
    }

    NSArray *normalized = [[bySnowflake allValues]
        sortedArrayUsingComparator:^NSComparisonResult(DCMessage *left, DCMessage *right) {
            return DCChannelWindowCompareSnowflakes(left.snowflake, right.snowflake);
        }];

    [self.messages removeAllObjects];
    [self.messages addObjectsFromArray:normalized];
    return YES;
}

- (NSString *)latestSnowflake {
    DCMessage *last = [self.messages lastObject];
    return last.snowflake;
}

- (NSString *)oldestSnowflake {
    DCMessage *first = [self.messages firstObject];
    return first.snowflake;
}

@end