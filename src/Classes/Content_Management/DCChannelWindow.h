//
//  DCChannelWindow.h
//  Discord Classic
//
//  Created by Ayeris on 6/7/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>

@interface DCChannelWindow : NSObject

// The channel this window belongs to.
@property (nonatomic, copy) NSString *channelSnowflake;

// Ordered oldest -> newest. This is the array the table reads from.
@property (nonatomic, strong, readonly) NSMutableArray *messages;

// Whether this window's tail is anchored to the live present. This is where
// viewingPresentTime really belongs — present-time is a per-channel fact, not
// a global one. Not wired into the controller yet (next step).
@property (nonatomic, assign) BOOL atPresentTime;

// Whether older messages may still exist before messages.firstObject.
// Terminates backward loading at the true start of channel history.
@property (nonatomic, assign) BOOL hasMoreBefore;

// Convenience reads (nil when empty).
@property (nonatomic, readonly) NSString *latestSnowflake;
@property (nonatomic, readonly) NSString *oldestSnowflake;

- (instancetype)initWithChannelSnowflake:(NSString *)snowflake;

@end