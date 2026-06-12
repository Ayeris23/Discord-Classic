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

@implementation DCChannelWindow

- (instancetype)initWithChannelSnowflake:(NSString *)snowflake {
    self = [super init];
    if (self) {
        _channelSnowflake = [snowflake copy];
        _messages         = [NSMutableArray array];
        _atPresentTime    = YES;  // a freshly opened window anchors to present
        _hasMoreBefore    = YES;  // assume history exists until a load proves otherwise
        _hasMoreAfter  = NO;   // window holds the live tail by default
    }
    return self;
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