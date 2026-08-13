//
//  DCGuild.m
//  Discord Classic
//
//  Created by bag.xml on 3/12/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCGuild.h"
#import "DCChannel.h"
#import "DCContentManager.h"

@implementation DCGuild

@synthesize icon = _icon;

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
            self.snowflake, self.unread, self.name, self.channels];
}

- (void)checkIfRead {
    BOOL oldUnread = self.unread;
    if (self.muted && self.mentionCount == 0) {
        // Only suppress unread dot if muted AND no mentions
        self.unread = false;
        goto refreshMarker;
    }
    /*Loop through all child channels
     if any single one is unread, the guild
     as a whole is unread*/
    for (DCChannel *channel in self.channels) {
        if (channel.unread) {
            self.unread = true;
            goto refreshMarker;
        }
    }
    self.unread = false;
refreshMarker:
    if (self.unread != oldUnread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"RELOAD GUILD"
                              object:self];
        });
    }
}

- (NSInteger)mentionCount {
    NSInteger total = 0;
    for (DCChannel *channel in self.channels) {
        total += channel.mentionCount;
    }
    return total;
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.snowflake   forKey:@"snowflake"];
    [aCoder encodeObject:self.name        forKey:@"name"];
    [aCoder encodeObject:self.ownerID     forKey:@"ownerID"];
    [aCoder encodeInteger:self.memberCount forKey:@"memberCount"];
    [aCoder encodeBool:self.muted         forKey:@"muted"];
    [aCoder encodeObject:self.channels    forKey:@"channels"];
    [aCoder encodeObject:self.roles       forKey:@"roles"];
    [aCoder encodeObject:self.userRoles   forKey:@"userRoles"];
    [aCoder encodeObject:self.emojis      forKey:@"emojis"];
    [aCoder encodeObject:self.iconID      forKey:@"iconID"];
    [aCoder encodeObject:self.iconURL     forKey:@"iconURL"];
    [aCoder encodeObject:self.bannerID    forKey:@"bannerID"];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self) {
        self.snowflake   = [aDecoder decodeObjectForKey:@"snowflake"];
        self.name        = [aDecoder decodeObjectForKey:@"name"];
        self.ownerID     = [aDecoder decodeObjectForKey:@"ownerID"];
        self.memberCount = [aDecoder decodeIntegerForKey:@"memberCount"];
        self.muted       = [aDecoder decodeBoolForKey:@"muted"];
        self.channels    = [aDecoder decodeObjectForKey:@"channels"];
        self.roles       = [[aDecoder decodeObjectForKey:@"roles"] mutableCopy];
        self.userRoles   = [[aDecoder decodeObjectForKey:@"userRoles"] mutableCopy];
        self.emojis      = [[aDecoder decodeObjectForKey:@"emojis"] mutableCopy];
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
    return self;
}

@end
