//
//  DCGuild.m
//  Discord Classic
//
//  Created by bag.xml on 3/12/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCGuild.h"
#import "DCCacheManager.h"
#import "DCChannel.h"
#import "DCContentManager.h"

@implementation DCGuild

@synthesize icon = _icon;

- (id)init {
    self = [super init];
    if (self) {
        self.members = [NSMutableArray array];
    }
    return self;
}

- (void)setIcon:(UIImage *)icon {
    if (_icon == icon) return;
    _icon = icon;
    self.compositedIcon = icon ? [DCContentManager processedGuildIcon:icon] : nil;
    if (icon) [DCContentManager processedFolderMiniGuildIcon:icon];
}

- (NSString*)description {
    return [NSString
        stringWithFormat:
            @"[Guild] Snowflake: %@, Read: %d, Name: %@, Channels: %@",
            self.snowflake, self.unread, self.name, [self channelsSnapshot]];
}

- (void)checkIfRead {
    BOOL oldUnread;
    BOOL isUnread = NO;
    @synchronized (self) {
        oldUnread = self.unread;
        if (!self.muted || self.mentionCount > 0) {
            for (DCChannel *channel in self.channels) {
                if (channel.unread) {
                    isUnread = YES;
                    break;
                }
            }
        }
        self.unread = isUnread;
    }
    if (isUnread != oldUnread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"RELOAD GUILD"
                              object:self];
        });
    }
}

- (NSInteger)mentionCount {
    NSInteger total = 0;
    @synchronized (self) {
        for (DCChannel *channel in self.channels) {
            total += channel.mentionCount;
        }
    }
    return total;
}

- (NSArray *)channelsSnapshot {
    @synchronized (self) {
        return [self.channels copy] ?: [NSArray array];
    }
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.snowflake   forKey:@"snowflake"];
    [aCoder encodeObject:self.name        forKey:@"name"];
    [aCoder encodeObject:self.ownerID     forKey:@"ownerID"];
    [aCoder encodeInteger:self.memberCount forKey:@"memberCount"];
    [aCoder encodeBool:self.muted         forKey:@"muted"];
    NSMutableArray *channelsToEncode;
    @synchronized (self) {
        channelsToEncode = [self.channels mutableCopy];
    }
    [aCoder encodeObject:channelsToEncode forKey:@"channels"];
    [aCoder encodeObject:self.roles       forKey:@"roles"];
    [aCoder encodeObject:self.userRoles   forKey:@"userRoles"];
    [aCoder encodeObject:self.emojis      forKey:@"emojis"];
    [aCoder encodeObject:self.iconID      forKey:@"iconID"];
    [aCoder encodeObject:self.iconURL     forKey:@"iconURL"];
    [aCoder encodeObject:self.bannerID    forKey:@"bannerID"];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    CFAbsoluteTime decodeStart = DCCacheGuildProfileBegin();
    self = [super init];
    if (self) {
        self.snowflake   = [aDecoder decodeObjectForKey:@"snowflake"];
        self.name        = [aDecoder decodeObjectForKey:@"name"];
        self.ownerID     = [aDecoder decodeObjectForKey:@"ownerID"];
        self.memberCount = [aDecoder decodeIntegerForKey:@"memberCount"];
        self.muted       = [aDecoder decodeBoolForKey:@"muted"];
        CFAbsoluteTime stepStart = DCCacheGuildProfileBegin();
        id cachedChannels = [aDecoder decodeObjectForKey:@"channels"];
        if ([cachedChannels isKindOfClass:[NSMutableArray class]]) {
            self.channels = cachedChannels;
        } else if ([cachedChannels isKindOfClass:[NSArray class]]) {
            self.channels = [cachedChannels mutableCopy];
        } else {
            self.channels = [NSMutableArray array];
        }
        DCCacheGuildProfileStep(DCCacheGuildDecodeStepChannels, stepStart);

        stepStart = DCCacheGuildProfileBegin();
        id cachedRoles = [aDecoder decodeObjectForKey:@"roles"];
        self.roles = [cachedRoles isKindOfClass:[NSMutableDictionary class]]
            ? cachedRoles : [cachedRoles mutableCopy];
        DCCacheGuildProfileStep(DCCacheGuildDecodeStepRoles, stepStart);

        id cachedUserRoles = [aDecoder decodeObjectForKey:@"userRoles"];
        self.userRoles = [cachedUserRoles isKindOfClass:[NSMutableArray class]]
            ? cachedUserRoles : [cachedUserRoles mutableCopy];

        stepStart = DCCacheGuildProfileBegin();
        id cachedEmojis = [aDecoder decodeObjectForKey:@"emojis"];
        self.emojis = [cachedEmojis isKindOfClass:[NSMutableDictionary class]]
            ? cachedEmojis : [cachedEmojis mutableCopy];
        DCCacheGuildProfileStep(DCCacheGuildDecodeStepEmojis, stepStart);
        self.iconID    = [aDecoder decodeObjectForKey:@"iconID"];
        self.iconURL   = [aDecoder decodeObjectForKey:@"iconURL"];
        self.bannerID  = [aDecoder decodeObjectForKey:@"bannerID"];

        // Migrate pre-hash caches. The old archive retained the hash-bearing
        // CDN URL but not the hash as a first-class field. Recover it once so
        // the first GUILD_UPDATE after upgrading does not falsely look like an
        // icon change.
        if (!self.iconID.length && self.iconURL.length) {
            NSURL *url = [NSURL URLWithString:self.iconURL];
            NSString *filename = [[url path] lastPathComponent];
            NSString *hash = [filename stringByDeletingPathExtension];
            if (hash.length) self.iconID = hash;
        }

        // Full member lists remain live/lazy state. Roles, the signed-in user's
        // role set, and emoji metadata are durable because a successful cold
        // Gateway RESUME does not send another READY to repopulate them.
        self.members = [NSMutableArray array];
        if (!self.roles) self.roles = [NSMutableDictionary dictionary];
        if (!self.userRoles) self.userRoles = [NSMutableArray array];
        if (!self.emojis) self.emojis = [NSMutableDictionary dictionary];
    }
    DCCacheGuildProfileEnd(DCCacheGuildObjectTypeGuild, decodeStart);
    return self;
}

@end
