//
//  DCServerCommunicator.m
//  Discord Classic
//
//  Created by bag.xml on 3/4/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#include "DCServerCommunicator.h"
#include <malloc/malloc.h>
#include <objc/NSObjCRuntime.h>
#import "DCServerCommunicator+Internal.h"
#include "DCUser.h"
#import <sys/utsname.h>

#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <dispatch/dispatch.h>

#include "DCChannel.h"
#include "DCGuild.h"
#include "DCGuildFolder.h"
#include "DCRole.h"
#include "DCTools.h"
#include "SDWebImageManager.h"
#import "DCContentManager.h"
#import "DCCacheManager.h"
#import "DCMessageStore.h"
#import "Base64.h"
#include <stdint.h>

@implementation DCServerCommunicator
UIActivityIndicatorView *spinner;
NSTimer *heartbeatTimer = nil;

/*
 * READY gives us a resume_gateway_url without any guarantee that it carries
 * the same query parameters as our initial Gateway connection. Discord
 * requires Resume to use the same API version, encoding, and compression.
 *
 * Keep this helper Foundation-only so it remains compatible with iOS 5/6
 * (NSURLComponents is too new for our deployment target).
 */

static BOOL DCChannelTypeAppearsInGuildList(DCChannelType type) {
    return type == DCChannelTypeGuildText
        || type == DCChannelTypeGuildAnnouncement
        || type == DCChannelTypeGuildCategory;
}

static UIImage *DCDefaultGuildIconForSnowflake(NSString *snowflake) {
    if (![snowflake isKindOfClass:[NSString class]] || snowflake.length == 0)
        return nil;
    unsigned long long value = [snowflake longLongValue];
    NSUInteger selector = (NSUInteger)((value >> 22) % 6);
    NSArray *defaults = [DCUser defaultAvatars];
    return selector < defaults.count ? [defaults objectAtIndex:selector] : nil;
}

static NSString *DCConfiguredGatewayURL(NSString *urlString) {
    if ([urlString length] == 0) {
        return nil;
    }

    NSRange queryRange = [urlString rangeOfString:@"?"];
    NSString *baseURL = (queryRange.location == NSNotFound)
        ? urlString
        : [urlString substringToIndex:queryRange.location];

    return [baseURL stringByAppendingString:
        @"?encoding=json&v=9&compress=zlib-stream"];
}


#pragma mark - Minimal user-settings protobuf reader

/*
 * USER_SETTINGS_PROTO_UPDATE carries settings.proto as a Base64-encoded
 * PreloadedUserSettings protobuf. Pulling in a full protobuf runtime just to
 * keep the guild sidebar synchronized is unnecessary on our old targets, so
 * this tiny reader understands only the protobuf wire types needed by
 * PreloadedUserSettings.guild_folders:
 *
 *   PreloadedUserSettings field 14 -> GuildFolders
 *   GuildFolders field 1          -> repeated GuildFolder
 *   GuildFolder field 1           -> packed fixed64 guild IDs
 *   GuildFolder field 2           -> google.protobuf.Int64Value folder ID
 *   GuildFolder field 3           -> google.protobuf.StringValue name
 *   GuildFolder field 4           -> google.protobuf.UInt64Value color
 *
 * Unknown fields are skipped, making this intentionally narrow but tolerant
 * of unrelated Discord settings being added to the proto.
 */

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger offset;
} DCProtoReader;

static BOOL DCProtoReadVarint(DCProtoReader *reader, uint64_t *valueOut) {
    if (!reader || !valueOut) return NO;

    uint64_t value = 0;
    unsigned int shift = 0;
    for (unsigned int i = 0; i < 10; i++) {
        if (reader->offset >= reader->length) return NO;
        uint8_t byte = reader->bytes[reader->offset++];
        value |= ((uint64_t)(byte & 0x7F)) << shift;
        if ((byte & 0x80) == 0) {
            *valueOut = value;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

static BOOL DCProtoReadLengthDelimited(DCProtoReader *reader,
                                       const uint8_t **bytesOut,
                                       NSUInteger *lengthOut) {
    uint64_t length64 = 0;
    if (!DCProtoReadVarint(reader, &length64)) return NO;
    if (length64 > (uint64_t)(reader->length - reader->offset)) return NO;

    NSUInteger length = (NSUInteger)length64;
    if (bytesOut) *bytesOut = reader->bytes + reader->offset;
    if (lengthOut) *lengthOut = length;
    reader->offset += length;
    return YES;
}

static BOOL DCProtoSkipField(DCProtoReader *reader, unsigned int wireType) {
    if (!reader) return NO;

    switch (wireType) {
        case 0: {
            uint64_t ignored = 0;
            return DCProtoReadVarint(reader, &ignored);
        }
        case 1: // fixed64
            if (reader->length - reader->offset < 8) return NO;
            reader->offset += 8;
            return YES;
        case 2: // length-delimited
            return DCProtoReadLengthDelimited(reader, NULL, NULL);
        case 5: // fixed32
            if (reader->length - reader->offset < 4) return NO;
            reader->offset += 4;
            return YES;
        default:
            return NO;
    }
}

static uint64_t DCProtoReadLittleEndian64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (unsigned int i = 0; i < 8; i++) {
        value |= ((uint64_t)bytes[i]) << (i * 8);
    }
    return value;
}

static BOOL DCProtoReadWrappedVarint(const uint8_t *bytes,
                                     NSUInteger length,
                                     uint64_t *valueOut) {
    DCProtoReader reader = { bytes, length, 0 };
    while (reader.offset < reader.length) {
        uint64_t key = 0;
        if (!DCProtoReadVarint(&reader, &key)) return NO;
        unsigned int fieldNumber = (unsigned int)(key >> 3);
        unsigned int wireType = (unsigned int)(key & 0x7);
        if (fieldNumber == 1 && wireType == 0) {
            return DCProtoReadVarint(&reader, valueOut);
        }
        if (!DCProtoSkipField(&reader, wireType)) return NO;
    }
    return NO;
}

static NSString *DCProtoReadWrappedString(const uint8_t *bytes,
                                          NSUInteger length) {
    DCProtoReader reader = { bytes, length, 0 };
    while (reader.offset < reader.length) {
        uint64_t key = 0;
        if (!DCProtoReadVarint(&reader, &key)) return nil;
        unsigned int fieldNumber = (unsigned int)(key >> 3);
        unsigned int wireType = (unsigned int)(key & 0x7);
        if (fieldNumber == 1 && wireType == 2) {
            const uint8_t *stringBytes = NULL;
            NSUInteger stringLength = 0;
            if (!DCProtoReadLengthDelimited(&reader, &stringBytes, &stringLength)) return nil;
            return [[NSString alloc] initWithBytes:stringBytes
                                      length:stringLength
                                    encoding:NSUTF8StringEncoding];
        }
        if (!DCProtoSkipField(&reader, wireType)) return nil;
    }
    return nil;
}

static DCGuildFolder *DCDecodeGuildFolderProto(const uint8_t *bytes,
                                                NSUInteger length) {
    DCProtoReader reader = { bytes, length, 0 };
    NSMutableArray *guildIDs = [NSMutableArray array];
    NSInteger folderID = 0;
    NSString *folderName = nil;
    NSInteger folderColor = 0;

    while (reader.offset < reader.length) {
        uint64_t key = 0;
        if (!DCProtoReadVarint(&reader, &key)) return nil;
        unsigned int fieldNumber = (unsigned int)(key >> 3);
        unsigned int wireType = (unsigned int)(key & 0x7);

        if (fieldNumber == 1 && wireType == 2) {
            // repeated fixed64 is packed by Discord's proto3 encoder.
            const uint8_t *packed = NULL;
            NSUInteger packedLength = 0;
            if (!DCProtoReadLengthDelimited(&reader, &packed, &packedLength)) return nil;
            if ((packedLength % 8) != 0) return nil;
            for (NSUInteger i = 0; i < packedLength; i += 8) {
                unsigned long long guildID = (unsigned long long)DCProtoReadLittleEndian64(packed + i);
                [guildIDs addObject:[NSString stringWithFormat:@"%llu", guildID]];
            }
            continue;
        } else if (fieldNumber == 1 && wireType == 1) {
            // Be liberal in case Discord ever emits an unpacked fixed64.
            if (reader.length - reader.offset < 8) return nil;
            unsigned long long guildID = (unsigned long long)DCProtoReadLittleEndian64(reader.bytes + reader.offset);
            reader.offset += 8;
            [guildIDs addObject:[NSString stringWithFormat:@"%llu", guildID]];
            continue;
        } else if ((fieldNumber == 2 || fieldNumber == 4) && wireType == 2) {
            const uint8_t *wrapper = NULL;
            NSUInteger wrapperLength = 0;
            if (!DCProtoReadLengthDelimited(&reader, &wrapper, &wrapperLength)) return nil;
            uint64_t wrappedValue = 0;
            if (!DCProtoReadWrappedVarint(wrapper, wrapperLength, &wrappedValue)) continue;
            if (fieldNumber == 2) {
                // Int64Value uses ordinary int64 varint encoding. Casting the
                // uint64_t bit pattern recovers negative folder IDs correctly.
                folderID = (NSInteger)((int64_t)wrappedValue);
            } else {
                folderColor = (NSInteger)wrappedValue;
            }
            continue;
        } else if (fieldNumber == 3 && wireType == 2) {
            const uint8_t *wrapper = NULL;
            NSUInteger wrapperLength = 0;
            if (!DCProtoReadLengthDelimited(&reader, &wrapper, &wrapperLength)) return nil;
            folderName = DCProtoReadWrappedString(wrapper, wrapperLength);
            continue;
        }

        if (!DCProtoSkipField(&reader, wireType)) return nil;
    }

    DCGuildFolder *folder = [DCGuildFolder new];
    folder.id = folderID;
    folder.name = folderName;
    folder.color = folderColor;
    folder.guildIds = guildIDs;

    NSNumber *opened = nil;
    if (folder.id != 0) {
        NSDictionary *folderPrefs = [[NSUserDefaults standardUserDefaults]
            dictionaryForKey:[@(folder.id) stringValue]];
        opened = [folderPrefs objectForKey:@"opened"];
    }
    folder.opened = opened ? [opened boolValue] : YES;
    return folder;
}

static BOOL DCDecodeGuildLayoutProto(NSData *protoData,
                                     NSMutableArray **positionsOut,
                                     NSMutableArray **foldersOut) {
    if (![protoData length]) return NO;

    DCProtoReader top = { (const uint8_t *)[protoData bytes], [protoData length], 0 };
    const uint8_t *guildFoldersBytes = NULL;
    NSUInteger guildFoldersLength = 0;

    // PreloadedUserSettings.guild_folders is field 14 in the current wire
    // format. Ignore all other top-level settings.
    while (top.offset < top.length) {
        uint64_t key = 0;
        if (!DCProtoReadVarint(&top, &key)) return NO;
        unsigned int fieldNumber = (unsigned int)(key >> 3);
        unsigned int wireType = (unsigned int)(key & 0x7);
        if (fieldNumber == 14 && wireType == 2) {
            if (!DCProtoReadLengthDelimited(&top, &guildFoldersBytes, &guildFoldersLength)) return NO;
            break;
        }
        if (!DCProtoSkipField(&top, wireType)) return NO;
    }

    // A settings update for an unrelated top-level field is not an error.
    if (!guildFoldersBytes) return NO;

    NSMutableArray *positions = [NSMutableArray array];
    NSMutableArray *folders = [NSMutableArray array];
    NSMutableArray *deprecatedPositions = [NSMutableArray array];
    DCProtoReader layout = { guildFoldersBytes, guildFoldersLength, 0 };

    while (layout.offset < layout.length) {
        uint64_t key = 0;
        if (!DCProtoReadVarint(&layout, &key)) return NO;
        unsigned int fieldNumber = (unsigned int)(key >> 3);
        unsigned int wireType = (unsigned int)(key & 0x7);

        if (fieldNumber == 1 && wireType == 2) {
            const uint8_t *folderBytes = NULL;
            NSUInteger folderLength = 0;
            if (!DCProtoReadLengthDelimited(&layout, &folderBytes, &folderLength)) return NO;
            DCGuildFolder *folder = DCDecodeGuildFolderProto(folderBytes, folderLength);
            if (!folder) return NO;

            [folders addObject:folder];
            // Modern Discord includes ungrouped guilds as anonymous folders,
            // so flattening this repeated list is the authoritative sidebar
            // order and also preserves order inside named folders.
            [positions addObjectsFromArray:folder.guildIds];
            continue;
        } else if (fieldNumber == 2 && wireType == 2) {
            // Deprecated guild_positions. Keep only as a fallback for an older
            // payload that somehow omits the modern folders list.
            const uint8_t *packed = NULL;
            NSUInteger packedLength = 0;
            if (!DCProtoReadLengthDelimited(&layout, &packed, &packedLength)) return NO;
            if ((packedLength % 8) != 0) return NO;
            for (NSUInteger i = 0; i < packedLength; i += 8) {
                unsigned long long guildID = (unsigned long long)DCProtoReadLittleEndian64(packed + i);
                [deprecatedPositions addObject:[NSString stringWithFormat:@"%llu", guildID]];
            }
            continue;
        }

        if (!DCProtoSkipField(&layout, wireType)) return NO;
    }

    if (folders.count == 0 && deprecatedPositions.count) {
        [positions addObjectsFromArray:deprecatedPositions];
    }

    if (positionsOut) *positionsOut = positions;
    if (foldersOut) *foldersOut = folders;
    return YES;
}


// Header for push requests. Critical for keeping Discord servers happy. Thanks JWI!
+ (NSString *)superPropertiesBase64 {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:[self superProperties] options:0 error:&err];
    if (!json) return @"";
    return [json base64Encoding];
}

+ (NSDictionary *)superProperties {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *arch = [NSString stringWithCString:systemInfo.machine
                                        encoding:NSUTF8StringEncoding] ?: @"armv7";
    NSString *osVersion = [[UIDevice currentDevice] systemVersion];
    NSString *vendorID = @"";
    if ([[UIDevice currentDevice] respondsToSelector:@selector(identifierForVendor)]) {
        vendorID = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"";
    } else {
        // iOS 5 fallback — generate and persist our own vendor ID
        vendorID = [[NSUserDefaults standardUserDefaults] stringForKey:@"DCVendorID"];
        if (!vendorID) {
            CFUUIDRef uuid = CFUUIDCreate(NULL);
            vendorID = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
            CFRelease(uuid);
            [[NSUserDefaults standardUserDefaults] setObject:vendorID forKey:@"DCVendorID"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    }
    return @{
        @"os"                  : @"iOS",
        @"browser"             : @"Discord iOS",
        @"device"              : arch,
        @"system_locale"       : @"en-US",
        @"client_version"      : @"0.0.326",
        @"release_channel"     : @"stable",
        @"device_vendor_id"    : vendorID,
        @"browser_user_agent"  : @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.326 Chrome/128.0.6613.186 Electron/32.2.2 Safari/537.36",
        @"browser_version"     : @"32.2.2",
        @"os_version"          : osVersion,
        @"os_arch"             : arch,
        @"app_arch"            : arch,
        @"os_sdk_version"      : @"23",
        @"client_build_number" : @209354,
        @"native_build_number" : [NSNull null],
        @"client_event_source" : [NSNull null],
    };
}

+ (NSMutableURLRequest *)requestWithPath:(NSString *)path token:(NSString *)token {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://discordapp.com/api/v9%@", path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:[self superPropertiesBase64] forHTTPHeaderField:@"X-Super-Properties"];
    [req setValue:@"en-US" forHTTPHeaderField:@"x-discord-locale"];
    [req setValue:@"https://discord.com/channels/@me" forHTTPHeaderField:@"Referrer"];
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    if (token.length > 0) {
        [req setValue:token forHTTPHeaderField:@"Authorization"];
    }
    return req;
}

- (void)registerPushToken:(NSString *)token {
    NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:@"/users/@me/devices" 
                                                                   token:self.token];
    request.HTTPMethod = @"POST";
    
    NSDictionary *body = @{
        @"provider": @"apns",
        @"token": token
    };
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body 
                                                       options:0 
                                                         error:nil];
    
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, 
                                               NSData *data, 
                                               NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSLog(@"Push token registration status: %ld", (long)http.statusCode);
        if (error) {
            NSLog(@"Push token registration error: %@", error.localizedDescription);
        }
        if (data) {
            NSString *responseBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"Push token registration response: %@", responseBody);
        }
    }];
}

+ (DCServerCommunicator *)sharedInstance {
    static DCServerCommunicator *sharedInstance = nil;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        DBGLOG(@"[DCServerCommunicator] Creating shared instance");
        sharedInstance = [[self alloc] init];
        sharedInstance.accessQueue = dispatch_queue_create(
            "Discord::Data::Access", DISPATCH_QUEUE_CONCURRENT);

        // Initialize if a sharedInstance does not yet exist

        sharedInstance.gatewayURL      = @"wss://gateway.discord.gg/?encoding=json&v=9&compress=zlib-stream";
        sharedInstance.oldMode         = [[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"];
        sharedInstance.dataSaver       = [[NSUserDefaults standardUserDefaults] boolForKey:@"dataSaver"];
        sharedInstance.token           = [[NSUserDefaults standardUserDefaults] stringForKey:@"token"];
        sharedInstance.currentUserInfo = nil;

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        
        [NSNotificationCenter.defaultCenter addObserver:sharedInstance
                                               selector:@selector(handleBackgroundEntry)
                                                   name:UIApplicationDidEnterBackgroundNotification
                                                 object:nil];

        [NSNotificationCenter.defaultCenter addObserver:sharedInstance
                                               selector:@selector(handleForegroundEntry)
                                                   name:UIApplicationWillEnterForegroundNotification
                                                 object:nil];

        if ([sharedInstance.token length] == 0) {
            return;
        }

        if (sharedInstance.oldMode == YES) {
            sharedInstance.alertView = [[UIAlertView alloc] initWithTitle:@"Connecting"
                                                                message:@"\n"
                                                               delegate:self
                                                      cancelButtonTitle:nil
                                                      otherButtonTitles:nil];

            UIActivityIndicatorView *spinner = [UIActivityIndicatorView.alloc initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
            [spinner setCenter:CGPointMake(139.5, 75.5)];

            [sharedInstance.alertView addSubview:spinner];
            [spinner startAnimating];
        } else {
            [sharedInstance showNonIntrusiveNotificationWithTitle:@"Connecting..."];
        }
    });

    return sharedInstance;
}

// Accessor Methods for thread safe data interactions
- (DCUser *)userForSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    __block DCUser *user;
    dispatch_sync(self.accessQueue, ^{
        user = self.loadedUsers[snowflake];
    });
    return user;
}

- (void)setUser:(DCUser *)user forSnowflake:(NSString *)snowflake {
    if (!snowflake || !user) return;
    dispatch_barrier_async(self.accessQueue, ^{
        self.loadedUsers[snowflake] = user;
    });
}

- (NSDictionary *)loadedUsersSnapshot {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(self.accessQueue, ^{
        snapshot = [NSDictionary dictionaryWithDictionary:self.loadedUsers ?: @{}];
    });
    return snapshot;
}

- (void)mergeCachedUsers:(NSDictionary *)cachedUsers {
    if (![cachedUsers isKindOfClass:[NSDictionary class]] || cachedUsers.count == 0)
        return;

    /*
     * Cold-start user hydration is deliberately late now.  Merge the disk
     * snapshot conservatively so live Gateway data always wins, while cached
     * data can still fill placeholders created by a restored message window.
     */
    NSMutableArray *changedPlaceholders = [NSMutableArray array];
    dispatch_barrier_sync(self.accessQueue, ^{
        if (!self.loadedUsers)
            self.loadedUsers = [NSMutableDictionary dictionary];

        for (NSString *snowflake in cachedUsers) {
            DCUser *cached = [cachedUsers objectForKey:snowflake];
            if (![cached isKindOfClass:[DCUser class]] || !snowflake.length)
                continue;

            DCUser *existing = [self.loadedUsers objectForKey:snowflake];
            if (!existing) {
                [self.loadedUsers setObject:cached forKey:snowflake];
                continue;
            }

            BOOL changed = NO;
            BOOL placeholderName =
                !existing.username.length ||
                [existing.username isEqualToString:@"Unknown User"];
            BOOL placeholderGlobalName =
                !existing.globalName.length ||
                [existing.globalName isEqualToString:@"Unknown User"];

            if (placeholderName && cached.username.length) {
                existing.username = cached.username;
                changed = YES;
            }
            if (placeholderGlobalName && cached.globalName.length) {
                existing.globalName = cached.globalName;
                changed = YES;
            }
            if (!existing.avatarID && cached.avatarID) {
                existing.avatarID = cached.avatarID;
                /*
                 * A placeholder may already have generated a default avatar
                 * before late hydration supplied the real hash.  Clear that
                 * runtime image so the next visible-cell request uses the real
                 * hash-versioned CDN asset instead of keeping the placeholder.
                 */
                existing.profileImage = nil;
                existing.rawProfileImage = nil;
                changed = YES;
            }
            if (!existing.avatarDecorationID && cached.avatarDecorationID) {
                existing.avatarDecorationID = cached.avatarDecorationID;
                existing.avatarDecoration = nil;
                existing.profileImage = nil;
                changed = YES;
            }
            if (!existing.biography.length && cached.biography.length)
                existing.biography = cached.biography;
            if (existing.discriminator == 0 && cached.discriminator != 0)
                existing.discriminator = cached.discriminator;

            if (!existing.guildNicknames)
                existing.guildNicknames = [NSMutableDictionary dictionary];
            for (NSString *guildID in cached.guildNicknames) {
                if (![existing.guildNicknames objectForKey:guildID]) {
                    id nickname = [cached.guildNicknames objectForKey:guildID];
                    if (nickname)
                        [existing.guildNicknames setObject:nickname forKey:guildID];
                }
            }

            if (changed) [changedPlaceholders addObject:existing];
        }
    });

    if (changedPlaceholders.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (DCUser *user in changedPlaceholders) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD USER DATA"
                                  object:user];
            }
        });
    }
}

- (void)requestMemberChunkForUserIds:(NSArray *)userIds
                             inGuild:(NSString *)guildId {
    if (!userIds.count || !guildId) return;
    // Discord caps user_ids at 100 per request
    NSArray *batch = userIds.count > 100
        ? [userIds subarrayWithRange:NSMakeRange(0, 100)]
        : userIds;
    [self sendJSON:@{
        @"op": @(8),
        @"d": @{
            @"guild_id": guildId,
            @"user_ids": batch,
            @"limit":    @0,
            @"presences": @NO
        }
    }];
}

- (DCRole *)roleForSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    __block DCRole *role;
    dispatch_sync(self.accessQueue, ^{
        role = self.loadedRoles[snowflake];
    });
    return role;
}

- (void)setRole:(DCRole *)role forSnowflake:(NSString *)snowflake {
    if (!snowflake || !role) return;
    dispatch_barrier_async(self.accessQueue, ^{
        self.loadedRoles[snowflake] = role;
    });
}

- (DCEmoji *)emojiForSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    __block DCEmoji *emoji;
    dispatch_sync(self.accessQueue, ^{
        emoji = self.loadedEmojis[snowflake];
    });
    return emoji;
}

- (void)setEmoji:(DCEmoji *)emoji forSnowflake:(NSString *)snowflake {
    if (!snowflake || !emoji) return;
    dispatch_barrier_async(self.accessQueue, ^{
        // Cached chats can parse custom emoji before IDENTIFY creates the
        // normal READY-era registry.  NSMutableDictionary messaging to nil is
        // a silent no-op, so lazily create the canonical store on first write.
        if (!self.loadedEmojis) self.loadedEmojis = NSMutableDictionary.new;
        self.loadedEmojis[snowflake] = emoji;
    });
}

// this no longer sucks

- (void)showNonIntrusiveNotificationWithTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat screenWidth        = UIScreen.mainScreen.bounds.size.width;
        CGFloat minimumPadding     = 0;   // Minimum padding threshold
        CGFloat maxPadding         = 120; // Maximum padding
        CGFloat notificationHeight = 50;

        // Calculate title width for iOS 6 compatibility
        CGSize titleSize   = [title sizeWithFont:[UIFont boldSystemFontOfSize:16]];
        CGFloat titleWidth = titleSize.width;

        // Calculate dynamic padding - decrease padding as title gets longer, up to minimumPadding
        CGFloat dynamicPadding    = MAX(minimumPadding, maxPadding - (titleWidth / screenWidth) * (maxPadding - minimumPadding));
        dynamicPadding            = MAX(40, dynamicPadding);
        CGFloat notificationWidth = screenWidth - (dynamicPadding * 2);
        CGFloat notificationX     = dynamicPadding;
        CGFloat notificationY     = -notificationHeight;

        if (self.notificationView != nil) {
            [self.notificationView removeFromSuperview];
            self.notificationView = nil;
        }

        self.notificationView = [[UIView alloc] initWithFrame:CGRectMake(notificationX, notificationY, notificationWidth, notificationHeight)];

        // Create a container view for masking and rounding
        UIView *maskView             = [[UIView alloc] initWithFrame:self.notificationView.bounds];
        maskView.backgroundColor     = [UIColor colorWithPatternImage:[UIImage imageNamed:@"No-header"]];
        maskView.layer.cornerRadius  = 15;
        maskView.layer.masksToBounds = YES; // Important: Masking the view to fix corner clipping

        [self.notificationView addSubview:maskView];
        [self.notificationView sendSubviewToBack:maskView];

        self.notificationView.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.notificationView.layer.shadowOffset  = CGSizeMake(0, 2);
        self.notificationView.layer.shadowOpacity = 0.6;
        self.notificationView.layer.shadowRadius  = 5;
        self.notificationView.layer.borderColor   = [UIColor darkGrayColor].CGColor;
        self.notificationView.layer.borderWidth   = 1.0;
        self.notificationView.layer.cornerRadius  = 15;

        CGFloat spinnerWidth  = 30;
        CGFloat labelWidth    = notificationWidth - spinnerWidth - 10; // Reduce space between label and spinner
        UILabel *label        = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, labelWidth, notificationHeight)];
        label.text            = title;
        label.backgroundColor = [UIColor clearColor];
        label.textColor       = [UIColor colorWithRed:168 / 255.0 green:168 / 255.0 blue:168 / 255.0 alpha:1];
        label.font            = [UIFont boldSystemFontOfSize:16];
        label.textAlignment   = (NSTextAlignment)UITextAlignmentLeft;
        label.lineBreakMode   = NSLineBreakByTruncatingTail;
        label.shadowColor     = [UIColor colorWithRed:0 / 255.0 green:0 / 255.0 blue:0 / 255.0 alpha:1];
        label.shadowOffset    = CGSizeMake(0, 1);

        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        spinner.center                   = CGPointMake(notificationWidth - (spinnerWidth / 2) - 5, notificationHeight / 2); // Adjust spinner closer to text
        [spinner startAnimating];

        [self.notificationView addSubview:label];
        [self.notificationView addSubview:spinner];

        UIWindow *window = [[[UIApplication sharedApplication] windows] lastObject];
        [window addSubview:self.notificationView];

        [UIView animateWithDuration:0.6
                         animations:^{
                             self.notificationView.frame = CGRectMake(notificationX, 64, notificationWidth, notificationHeight);
                         }];
    });
}

- (void)dismissNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Animate out
        [UIView animateWithDuration:0.4
            animations:^{
                CGRect frame                = self.notificationView.frame;
                frame.origin.y              = -frame.size.height; // Move off-screen
                self.notificationView.frame = frame;
            }
            completion:^(BOOL finished) {
                [self.notificationView removeFromSuperview];
                self.notificationView = nil;
            }];
    });
}


- (DCChannel *)findChannelById:(NSString *)channelId {
    for (DCGuild *guild in self.guilds) { // Replace `self.guilds` with your guilds array
        for (DCChannel *channel in guild.channels) {
            if ([channel.snowflake isEqualToString:channelId]) {
                return channel;
            }
        }
    }
    return nil;
}

#pragma mark - Discord Event Handlers

- (void)handleReadyWithData:(NSDictionary *)d {
    self.didAuthenticate = true;
    self.reconnectAttempts = 0;
    DBGLOG(@"Did authenticate!");
    if (self.oldMode == NO) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showNonIntrusiveNotificationWithTitle:@"Getting Ready..."];
        });
    }
    // Grab session state used for RESUME. Discord requires reconnects to use
    // resume_gateway_url rather than the generic Gateway hostname.
    self.sessionId = [NSString stringWithFormat:@"%@", [d valueForKeyPath:@"session_id"]];

    id resumeGatewayURL = [d objectForKey:@"resume_gateway_url"];
    if ([resumeGatewayURL isKindOfClass:[NSString class]] &&
        [(NSString *)resumeGatewayURL length] > 0) {
        self.resumeGatewayURL = (NSString *)resumeGatewayURL;
        DBGLOG(@"Cached resume gateway URL: %@", self.resumeGatewayURL);
    } else {
        self.resumeGatewayURL = nil;
        DBGLOG(@"READY did not contain a usable resume_gateway_url");
    }
    // THIS IS US, hey hey hey this is MEEEEE BITCCCH MORTY DID YOU HEAR, THIS IS ME, AND MY USER ID, YES MORT(BUÜÜÜRPP)Y, THIS IS ME. BITCCHHHH. 100 YEARS OF DISCORD CLASSIC MORTYY YOU AND MEEEE
    self.snowflake       = [NSString stringWithFormat:@"%@", [d valueForKeyPath:@"user.id"]];
    DCUserInfo *userInfo = [DCUserInfo new];
    userInfo.username    = [d valueForKeyPath:@"user.username"];
    if ([[d valueForKeyPath:@"user.global_name"] isKindOfClass:[NSNull class]]) {
        userInfo.globalName = [d valueForKeyPath:@"user.username"];
    } else {
        userInfo.globalName = [d valueForKeyPath:@"user.global_name"];
    }
    userInfo.pronouns          = [d valueForKeyPath:@"user.pronouns"];
    userInfo.avatar            = [d valueForKeyPath:@"user.avatar"];
    userInfo.phone             = [d valueForKeyPath:@"user.phone"];
    userInfo.email             = [d valueForKeyPath:@"user.email"];
    userInfo.bio               = [d valueForKeyPath:@"user.bio"];
    userInfo.banner            = [d valueForKeyPath:@"user.banner"];
    userInfo.bannerColor       = [d valueForKeyPath:@"user.banner_color"];
    userInfo.clan              = [d valueForKeyPath:@"user.clan"];
    userInfo.id                = [d valueForKeyPath:@"user.id"];
    userInfo.connectedAccounts = [d valueForKeyPath:@"connected_accounts"];
    self.currentUserInfo       = userInfo;
    self.userChannelSettings   = NSMutableDictionary.new;
    for (NSDictionary *guildSettings in [d objectForKey:@"user_guild_settings"]) {
        for (NSDictionary *channelSetting in [guildSettings objectForKey:@"channel_overrides"]) {
            [self.userChannelSettings setValue:@([[channelSetting objectForKey:@"muted"] boolValue])
                                        forKey:[channelSetting objectForKey:@"channel_id"]];
        }
    }
    // NSLog(@"[MuteCheck] userChannelSettings: %@", self.userChannelSettings);
    // Get users from READY payload (DEDUPE_USER_OBJECTS)
    [self setUser:[DCTools convertJsonUser:[d objectForKey:@"user"] cache:YES]
     forSnowflake:[d valueForKeyPath:@"user.id"]];
    for (NSDictionary *user in [d objectForKey:@"users"]) {
        @autoreleasepool {
            DCUser *dcUser = [DCTools convertJsonUser:user cache:YES];
            if (dcUser) {
                [self setUser:dcUser forSnowflake:dcUser.snowflake];
                // NSLog(@"[READY] Cached user: %@ (ID: %@)", dcUser.username, dcUser.snowflake);
            } else {
                DBGLOG(@"[READY] Failed to convert user: %@", user);
            }
        }
    }

    // Get user DMs and DM groups
    // The user's DMs are treated like a guild, where the channels are different DM/groups
    DCGuild *privateGuild = DCGuild.new;
    privateGuild.name     = @"Direct Messages";
    if (self.oldMode == NO) {
        privateGuild.icon = [UIImage imageNamed:@"privateGuildLogo"];
    }
    privateGuild.channels  = NSMutableArray.new;
    privateGuild.snowflake = nil;
    for (NSDictionary *privateChannel in [d objectForKey:@"private_channels"]) {
        @autoreleasepool {
            // this may actually suck
            // NSLog(@"%@", privateChannel);
            DCChannel *newChannel    = DCChannel.new;
            id privateParentID       = [privateChannel objectForKey:@"parent_id"];
            newChannel.parentID      = [privateParentID isKindOfClass:[NSString class]] ? privateParentID : nil;
            newChannel.snowflake     = [privateChannel objectForKey:@"id"];
            newChannel.lastMessageId = [privateChannel objectForKey:@"last_message_id"];
            newChannel.parentGuild   = privateGuild;
            id privateChannelType = [privateChannel objectForKey:@"type"];
            newChannel.type          = [privateChannelType respondsToSelector:@selector(integerValue)]
                ? (DCChannelType)[privateChannelType integerValue]
                : DCChannelTypeDM;
            newChannel.writeable     = YES;             // DMs are always writeable
            newChannel.recipients    = NSMutableArray.new;
            { // default icon
                NSNumber *longId = @([newChannel.snowflake longLongValue]);
                int selector     = (int)(([longId longLongValue] >> 22) % 6);
                newChannel.icon  = [DCContentManager processedIcon:[[DCUser defaultAvatars] objectAtIndex:selector] context:DCAssetContextList];
            }
            NSArray *recipientIds = [privateChannel objectForKey:@"recipient_ids"];
            if ([recipientIds isKindOfClass:[NSArray class]]) {
                newChannel.recipientIDs = [NSArray arrayWithArray:recipientIds];
            }
            id privateChannelIcon = [privateChannel objectForKey:@"icon"];
            if ([privateChannelIcon isKindOfClass:[NSString class]] &&
                [(NSString *)privateChannelIcon length] > 0) {
                newChannel.iconID = privateChannelIcon;
            }
            if ([recipientIds isKindOfClass:[NSArray class]] && recipientIds.count > 0) {
                for (NSString *userId in recipientIds) {
                    DCUser *recipient = [self userForSnowflake:userId];
                    if (!recipient) {
                        NSLog(@"[READY] Missing recipient %@ for channel %@", userId, newChannel.snowflake);
                        // DBGLOG(@"[READY] User ID %@ not found in loadedUsers", userId);
                        continue;
                    }
                    [newChannel.recipients addObject:recipient];
                }
                NSMutableArray *mUsers = [newChannel.recipients mutableCopy];
                [mUsers addObject:[self userForSnowflake:self.snowflake]];
                newChannel.users = mUsers;
            }
            if (newChannel.iconID.length > 0) {
                NSURL *iconURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.discordapp.com/channel-icons/%@/%@.png?size=64",
                    newChannel.snowflake, newChannel.iconID]];
                SDWebImageManager *manager = [SDWebImageManager sharedManager];
                [manager downloadImageWithURL:iconURL
                                      options:0
                                     progress:nil
                                    completed:^(UIImage *icon, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                        @autoreleasepool {
                                            if (!icon || !finished) {
                                                NSLog(@"Failed to load channel icon with URL %@: %@", iconURL, error);
                                                return;
                                            }
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                newChannel.icon = [DCContentManager processedIcon:icon context:DCAssetContextList];
                                                [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST" object:nil];
                                            });
                                        }
                                    }];
            } else {
                if (newChannel.recipients.count > 0) {
                    NSInteger channelType = newChannel.type;
                    if (channelType == DCChannelTypeDM) {
                        // 1-on-1 DM — use buddy's avatar via getUserAvatar:
                        DCUser *user = [newChannel.recipients objectAtIndex:0];
                        [DCTools getUserAvatar:user];
                    } else {
                        // Group DM — download and process first recipient's avatar as icon
                        DCUser *user = [newChannel.recipients objectAtIndex:0];
                        NSURL *avatarURL = [NSURL URLWithString:[NSString stringWithFormat:
                            @"https://cdn.discordapp.com/avatars/%@/%@.png?size=64",
                            user.snowflake, user.avatarID]];
                        SDWebImageManager *manager = [SDWebImageManager sharedManager];
                        [manager downloadImageWithURL:avatarURL
                                              options:0
                                             progress:nil
                                            completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                                @autoreleasepool {
                                                    if (image && finished) {
                                                        dispatch_async(dispatch_get_main_queue(), ^{
                                                            newChannel.icon = [DCContentManager processedIcon:image context:DCAssetContextList];
                                                            [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST" object:nil];
                                                        });
                                                    } else {
                                                        int selector = 0;
                                                        NSNumber *discriminator = @(user.discriminator);
                                                        if ([discriminator integerValue] == 0) {
                                                            NSNumber *longId = @([user.snowflake longLongValue]);
                                                            selector = (int)(([longId longLongValue] >> 22) % 6);
                                                        } else {
                                                            selector = (int)([discriminator integerValue] % 5);
                                                        }
                                                        dispatch_async(dispatch_get_main_queue(), ^{
                                                            newChannel.icon = [DCContentManager processedIcon:[[DCUser defaultAvatars] objectAtIndex:selector] context:DCAssetContextList];
                                                            [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST" object:nil];
                                                        });
                                                    }
                                                }
                                            }];
                    }
                }
            }
            NSString *privateChannelName = [privateChannel objectForKey:@"name"];
            // Some private channels dont have names, check if nil
            if (privateChannelName && (NSNull *)privateChannelName != [NSNull null]) {
                newChannel.name = privateChannelName;
            } else {
                // If no name, create a name from channel members
                NSMutableString *fullChannelName = [@"" mutableCopy];
                for (DCUser *recipient in newChannel.recipients) {
                    @autoreleasepool {
                        // add comma between member names
                        if ([newChannel.recipients indexOfObject:recipient] != 0) {
                            [fullChannelName appendString:@", "];
                        }
                        NSString *memberName = [recipient displayName];
                        if (recipient.globalName && [recipient.globalName isKindOfClass:[NSString class]]) {
                            memberName = recipient.globalName;
                        }
                        if (memberName) {
                            [fullChannelName appendString:memberName];
                        }
                        newChannel.name = fullChannelName;
                    }
                }
            }
            [privateGuild.channels addObject:newChannel];
        }
    }

    // Parse friend nicknames from relationships
    NSArray *relationships = [d objectForKey:@"relationships"];
    for (NSDictionary *relationship in relationships) {
        NSString *friendNick = [relationship objectForKey:@"nickname"];
        NSString *userId = [relationship valueForKeyPath:@"id"];
        // NSLog(@"[Relationships] userId:%@ nick:%@", userId, friendNick);
        if (!friendNick || (NSNull *)friendNick == [NSNull null] || friendNick.length == 0) {
            continue;
        }
        DCUser *user = [self userForSnowflake:userId];
        // NSLog(@"[Relationships] found user:%@ setting nick:%@", user.username, friendNick);
        if (!user) {
            user = [DCTools convertJsonUser:[relationship objectForKey:@"user"] cache:YES];
            [self setUser:user forSnowflake:userId];
        }
        user.globalName = friendNick;
    }

    // Process user presences from READY payload (DEDUPE_USER_OBJECTS)
    NSDictionary *merged_presences = [d objectForKey:@"merged_presences"];
    NSMutableArray *presences      = NSMutableArray.new;
    for (NSDictionary *presence in merged_presences[@"friends"]) {
        @autoreleasepool {
            [presences addObject:presence];
        }
    }
    for (NSArray *guildPresences in merged_presences[@"guilds"]) {
        @autoreleasepool {
            for (NSDictionary *presence in guildPresences) {
                @autoreleasepool {
                    [presences addObject:presence];
                }
            }
        }
    }
    for (NSDictionary *presence in presences) {
        NSString *userId = [presence objectForKey:@"user_id"];
        NSString *status = [presence objectForKey:@"status"];
        if (!userId || !status) {
            continue;
        }
        DCUser *user = [self userForSnowflake:userId];
        if (!user) {
            DBGLOG(@"[READY] User ID %@ not found in loadedUsers", userId);
            continue;
        }
        user.status = [DCUser statusFromString:status];
        // NSLog(@"[READY] User %@ (ID: %@) has status: %@ (%ld)", user.username, userId, status, (long)user.status);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST" object:nil];
    });

    // Refresh DM channel names with updated friend nicknames
    NSArray *channelSnapshot = [privateGuild.channels copy];
    for (DCChannel *channel in channelSnapshot) {
        if (channel.recipients.count == 1) {
            DCUser *recipient = channel.recipients.firstObject;
            channel.name = [recipient displayName];
        } else if (channel.recipients.count > 1) {
            if (!channel.name || channel.name.length == 0) {
                NSMutableString *fullChannelName = [@"" mutableCopy];
                NSArray *recipientSnapshot = [channel.recipients copy];
                for (DCUser *recipient in recipientSnapshot) {
                    if ([recipientSnapshot indexOfObject:recipient] != 0) {
                        [fullChannelName appendString:@", "];
                    }
                    [fullChannelName appendString:[recipient displayName]];
                }
                if (fullChannelName.length > 0) {
                    channel.name = fullChannelName;
                }
            }
        }
    }

    // Sort the DMs list by most recent...
    [privateGuild.channels sortUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
        NSString *idA = ([a.lastMessageId isKindOfClass:[NSString class]]) ? a.lastMessageId : @"0";
        NSString *idB = ([b.lastMessageId isKindOfClass:[NSString class]]) ? b.lastMessageId : @"0";
        return [idB localizedStandardCompare:idA]; // descending
    }];
    NSMutableDictionary *channelsDict = NSMutableDictionary.new;
    for (DCChannel *channel in privateGuild.channels) {
        [channelsDict setObject:channel forKey:channel.snowflake];
    }
    self.channels          = channelsDict;
    NSMutableArray *guilds = NSMutableArray.new;
    [guilds addObject:privateGuild];
    // Get servers (guilds) the user is a member of
    NSArray *mergedMembers = [d objectForKey:@"merged_members"];
    NSArray *guildJsons    = [d objectForKey:@"guilds"];
    for (NSUInteger i = 0; i < guildJsons.count; i++) {
        @autoreleasepool {
            DCGuild *guild = [DCTools convertJsonGuild:[guildJsons objectAtIndex:i]
                                           withMembers:[mergedMembers objectAtIndex:i]];
            [guilds addObject:guild];
        }
    }
    userInfo.guildPositions = NSMutableArray.new;
    if ([d valueForKeyPath:@"user_settings.guild_positions"]) {
        [userInfo.guildPositions addObjectsFromArray:[d valueForKeyPath:@"user_settings.guild_positions"]];
    } else if ([d valueForKeyPath:@"user_settings.guild_folders"]) {
        userInfo.guildFolders = NSMutableArray.new;
        for (NSDictionary *userDict in [d valueForKeyPath:@"user_settings.guild_folders"]) {
            @autoreleasepool {
                DCGuildFolder *folder    = [DCGuildFolder new];
                folder.id                = [userDict objectForKey:@"id"] != [NSNull null] ? [[userDict objectForKey:@"id"] intValue] : 0;
                folder.name              = [userDict objectForKey:@"name"];
                folder.color             = [userDict objectForKey:@"color"] != [NSNull null] ? [[userDict objectForKey:@"color"] intValue] : 0;
                NSMutableArray *guildIds = [[userDict objectForKey:@"guild_ids"] mutableCopy];
                // below code required for deleted but not updated guilds
                for (NSUInteger i = guildIds.count - 1; i > 0; i--) {
                    NSString *guildId = [guildIds objectAtIndex:i];
                    if ([guilds indexOfObjectPassingTest:
                                    ^BOOL(DCGuild *guild, NSUInteger idx, BOOL *stop) {
                                        return [guild.snowflake isEqualToString:guildId];
                                    }]
                        == NSNotFound) {
                        DBGLOG(@"[READY] Guild ID %@ not found in guilds array!", guildId);
                        [guildIds removeObjectAtIndex:i];
                    }
                }
                folder.guildIds  = guildIds;
                NSNumber *opened = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:[@(folder.id) stringValue]] objectForKey:@"opened"];
                folder.opened    = opened != nil ? [opened boolValue] : YES; // default to opened
                [userInfo.guildFolders addObject:folder];
                [userInfo.guildPositions addObjectsFromArray:folder.guildIds];
            }
        }
    } else {
        NSLog(@"no guild positions found in user settings");
    }
    for (NSDictionary *guildSettings in [d objectForKey:@"user_guild_settings"]) {
        NSString *guildId = [guildSettings objectForKey:@"guild_id"];
        if ((NSNull *)guildId == [NSNull null]) {
            ((DCGuild *)[guilds objectAtIndex:0]).muted = [[guildSettings objectForKey:@"muted"] boolValue];
            continue;
        }
        for (DCGuild *guild in guilds) {
            if ([guild.snowflake isEqualToString:guildId]) {
                guild.muted = [[guildSettings objectForKey:@"muted"] boolValue];
                // NSLog(@"[MuteCheck] guild: %@ muted: %d", guild.name, guild.muted);
                break;
            }
        }
    }
    self.guilds         = guilds;
    self.guildsIsSorted = NO;
    // Read states are recieved in READY payload
    // they give a channel ID and the ID of the last read message in that channel
    NSArray *readstatesArray = [d objectForKey:@"read_state"];
    // NSLog(@"[ReadState] array: %@", [d objectForKey:@"read_state"]);
    for (NSDictionary *readstate in readstatesArray) {
        NSString *readstateChannelId = [readstate objectForKey:@"id"];
        NSString *readstateMessageId = [readstate objectForKey:@"last_message_id"];
        NSInteger mentionCount = [[readstate objectForKey:@"mention_count"] integerValue];
        DCChannel *channelOfReadstate = [self.channels objectForKey:readstateChannelId];
        channelOfReadstate.lastReadMessageId = readstateMessageId;
        channelOfReadstate.mentionCount = mentionCount;
        // NSLog(@"[ReadState] channel:%@ lastMessageId:%@ lastReadMessageId:%@ muted:%d", 
        //         channelOfReadstate.name,
        //         channelOfReadstate.lastMessageId,
        //         channelOfReadstate.lastReadMessageId,
        //         channelOfReadstate.muted);
        [channelOfReadstate checkIfRead];
        // NSLog(@"[ReadState] channel:%@ id:%@ mentionCount:%ld lastMessageId:%@ lastReadMessageId:%@",
        //     channelOfReadstate.name,
        //     channelOfReadstate.snowflake,
        //     (long)channelOfReadstate.mentionCount,
        //     channelOfReadstate.lastMessageId,
        //     channelOfReadstate.lastReadMessageId);
    }
    // Wire up channel mute state from userChannelSettings
    for (DCGuild *guild in self.guilds) {
        for (DCChannel *channel in guild.channels) {
            NSNumber *muteValue = self.userChannelSettings[channel.snowflake];
            if (muteValue) {
                channel.muted = [muteValue boolValue];
            }
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"MENTION_COUNT_UPDATED" object:nil];
    });
    // Re-resolve selectedChannel from fresh READY data and re-subscribe
    if (self.selectedChannel) {
        NSString *channelSnowflake = self.selectedChannel.snowflake;
        DCChannel *freshChannel = [self.channels objectForKey:channelSnowflake];
        if (freshChannel && freshChannel.parentGuild) {
            self.selectedChannel = freshChannel;
            [self sendGuildSubscriptionWithGuildId:freshChannel.parentGuild.snowflake
                                         channelId:freshChannel.snowflake];
            DBGLOG(@"[READY] Re-subscribed to channel %@ after reconnect", channelSnowflake);
        }
    }
    // Persist guild/channel structure for cold-start cache
        [[DCCacheManager sharedInstance] saveGuilds:self.guilds];
        [[DCCacheManager sharedInstance] saveUserInfo:self.currentUserInfo];
        [[DCCacheManager sharedInstance] saveUsers:[self loadedUsersSnapshot]];

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"READY" object:self];
            // Dismiss the 'reconnecting' dialogue box
            [self.alertView dismissWithClickedButtonIndex:0 animated:YES];
            [self dismissNotification];
        });
}

- (void)handlePresenceUpdateEventWithData:(NSDictionary *)d {
    @autoreleasepool {
        NSString *userId = [d valueForKeyPath:@"user.id"];
        NSString *status = [d objectForKey:@"status"];
        if (!userId || !status) {
            return;
        }

        NSDictionary *userDict = [d objectForKey:@"user"];
        DCUser *user = nil;
        if ([userDict isKindOfClass:[NSDictionary class]]) {
            // PRESENCE_UPDATE can carry partial identity changes (including
            // avatar/name changes). Merge them into the canonical user rather
            // than ignoring the payload just because the user already exists.
            user = [DCTools convertJsonUser:userDict cache:YES];
        }
        if (!user) user = [self userForSnowflake:userId];
        if (!user) return;

        user.status = [DCUser statusFromString:status];

        // Presence itself is ephemeral. Identity fields in this payload are
        // merged immediately in RAM and will be checkpointed by the normal
        // READY/background cache flush rather than rewriting the whole user
        // archive for every presence event.

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"USER_PRESENCE_UPDATED"
                              object:user];
        });
    }
}

- (void)handleMessageCreateWithData:(NSDictionary *)d {
    @autoreleasepool {
        NSString *channelIdOfMessage = [d objectForKey:@"channel_id"];
        NSString *messageId          = [d objectForKey:@"id"];
        // Check if a channel is currently being viewed
        // and if so, if that channel is the same the message was sent in
        if (self.selectedChannel != nil && [channelIdOfMessage isEqualToString:self.selectedChannel.snowflake]) {
            // NSLog(@"[MESSAGE_CREATE] Message received in currently selected channel: %@", self.selectedChannel.name);
            dispatch_async(dispatch_get_main_queue(), ^{
                // Send notification with the new message
                // will be recieved by DCChatViewController
                [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE CREATE" object:self userInfo:d];
                // Also notify menu to update DM list position/unread state
                [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE ACK"
                                                                  object:self
                                                                userInfo:@{@"channelId": channelIdOfMessage}];
            }); // Update current channel & read state last message
            [self.selectedChannel setLastMessageId:messageId];
            // Ack message since we are currently viewing this channel
            [self.selectedChannel ackMessage:messageId];
        } else {
            DCChannel *channelOfMessage = [self.channels objectForKey:channelIdOfMessage];
            // NSLog(@"[MESSAGE_CREATE] Message received in channel %@ (ID: %@) not currently selected", channelOfMessage.name, channelIdOfMessage);
            channelOfMessage.lastMessageId = messageId;
            
            // Don't mark as unread if we sent the message
            NSString *authorId = [d valueForKeyPath:@"author.id"];
            if (![authorId isEqualToString:self.snowflake]) {
                // Increment mention count for DMs
                if (channelOfMessage.type == 1 || channelOfMessage.type == 3) {
                    channelOfMessage.mentionCount += 1;
                } else {
                    // Check for mentions in guild channels
                    BOOL mentionEveryone = [[d objectForKey:@"mention_everyone"] boolValue];
                    
                    // Check for direct user mention
                    BOOL mentionedDirectly = NO;
                    NSArray *mentions = [d objectForKey:@"mentions"];
                    for (NSDictionary *user in mentions) {
                        if ([[user objectForKey:@"id"] isEqualToString:self.snowflake]) {
                            mentionedDirectly = YES;
                            break;
                        }
                    }
                    
                    if (mentionedDirectly || mentionEveryone) {
                        channelOfMessage.mentionCount += 1;
                    }
                }
                [channelOfMessage checkIfRead];
            } else {
                // We sent it, update lastReadMessageId to match so it stays read
                channelOfMessage.lastReadMessageId = messageId;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE ACK" 
                                                                  object:self 
                                                                userInfo:@{@"channelId": channelIdOfMessage}];
            });
        }
    }
}

- (void)handleMessageUpdateWithData:(NSDictionary *)d {
    NSString *channelIdOfMessage = [d objectForKey:@"channel_id"];
    NSString *messageId          = [d objectForKey:@"id"];
    // Check if a channel is currently being viewed
    // and if so, if that channel is the same the message was sent in
    if (self.selectedChannel != nil && [channelIdOfMessage isEqualToString:self.selectedChannel.snowflake]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Send notification with the new message
            // will be recieved by DCChatViewController
            [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE EDIT" object:self userInfo:d];
        });
        // Update current channel & read state last message
        [self.selectedChannel setLastMessageId:messageId];
        // Ack message since we are currently viewing this channel
        [self.selectedChannel ackMessage:messageId];
    }
}

- (DCGuild *)guildWithSnowflake:(NSString *)guildID {
    if (![guildID isKindOfClass:[NSString class]]) return nil;
    for (DCGuild *guild in self.guilds) {
        if ([guild.snowflake isEqualToString:guildID]) return guild;
    }
    return nil;
}

- (DCGuild *)privateGuild {
    for (DCGuild *guild in self.guilds) {
        if (!guild.snowflake && [guild.name isEqualToString:@"Direct Messages"])
            return guild;
    }
    return nil;
}

- (void)loadGuildIconHash:(NSString *)iconHash forGuild:(DCGuild *)guild {
    if (!guild || !guild.snowflake) return;

    guild.iconID = iconHash;
    if (!iconHash.length) {
        guild.iconURL = nil;
        guild.icon = DCDefaultGuildIconForSnowflake(guild.snowflake);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD"
                                                              object:guild];
        });
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://cdn.discordapp.com/icons/%@/%@.png?size=80",
        guild.snowflake, iconHash]];
    guild.iconURL = [url absoluteString];
    // Do not display an explicitly stale icon while the hash-versioned asset
    // is being resolved from SDWebImage's disk cache/network.
    guild.icon = DCDefaultGuildIconForSnowflake(guild.snowflake);

    [[SDWebImageManager sharedManager]
        downloadImageWithURL:url
                     options:SDWebImageRetryFailed
                    progress:nil
                   completed:^(UIImage *image, NSError *error,
                               SDImageCacheType cacheType, BOOL finished,
                               NSURL *imageURL) {
        if (!image || !finished) {
            DBGLOG(@"[GUILD_UPDATE] Failed icon %@ for guild %@: %@",
                   iconHash, guild.snowflake, error);
            return;
        }
        // A second update may have arrived while this request was in flight.
        if (![guild.iconID isEqualToString:iconHash]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![guild.iconID isEqualToString:iconHash]) return;
            CGSize itemSize = CGSizeMake(40, 40);
            UIGraphicsBeginImageContextWithOptions(itemSize, NO,
                                                   UIScreen.mainScreen.scale);
            [image drawInRect:CGRectMake(0, 0, itemSize.width, itemSize.height)];
            UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            guild.icon = resized ?: image;
            [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD"
                                                              object:guild];
        });
    }];
}

- (void)loadGuildBannerHash:(NSString *)bannerHash forGuild:(DCGuild *)guild {
    if (!guild || !guild.snowflake) return;

    guild.bannerID = bannerHash;
    guild.banner = nil;
    if (!bannerHash.length) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://cdn.discordapp.com/banners/%@/%@.png?size=320",
        guild.snowflake, bannerHash]];
    [[SDWebImageManager sharedManager]
        downloadImageWithURL:url
                     options:SDWebImageRetryFailed
                    progress:nil
                   completed:^(UIImage *image, NSError *error,
                               SDImageCacheType cacheType, BOOL finished,
                               NSURL *imageURL) {
        if (!image || !finished) {
            DBGLOG(@"[GUILD_UPDATE] Failed banner %@ for guild %@: %@",
                   bannerHash, guild.snowflake, error);
            return;
        }
        if (![guild.bannerID isEqualToString:bannerHash]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![guild.bannerID isEqualToString:bannerHash]) return;
            guild.banner = image;
            if (self.selectedGuild == guild ||
                [self.selectedGuild.snowflake isEqualToString:guild.snowflake]) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD GUILD" object:guild];
            }
        });
    }];
}

- (void)mergeGuild:(DCGuild *)guild fromData:(NSDictionary *)d {
    if (!guild || ![d isKindOfClass:[NSDictionary class]]) return;

    id value = [d objectForKey:@"id"];
    if ([value isKindOfClass:[NSString class]]) guild.snowflake = value;

    if ([d objectForKey:@"name"] != nil) {
        value = [d objectForKey:@"name"];
        if ([value isKindOfClass:[NSString class]]) guild.name = value;
    }

    if ([d objectForKey:@"owner_id"] != nil) {
        value = [d objectForKey:@"owner_id"];
        guild.ownerID = [value isKindOfClass:[NSString class]] ? value : nil;
    }

    value = [d objectForKey:@"member_count"];
    if ([value respondsToSelector:@selector(integerValue)])
        guild.memberCount = [value integerValue];

    if ([d objectForKey:@"icon"] != nil) {
        value = [d objectForKey:@"icon"];
        NSString *newHash = [value isKindOfClass:[NSString class]] ? value : nil;
        NSString *oldHash = [guild.iconID isKindOfClass:[NSString class]]
            ? guild.iconID : nil;
        BOOL changed = (oldHash != newHash) && ![oldHash isEqualToString:newHash];
        if (changed) [self loadGuildIconHash:newHash forGuild:guild];
    }

    if ([d objectForKey:@"banner"] != nil) {
        value = [d objectForKey:@"banner"];
        NSString *newHash = [value isKindOfClass:[NSString class]] ? value : nil;
        NSString *oldHash = [guild.bannerID isKindOfClass:[NSString class]]
            ? guild.bannerID : nil;
        BOOL changed = (oldHash != newHash) && ![oldHash isEqualToString:newHash];
        if (changed) [self loadGuildBannerHash:newHash forGuild:guild];
    }
}

- (void)mergeGuildCreateSnapshot:(NSDictionary *)d intoGuild:(DCGuild *)guild {
    [self mergeGuild:guild fromData:d];

    // GUILD_CREATE is also the authoritative rehydration event after a guild
    // was temporarily unavailable. Refresh roles/emojis if supplied before
    // recalculating channel permission state.
    id rawRoles = [d objectForKey:@"roles"];
    if ([rawRoles isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *roles = [NSMutableDictionary dictionary];
        for (NSDictionary *roleData in rawRoles) {
            if (![roleData isKindOfClass:[NSDictionary class]]) continue;
            DCRole *role = [DCTools convertJsonRole:roleData cache:YES];
            NSString *roleID = [roleData objectForKey:@"id"];
            if (role && [roleID isKindOfClass:[NSString class]])
                [roles setObject:role forKey:roleID];
        }
        guild.roles = roles;
        if (!guild.userRoles) guild.userRoles = [NSMutableArray array];
        // @everyone's role ID is the guild ID and always applies.
        if (guild.snowflake && ![guild.userRoles containsObject:guild.snowflake])
            [guild.userRoles insertObject:guild.snowflake atIndex:0];
    }

    id rawEmojis = [d objectForKey:@"emojis"];
    if ([rawEmojis isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *emojis = [NSMutableDictionary dictionary];
        for (NSDictionary *emojiData in rawEmojis) {
            if (![emojiData isKindOfClass:[NSDictionary class]]) continue;
            DCEmoji *emoji = [DCTools convertJsonEmoji:emojiData cache:YES];
            NSString *emojiID = [emojiData objectForKey:@"id"];
            if (emoji && [emojiID isKindOfClass:[NSString class]])
                [emojis setObject:emoji forKey:emojiID];
        }
        guild.emojis = emojis;
    }

    id rawMembers = [d objectForKey:@"members"];
    if ([rawMembers isKindOfClass:[NSArray class]]) {
        for (NSDictionary *member in rawMembers) {
            if (![member isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *userData = [member objectForKey:@"user"];
            DCUser *user = [userData isKindOfClass:[NSDictionary class]]
                ? [DCTools convertJsonUser:userData cache:YES] : nil;
            NSString *userID = user.snowflake;
            NSString *nick = [member objectForKey:@"nick"];
            if (user && [nick isKindOfClass:[NSString class]] && nick.length) {
                if (!user.guildNicknames) user.guildNicknames = [NSMutableDictionary dictionary];
                [user.guildNicknames setObject:nick forKey:guild.snowflake];
            }
            if ([userID isEqualToString:self.snowflake]) {
                NSMutableArray *currentRoles = [NSMutableArray array];
                if (guild.snowflake) [currentRoles addObject:guild.snowflake];
                id memberRoles = [member objectForKey:@"roles"];
                if ([memberRoles isKindOfClass:[NSArray class]])
                    [currentRoles addObjectsFromArray:memberRoles];
                guild.userRoles = currentRoles;
            }
        }
    }

    NSArray *rawChannels = [d objectForKey:@"channels"];
    NSArray *rawThreads = [d objectForKey:@"threads"];
    BOOL hasChannelSnapshot = [rawChannels isKindOfClass:[NSArray class]];
    if (!hasChannelSnapshot && ![rawThreads isKindOfClass:[NSArray class]]) return;

    NSMutableArray *combined = [NSMutableArray array];
    if ([rawChannels isKindOfClass:[NSArray class]]) [combined addObjectsFromArray:rawChannels];
    if ([rawThreads isKindOfClass:[NSArray class]]) [combined addObjectsFromArray:rawThreads];
    NSMutableSet *incomingIDs = [NSMutableSet set];
    NSMutableSet *listedIDs = [NSMutableSet set];

    if (!guild.channels) guild.channels = [NSMutableArray array];
    if (!self.channels) self.channels = [NSMutableDictionary dictionary];

    for (NSDictionary *rawChannel in combined) {
        if (![rawChannel isKindOfClass:[NSDictionary class]]) continue;
        NSString *channelID = [rawChannel objectForKey:@"id"];
        if (![channelID isKindOfClass:[NSString class]]) continue;
        [incomingIDs addObject:channelID];

        DCChannel *channel = [self.channels objectForKey:channelID];
        if (!channel) channel = [self channelInGuild:guild withSnowflake:channelID];
        if (!channel) channel = [DCChannel new];

        NSMutableDictionary *payload = [rawChannel mutableCopy];
        [payload setObject:guild.snowflake forKey:@"guild_id"];
        [self mergeChannel:channel fromData:payload guild:guild];
        [self.channels setObject:channel forKey:channelID];

        BOOL shouldAppear = DCChannelTypeAppearsInGuildList(channel.type);
        [self ensureChannel:channel membershipInGuild:guild shouldAppear:shouldAppear];
        if (shouldAppear) [listedIDs addObject:channelID];
    }

    if (hasChannelSnapshot) {
        // A GUILD_CREATE channel list is a snapshot. Remove visible channels
        // that were in our stale outage cache but no longer exist in it.
        NSArray *oldListed = [guild.channels copy];
        for (DCChannel *channel in oldListed) {
            if (![listedIDs containsObject:channel.snowflake])
                [guild.channels removeObject:channel];
        }

        NSArray *allKnownIDs = [self.channels allKeys];
        for (NSString *channelID in allKnownIDs) {
            DCChannel *channel = [self.channels objectForKey:channelID];
            if (channel.parentGuild == guild && ![incomingIDs containsObject:channelID])
                [self.channels removeObjectForKey:channelID];
        }
    }

    [self resortChannelsForGuild:guild];
    [guild checkIfRead];
}

- (void)invalidateGuildDisplayLayout {
    self.cachedDisplayLayout = nil;
    self.guildsIsSorted = NO;
    [[DCCacheManager sharedInstance] invalidateDisplayLayout];
}

- (void)checkpointGuildState {
    DCCacheManager *cache = [DCCacheManager sharedInstance];
    [cache saveGuilds:self.guilds];
    if (self.currentUserInfo) [cache saveUserInfo:self.currentUserInfo];
}

- (void)handleUserSettingsProtoUpdateWithData:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *settings = [d objectForKey:@"settings"];
    if (![settings isKindOfClass:[NSDictionary class]]) return;

    // Type 1 is PreloadedUserSettings. Other settings protos (frecency, etc.)
    // do not contain the guild sidebar layout we care about here.
    id typeValue = [settings objectForKey:@"type"];
    if ([typeValue respondsToSelector:@selector(integerValue)] &&
        [typeValue integerValue] != 1) {
        return;
    }

    NSString *encodedProto = [settings objectForKey:@"proto"];
    if (![encodedProto isKindOfClass:[NSString class]] || encodedProto.length == 0)
        return;

    NSData *protoData = [NSData dataWithBase64EncodedString:encodedProto];
    if (![protoData length]) {
        DBGLOG(@"[USER_SETTINGS_PROTO_UPDATE] Could not decode Base64 settings proto");
        return;
    }

    NSMutableArray *guildPositions = nil;
    NSMutableArray *guildFolders = nil;
    if (!DCDecodeGuildLayoutProto(protoData, &guildPositions, &guildFolders)) {
        // Most settings changes are unrelated to guild layout. Silently ignore
        // a valid PreloadedUserSettings update that does not include field 14.
        return;
    }

    if (!self.currentUserInfo) self.currentUserInfo = [DCUserInfo new];
    self.currentUserInfo.guildPositions = guildPositions ?: [NSMutableArray array];
    self.currentUserInfo.guildFolders = guildFolders ?: [NSMutableArray array];

    [self invalidateGuildDisplayLayout];
    [[DCCacheManager sharedInstance] saveUserInfo:self.currentUserInfo];

    DBGLOG(@"[USER_SETTINGS_PROTO_UPDATE] Applied guild layout: %lu guilds, %lu folder entries",
           (unsigned long)self.currentUserInfo.guildPositions.count,
           (unsigned long)self.currentUserInfo.guildFolders.count);

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD LIST"
                                                          object:self];
    });
}

- (void)handleGuildCreateWithData:(NSDictionary *)d {
    NSString *guildID = [d objectForKey:@"id"];
    if (![guildID isKindOfClass:[NSString class]] || guildID.length == 0) return;

    id unavailable = [d objectForKey:@"unavailable"];
    if ([unavailable respondsToSelector:@selector(boolValue)] && [unavailable boolValue]) {
        DBGLOG(@"[GUILD_CREATE] Guild %@ is still unavailable; retaining cached state", guildID);
        return;
    }

    DCGuild *guild = [self guildWithSnowflake:guildID];
    BOOL created = (guild == nil);
    if (created) {
        guild = [DCTools convertJsonGuild:d withMembers:nil];
        if (!guild) return;
        if (!self.guilds) self.guilds = [NSMutableArray array];
        [self.guilds addObject:guild];
        if (self.currentUserInfo.guildPositions &&
            ![self.currentUserInfo.guildPositions containsObject:guildID]) {
            [self.currentUserInfo.guildPositions addObject:guildID];
        }
        [self invalidateGuildDisplayLayout];
    } else {
        [self mergeGuildCreateSnapshot:d intoGuild:guild];
    }

    DBGLOG(@"[GUILD_CREATE] %@ guild %@ (%@)",
           created ? @"Inserted" : @"Rehydrated", guild.name ?: @"(unnamed)", guildID);
    [self checkpointGuildState];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD LIST"
                                                          object:guild];
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST"
                                                          object:nil];
    });
}

- (void)handleGuildUpdateWithData:(NSDictionary *)d {
    NSString *guildID = [d objectForKey:@"id"];
    if (![guildID isKindOfClass:[NSString class]] || guildID.length == 0) return;

    DCGuild *guild = [self guildWithSnowflake:guildID];
    if (!guild) {
        // UPDATE normally targets a known guild, but preserve forward progress
        // if our cache missed it. Create a minimal canonical shell rather than
        // forcing a master refresh.
        guild = [DCGuild new];
        guild.snowflake = guildID;
        guild.channels = [NSMutableArray array];
        guild.members = [NSMutableArray array];
        guild.roles = [NSMutableDictionary dictionary];
        guild.userRoles = [NSMutableArray arrayWithObject:guildID];
        guild.emojis = [NSMutableDictionary dictionary];
        if (!self.guilds) self.guilds = [NSMutableArray array];
        [self.guilds addObject:guild];
        [self invalidateGuildDisplayLayout];
    }

    NSString *oldName = guild.name;
    NSString *oldIcon = guild.iconID;
    NSString *oldBanner = guild.bannerID;
    [self mergeGuild:guild fromData:d];

    DBGLOG(@"[GUILD_UPDATE] Merged guild %@ (%@)%@%@%@",
           guild.name ?: @"(unnamed)", guildID,
           (oldName != guild.name && ![oldName isEqualToString:guild.name]) ? @" name" : @"",
           (oldIcon != guild.iconID && ![oldIcon isEqualToString:guild.iconID]) ? @" icon" : @"",
           (oldBanner != guild.bannerID && ![oldBanner isEqualToString:guild.bannerID]) ? @" banner" : @"");

    [self checkpointGuildState];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD"
                                                          object:guild];
    });
}

- (void)handleGuildDeleteWithData:(NSDictionary *)d {
    NSString *guildID = [d objectForKey:@"id"];
    if (![guildID isKindOfClass:[NSString class]] || guildID.length == 0) return;

    id unavailable = [d objectForKey:@"unavailable"];
    if ([unavailable respondsToSelector:@selector(boolValue)] && [unavailable boolValue]) {
        // Discord uses GUILD_DELETE for temporary outages too. The last-known
        // cache is more useful than an empty hole; GUILD_CREATE will rehydrate
        // this same canonical object when the guild becomes available again.
        DBGLOG(@"[GUILD_DELETE] Guild %@ temporarily unavailable; retaining cached state", guildID);
        return;
    }

    DCGuild *guild = [self guildWithSnowflake:guildID];
    if (!guild) return; // idempotent replay/delete

    NSArray *allChannelIDs = [[self.channels allKeys] copy];
    for (NSString *channelID in allChannelIDs) {
        DCChannel *channel = [self.channels objectForKey:channelID];
        if (channel.parentGuild == guild ||
            [channel.parentGuild.snowflake isEqualToString:guildID]) {
            [[DCMessageStore sharedInstance] removeWindowForChannel:channelID];
            [self.channels removeObjectForKey:channelID];
        }
    }
    [self.guilds removeObject:guild];

    // Drop guild-scoped identity metadata while keeping canonical users.
    for (DCUser *user in [self.loadedUsers allValues]) {
        [user.guildNicknames removeObjectForKey:guildID];
    }
    for (NSString *roleID in [guild.roles allKeys])
        [self.loadedRoles removeObjectForKey:roleID];
    for (NSString *emojiID in [guild.emojis allKeys])
        [self.loadedEmojis removeObjectForKey:emojiID];

    [self.currentUserInfo.guildPositions removeObject:guildID];
    for (DCGuildFolder *folder in self.currentUserInfo.guildFolders) {
        if (![folder.guildIds containsObject:guildID]) continue;
        NSMutableArray *ids = [folder.guildIds mutableCopy];
        [ids removeObject:guildID];
        folder.guildIds = ids;
    }

    if ([self.selectedGuild.snowflake isEqualToString:guildID] ||
        [self.selectedChannel.parentGuild.snowflake isEqualToString:guildID]) {
        [[DCCacheManager sharedInstance] clearLastActiveChatChannel];
        self.selectedGuild = [self privateGuild];
        self.selectedChannel = nil;
    }

    [self invalidateGuildDisplayLayout];
    [self checkpointGuildState];
    DBGLOG(@"[GUILD_DELETE] Removed guild %@", guildID);

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD LIST"
                                                          object:guild];
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST"
                                                          object:nil];
    });
}

- (DCGuild *)guildForChannelPayload:(NSDictionary *)d {
    id guildID = [d objectForKey:@"guild_id"];
    if ([guildID isKindOfClass:[NSString class]]) {
        for (DCGuild *guild in self.guilds) {
            if ([guild.snowflake isEqualToString:guildID]) return guild;
        }
        return nil;
    }

    // Private channels live inside Classic's synthetic Direct Messages guild.
    for (DCGuild *guild in self.guilds) {
        if (!guild.snowflake && [guild.name isEqualToString:@"Direct Messages"]) {
            return guild;
        }
    }
    return nil;
}

- (DCChannel *)channelInGuild:(DCGuild *)guild withSnowflake:(NSString *)channelID {
    if (!guild || !channelID) return nil;
    for (DCChannel *candidate in guild.channels) {
        if ([candidate.snowflake isEqualToString:channelID]) return candidate;
    }
    return nil;
}

- (void)ensureChannel:(DCChannel *)channel
      membershipInGuild:(DCGuild *)guild
          shouldAppear:(BOOL)shouldAppear {
    if (!guild || !channel.snowflake) return;
    if (!guild.channels) guild.channels = [NSMutableArray array];

    DCChannel *listed = [self channelInGuild:guild withSnowflake:channel.snowflake];
    if (!shouldAppear) {
        if (listed) [guild.channels removeObject:listed];
        return;
    }

    if (!listed) {
        [guild.channels addObject:channel];
    } else if (listed != channel) {
        NSUInteger index = [guild.channels indexOfObjectIdenticalTo:listed];
        if (index != NSNotFound) [guild.channels replaceObjectAtIndex:index withObject:channel];
    }
}

- (void)rebuildPrivateChannelRelationships:(DCChannel *)channel
                                   fromData:(NSDictionary *)d {
    NSArray *recipientIDs = nil;
    id rawRecipientIDs = [d objectForKey:@"recipient_ids"];
    if ([rawRecipientIDs isKindOfClass:[NSArray class]]) {
        recipientIDs = rawRecipientIDs;
    } else {
        id rawRecipients = [d objectForKey:@"recipients"];
        if ([rawRecipients isKindOfClass:[NSArray class]]) {
            NSMutableArray *ids = [NSMutableArray array];
            for (id rawRecipient in rawRecipients) {
                if (![rawRecipient isKindOfClass:[NSDictionary class]]) continue;
                DCUser *user = [DCTools convertJsonUser:rawRecipient cache:YES];
                if (user.snowflake) [ids addObject:user.snowflake];
            }
            recipientIDs = ids;
        }
    }

    if (!recipientIDs) return;

    channel.recipientIDs = [NSArray arrayWithArray:recipientIDs];
    NSMutableArray *recipients = [NSMutableArray array];
    for (NSString *recipientID in recipientIDs) {
        DCUser *recipient = [self userForSnowflake:recipientID];
        if (recipient) [recipients addObject:recipient];
    }
    channel.recipients = recipients;

    NSMutableArray *users = [recipients mutableCopy];
    DCUser *currentUser = [self userForSnowflake:self.snowflake];
    if (currentUser) [users addObject:currentUser];
    channel.users = users;
}

- (void)updateWriteabilityForChannel:(DCChannel *)channel
                            fromData:(NSDictionary *)d
                               guild:(DCGuild *)guild {
    if (!guild || !guild.snowflake) {
        channel.writeable = YES;
        return;
    }

    NSArray *rawOverwrites = [d objectForKey:@"permission_overwrites"];
    if (![rawOverwrites isKindOfClass:[NSArray class]]) return;

    BOOL canWrite = YES;
    NSArray *overwrites = [rawOverwrites sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *perm1, NSDictionary *perm2) {
            DCRole *role1 = [guild.roles objectForKey:[perm1 objectForKey:@"id"]];
            DCRole *role2 = [guild.roles objectForKey:[perm2 objectForKey:@"id"]];
            NSInteger p1 = role1 ? role1.position : 0;
            NSInteger p2 = role2 ? role2.position : 0;
            if (p1 < p2) return NSOrderedAscending;
            if (p1 > p2) return NSOrderedDescending;
            return NSOrderedSame;
        }];

    for (NSDictionary *permission in overwrites) {
        NSInteger type = [[permission objectForKey:@"type"] integerValue];
        NSString *identifier = [permission objectForKey:@"id"];
        uint64_t deny = [[permission objectForKey:@"deny"] longLongValue];
        uint64_t allow = [[permission objectForKey:@"allow"] longLongValue];

        if (type == 0) {
            if (![guild.userRoles containsObject:identifier]) continue;
            if ((deny & DCPermissionSendMessages) == DCPermissionSendMessages)
                canWrite = NO;
            if ((allow & DCPermissionSendMessages) == DCPermissionSendMessages)
                canWrite = YES;
        } else if (type == 1 && [identifier isEqualToString:self.snowflake]) {
            if ((deny & DCPermissionSendMessages) == DCPermissionSendMessages)
                canWrite = NO;
            if ((allow & DCPermissionSendMessages) == DCPermissionSendMessages)
                canWrite = YES;
            break;
        }
    }

    channel.writeable = canWrite || [guild.ownerID isEqualToString:self.snowflake];
}

- (void)mergeChannel:(DCChannel *)channel
             fromData:(NSDictionary *)d
                guild:(DCGuild *)guild {
    id value = [d objectForKey:@"id"];
    if ([value isKindOfClass:[NSString class]]) channel.snowflake = value;

    if ([d objectForKey:@"parent_id"] != nil) {
        value = [d objectForKey:@"parent_id"];
        channel.parentID = [value isKindOfClass:[NSString class]] ? value : nil;
    }

    if ([d objectForKey:@"name"] != nil) {
        value = [d objectForKey:@"name"];
        channel.name = [value isKindOfClass:[NSString class]] ? value : nil;
    }

    if ([d objectForKey:@"last_message_id"] != nil) {
        value = [d objectForKey:@"last_message_id"];
        channel.lastMessageId = [value isKindOfClass:[NSString class]] ? value : nil;
    }

    value = [d objectForKey:@"type"];
    if ([value respondsToSelector:@selector(integerValue)])
        channel.type = (DCChannelType)[value integerValue];

    value = [d objectForKey:@"position"];
    if ([value respondsToSelector:@selector(integerValue)])
        channel.position = [value integerValue];

    if ([d objectForKey:@"icon"] != nil) {
        value = [d objectForKey:@"icon"];
        NSString *newIconID = [value isKindOfClass:[NSString class]] ? value : nil;
        BOOL changed = (channel.iconID != newIconID)
            && ![channel.iconID isEqualToString:newIconID];
        if (changed) {
            channel.iconID = newIconID;
            channel.icon = nil;
        }
    }

    channel.parentGuild = guild;
    [self rebuildPrivateChannelRelationships:channel fromData:d];
    [self updateWriteabilityForChannel:channel fromData:d guild:guild];

    // 1:1 DMs have no explicit name. Keep their label tied to the canonical
    // user so a restored/updated display name appears without another fetch.
    if (channel.type == DCChannelTypeDM && channel.recipients.count == 1) {
        NSString *displayName = [[channel.recipients objectAtIndex:0] displayName];
        if (displayName.length > 0) channel.name = displayName;
    } else if (channel.type == DCChannelTypeGroupDM && channel.name.length == 0
               && channel.recipients.count > 0) {
        NSMutableArray *names = [NSMutableArray array];
        for (DCUser *recipient in channel.recipients) {
            NSString *displayName = [recipient displayName];
            if (displayName.length > 0) [names addObject:displayName];
        }
        if (names.count > 0) channel.name = [names componentsJoinedByString:@", "];
    }
}

- (void)resortChannelsForGuild:(DCGuild *)guild {
    if (!guild || guild.channels.count < 2) return;

    if (!guild.snowflake) {
        [guild.channels sortUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
            NSString *idA = [a.lastMessageId isKindOfClass:[NSString class]] ? a.lastMessageId : @"0";
            NSString *idB = [b.lastMessageId isKindOfClass:[NSString class]] ? b.lastMessageId : @"0";
            return [idB compare:idA options:NSNumericSearch];
        }];
        return;
    }

    NSMutableArray *categories = [NSMutableArray array];
    NSMutableArray *channels = [NSMutableArray array];
    for (DCChannel *channel in guild.channels) {
        // Older READY/cached channel objects may contain NSNull for parent_id.
        // Normalize it here too so structural events can safely resort a mixed
        // pre-hotfix object graph without waiting for a fresh READY.
        if (![channel.parentID isKindOfClass:[NSString class]])
            channel.parentID = nil;

        if (channel.type == DCChannelTypeGuildCategory)
            [categories addObject:channel];
        else
            [channels addObject:channel];
    }

    [categories sortUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
        if (a.position < b.position) return NSOrderedAscending;
        if (a.position > b.position) return NSOrderedDescending;
        return [a.snowflake compare:b.snowflake];
    }];

    [channels sortUsingComparator:^NSComparisonResult(DCChannel *channel1, DCChannel *channel2) {
        BOOL hasParent1 = [channel1.parentID isKindOfClass:[NSString class]];
        BOOL hasParent2 = [channel2.parentID isKindOfClass:[NSString class]];
        if (hasParent1 != hasParent2)
            return hasParent1 ? NSOrderedDescending : NSOrderedAscending;

        if (hasParent1 && ![channel1.parentID isEqualToString:channel2.parentID]) {
            DCChannel *parent1 = [self.channels objectForKey:channel1.parentID];
            DCChannel *parent2 = [self.channels objectForKey:channel2.parentID];
            if (parent1.position < parent2.position) return NSOrderedAscending;
            if (parent1.position > parent2.position) return NSOrderedDescending;
        }

        if (channel1.position < channel2.position) return NSOrderedAscending;
        if (channel1.position > channel2.position) return NSOrderedDescending;
        return [channel1.snowflake compare:channel2.snowflake];
    }];

    NSMutableArray *ordered = [channels mutableCopy];
    for (DCChannel *category in categories) {
        if (![category.snowflake isKindOfClass:[NSString class]])
            continue;

        NSUInteger firstChild = [ordered indexOfObjectPassingTest:
            ^BOOL(DCChannel *candidate, NSUInteger idx, BOOL *stop) {
                if (![candidate.parentID isKindOfClass:[NSString class]])
                    return NO;
                return [(NSString *)candidate.parentID isEqualToString:category.snowflake];
            }];
        if (firstChild == NSNotFound)
            [ordered addObject:category];
        else
            [ordered insertObject:category atIndex:firstChild];
    }
    guild.channels = ordered;
}

- (void)checkpointChannelStructure {
    // Channel structural events are infrequent enough that a complete guild
    // structure checkpoint is acceptable for now. This will become dirty-ID
    // persistence once the cache is normalized.
    [[DCCacheManager sharedInstance] saveGuilds:self.guilds];
}

- (void)handleChannelCreateWithData:(NSDictionary *)d {
    NSString *channelID = [d objectForKey:@"id"];
    if (![channelID isKindOfClass:[NSString class]] || channelID.length == 0)
        return;

    if (!self.channels) self.channels = [NSMutableDictionary dictionary];

    DCGuild *guild = [self guildForChannelPayload:d];
    DCChannel *channel = [self.channels objectForKey:channelID];
    if (!channel && guild) channel = [self channelInGuild:guild withSnowflake:channelID];
    BOOL created = (channel == nil);
    if (!channel) channel = [DCChannel new];

    [self mergeChannel:channel fromData:d guild:guild];
    [self.channels setObject:channel forKey:channelID];

    if (guild) {
        BOOL shouldAppear = !guild.snowflake
            || DCChannelTypeAppearsInGuildList(channel.type);
        [self ensureChannel:channel membershipInGuild:guild shouldAppear:shouldAppear];
        [self resortChannelsForGuild:guild];
        [guild checkIfRead];
    }

    DBGLOG(@"[%@] %@ channel %@ (%@)",
           created ? @"CHANNEL_CREATE" : @"CHANNEL_CREATE replay",
           created ? @"Inserted" : @"Merged existing",
           channel.name ?: @"(unnamed)", channelID);

    [self checkpointChannelStructure];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD CHANNEL LIST" object:channel];
    });
}

- (void)handleChannelUpdateWithData:(NSDictionary *)d {
    NSString *channelID = [d objectForKey:@"id"];
    if (![channelID isKindOfClass:[NSString class]] || channelID.length == 0)
        return;

    DCChannel *channel = [self.channels objectForKey:channelID];
    if (!channel) {
        // Treat an update for an object we somehow missed as an upsert. This is
        // safe for Gateway replay and avoids requiring a master refresh.
        [self handleChannelCreateWithData:d];
        return;
    }

    DCGuild *oldGuild = channel.parentGuild;
    DCGuild *guild = [self guildForChannelPayload:d] ?: oldGuild;
    [self mergeChannel:channel fromData:d guild:guild];

    if (oldGuild && oldGuild != guild) {
        DCChannel *oldListed = [self channelInGuild:oldGuild withSnowflake:channelID];
        if (oldListed) [oldGuild.channels removeObject:oldListed];
        [self resortChannelsForGuild:oldGuild];
    }

    if (guild) {
        BOOL shouldAppear = !guild.snowflake
            || DCChannelTypeAppearsInGuildList(channel.type);
        [self ensureChannel:channel membershipInGuild:guild shouldAppear:shouldAppear];
        [self resortChannelsForGuild:guild];
        [guild checkIfRead];
    }

    DBGLOG(@"[CHANNEL_UPDATE] Merged channel %@ (%@)",
           channel.name ?: @"(unnamed)", channelID);
    [self checkpointChannelStructure];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD CHANNEL LIST" object:channel];
    });
}

- (void)handleChannelDeleteWithData:(NSDictionary *)d {
    NSString *channelID = [d objectForKey:@"id"];
    if (![channelID isKindOfClass:[NSString class]] || channelID.length == 0)
        return;

    DCChannel *channel = [self.channels objectForKey:channelID];
    DCGuild *guild = channel.parentGuild ?: [self guildForChannelPayload:d];

    if (guild) {
        DCChannel *listed = [self channelInGuild:guild withSnowflake:channelID];
        if (listed) [guild.channels removeObject:listed];
        [self resortChannelsForGuild:guild];
        [guild checkIfRead];
    }
    [self.channels removeObjectForKey:channelID];
    [[DCMessageStore sharedInstance] removeWindowForChannel:channelID];

    if ([self.selectedChannel.snowflake isEqualToString:channelID]) {
        [[DCCacheManager sharedInstance] clearLastActiveChatChannel];
        self.selectedChannel = nil;
    }

    DBGLOG(@"[CHANNEL_DELETE] Removed channel %@", channelID);
    [self checkpointChannelStructure];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD CHANNEL LIST" object:channel];
    });
}

- (id)handleGuildMemberItemWithItem:(NSDictionary *)item guild:(DCGuild *)guild {
    if ([item objectForKey:@"group"]) {
        NSDictionary *groupItem = [item objectForKey:@"group"];
        id ret = [self roleForSnowflake:[groupItem objectForKey:@"id"]];
        if (!ret) {
            // fake online/offline roles
            DCRole *role   = DCRole.new;
            role.snowflake = [groupItem objectForKey:@"id"];
            if ([role.snowflake isEqualToString:@"online"]) {
                role.name = @"Online";
            } else if ([role.snowflake isEqualToString:@"offline"]) {
                role.name = @"Offline";
            } else {
                role.name = [groupItem objectForKey:@"id"];
            }
            [self setRole:role forSnowflake:[groupItem objectForKey:@"id"]];
            ret = role;
        }
        return ret;
    } else if ([item objectForKey:@"member"]) {
        NSDictionary *memberItem = [item objectForKey:@"member"];
        DCUser *user = [self userForSnowflake:[memberItem valueForKeyPath:@"user.id"]];
        if (!user) {
            user = [DCTools convertJsonUser:[memberItem objectForKey:@"user"] cache:YES];
            [self setUser:user forSnowflake:user.snowflake];
        }
        NSString *nick = [memberItem objectForKey:@"nick"];
        if (guild && nick && (NSNull *)nick != [NSNull null] && nick.length > 0
            && guild.snowflake) { // add nil check
            if (!user.guildNicknames) user.guildNicknames = NSMutableDictionary.new;
            user.guildNicknames[guild.snowflake] = nick;
        }
        user.status = [DCUser statusFromString:[memberItem valueForKeyPath:@"presence.status"]];
        return user;
    } else {
        return nil;
    }
}

#define SYNC @"SYNC"
#define UPDATE @"UPDATE"
#define DELETE @"DELETE"
#define INSERT @"INSERT"

- (void)handleGuildMemberListUpdateWithData:(NSDictionary *)d {
    DCGuild *guild = nil;
    for (DCGuild *g in self.guilds) {
        if ([g.snowflake isEqualToString:[d objectForKey:@"guild_id"]]) {
            guild = g;
            break;
        }
    }
    if (!guild) {
        return;
    }
    @synchronized(guild) {
        guild.memberCount = [[d objectForKey:@"member_count"] intValue];
        guild.onlineCount = [[d objectForKey:@"online_count"] intValue];

        for (NSDictionary *op in [d objectForKey:@"ops"]) {
            if ([[op objectForKey:@"op"] isEqualToString:SYNC]) {
                if (![[op objectForKey:@"items"] isKindOfClass:[NSArray class]]
                    || [((NSArray *)[op objectForKey:@"items"]) count] == 0) {
                    DBGLOG(@"Guild member list update SYNC op without items: %@", op);
                    continue;
                }
                guild.members = NSMutableArray.new;
                // #ifdef DEBUG
                //              NSLog(
                //                  @"SYNC: length: %lu, range: [%lu..%lu]",
                //                  (unsigned long)[op[@"items"] count],
                //                  (unsigned long)[op[@"range"][0] integerValue],
                //                  (unsigned long)[op[@"range"][1] integerValue]
                //              );
                // #endif
                for (NSDictionary *item in [op objectForKey:@"items"]) {
                    id member = [self handleGuildMemberItemWithItem:item guild:guild];
                    if (!member) {
                        DBGLOG(@"Guild member list update SYNC op with invalid item: %@", item);
                        continue;
                    }
                    [guild.members addObject:member];
                }
            } else if ([[op objectForKey:@"op"] isEqualToString:UPDATE]) {
                NSDictionary *item = [op objectForKey:@"item"];
                id member = [self handleGuildMemberItemWithItem:item guild:guild];
                if (!member) {
                    DBGLOG(@"Guild member list UPDATE op with invalid item: %@", item);
                    continue;
                }
                NSUInteger index = (NSUInteger)[[op objectForKey:@"index"] intValue];
                NSUInteger count = guild.members.count;
                if (count == 0 || index >= count) {
                    DBGLOG(@"Guild member list UPDATE op index %lu OOB (count: %lu), skipping",
                           (unsigned long)index, (unsigned long)count);
                    continue;
                }
                [guild.members replaceObjectAtIndex:index withObject:member];
            } else if ([[op objectForKey:@"op"] isEqualToString:DELETE]) {
                NSUInteger count = [guild.members count];
                if (count == 0) {
                    DBGLOG(@"Guild member list update DELETE op on empty members array");
                    continue;
                }
                NSUInteger index = (NSUInteger)[[op objectForKey:@"index"] intValue];
                if (index >= count) {
                    index = count - 1;
                }
                [guild.members removeObjectAtIndex:index];

            } else if ([[op objectForKey:@"op"] isEqualToString:INSERT]) {
                NSUInteger count = [guild.members count];
                NSUInteger index = (NSUInteger)[[op objectForKey:@"index"] intValue];
                if (index > count) {
                    index = count;  // clamp to append position, not count-1
                }
                NSDictionary *item = [op objectForKey:@"item"];
                id member          = [self handleGuildMemberItemWithItem:item guild:guild];
                if (!member) {
                    DBGLOG(@"Guild member list update INSERT op with invalid item: %@", item);
                    continue;
                }
                [guild.members insertObject:member atIndex:index];
            } else {
                DBGLOG(@"Unhandled guild member list update op: %@", op);
            }
        }
        if ([guild.members count] > 100) {
            // NSLog(@"Capping guild members at 100");
            guild.members = [[guild.members subarrayWithRange:NSMakeRange(0, 100)] mutableCopy];
        }
        // #ifdef DEBUG
        //      NSLog(@"size: %lu", (unsigned long)[guild.members count]);
        // #endif
    }
    if (self.selectedChannel != nil && [self.selectedChannel.parentGuild.snowflake isEqualToString:guild.snowflake]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"GuildMemberListUpdated" object:nil];
        });
    }
}

#pragma mark - WebSocket Event Handlers

- (void)handleHelloWithData:(NSDictionary *)d {
    __weak typeof(self) weakSelf = self;

    NSTimeInterval heartbeatSeconds =
        [[d objectForKey:@"heartbeat_interval"] doubleValue] /
        1000.0;

    self.heartbeatInterval = heartbeatSeconds;

    dispatch_async(dispatch_get_main_queue(), ^{
        [heartbeatTimer invalidate];
        heartbeatTimer = nil;

        if (self.applicationSuspended) {
            return;
        }

        NSTimeInterval jitter =
            heartbeatSeconds *
            (arc4random_uniform(1000) / 1000.0);

        self.gotHeartbeat = NO;

        DBGLOG(@"Heartbeat is %f seconds, jitter is %f seconds",
               heartbeatSeconds,
               jitter);

        heartbeatTimer =
            [NSTimer scheduledTimerWithTimeInterval:jitter
                                             target:self
                                           selector:@selector(jitterBeat:)
                                           userInfo:@{
                                               @"heartbeatInterval" :
                                                   @(heartbeatSeconds)
                                           }
                                            repeats:NO];
    });
    if (self.sequenceNumber && self.sessionId) {
        DBGLOG(@"Sending Resume with sequence number %li, session ID %@", (long)self.sequenceNumber, self.sessionId);
        // RESUME
        [self sendJSON:@{
            @"op" : @(DCGatewayOpCodeResume),
            @"d" : @{
                @"token" : self.token,
                @"session_id" : self.sessionId,
                @"seq" : @(self.sequenceNumber),
            }
        }];
    } else {
        DBGLOG(@"Sending Identify");
        [self sendJSON:@{
            @"op" : @(DCGatewayOpCodeIdentify),
            @"d" : @{
                @"token" : self.token,
                @"properties" : [DCServerCommunicator superProperties],
                @"large_threshold" : @"50",
                @"capabilities" : @(
                    DCGatewayCapabilitiesDebounceMessageReactions // not handling it anyways
                    | DCGatewayCapabilitiesLazyUserNotes          // not handling it anyways
                    | DCGatewayCapabilitiesDedupeUserObjects      // dedupe user objects in READY payload
                ),
            }
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!weakSelf.didAuthenticate && weakSelf.websocket) {
                [weakSelf showNonIntrusiveNotificationWithTitle:@"Downloading data…"];
            }
        });
        // Disable ability to identify until reenabled 5 seconds later.
        // API only allows once identify every 5 seconds
        self.canIdentify = false;
        /* do not initialize guilds and channels here,
           could cause concurrency issues while guilds and channels are being loaded */
        dispatch_sync(dispatch_get_main_queue(), ^{
            // loadedUsers is a canonical store and may have been restored from
            // disk before this IDENTIFY. Do not throw it away here; READY will
            // merge fresh user fields into those existing objects.
            if (!self.loadedUsers) self.loadedUsers = NSMutableDictionary.new;

            // Roles are still rebuilt from READY.  Emoji objects, however,
            // may already have been synthesized from cached/external message
            // tokens before IDENTIFY; preserve those so their image fetches and
            // inline attachment lookups remain valid across authentication.
            self.loadedRoles = NSMutableDictionary.new;
            if (!self.loadedEmojis) self.loadedEmojis = NSMutableDictionary.new;
        });
    }
}

- (void)sendGuildSubscriptionWithGuildId:(NSString *)guildId channelId:(NSString *)channelId {
    if (!self.token || !self.sessionId) {
        return;
    } else if (!guildId || !channelId) {
        return;
    }
    // #ifdef DEBUG
    //     NSLog(@"Sending guild subscription for guild %@ and channel %@", guildId, channelId);
    // #endif
    [self sendJSON:@{
        @"op" : @(DCGatewayOpCodeGuildSubscriptions),
        @"d" : @{
            @"guild_id" : guildId,
            @"typing" : @YES,
            @"threads" : @YES,
            @"activities" : @YES,
            @"thread_member_lists" : @[],
            @"members" : @[],
            @"channels" : @{
                channelId : @[
                    @[ @0, @99 ]
                ]
            }
        }
    }];
}

- (void)handleDispatchWithResponse:(NSDictionary *)parsedJsonResponse {
    __weak typeof(self) weakSelf = self;
    // get data
    NSDictionary *d = [parsedJsonResponse objectForKey:@"d"];

    // Get event type and sequence number
    NSString *t         = [parsedJsonResponse objectForKey:@"t"];
    self.sequenceNumber = [[parsedJsonResponse objectForKey:@"s"] integerValue];
    // NSLog(@"Got event %@", t);
    // received READY
    if (![[parsedJsonResponse objectForKey:@"t"] isKindOfClass:[NSString class]]) {
        return;
    }

    if ([t isEqualToString:@"READY"]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf handleReadyWithData:d];
        });
        return;
    } else if ([t isEqualToString:PRESENCE_UPDATE_EVENT]) {
        [self handlePresenceUpdateEventWithData:d];
        return;
    } else if ([t isEqualToString:USER_UPDATE]) {
        DCUser *user = [DCTools convertJsonUser:d cache:YES];
        if (user) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD USER DATA"
                                  object:user];
            });
        }
        return;
    } else if ([t isEqualToString:GUILD_MEMBER_UPDATE]) {
        NSDictionary *userDict = [d objectForKey:@"user"];
        DCUser *user = [userDict isKindOfClass:[NSDictionary class]]
            ? [DCTools convertJsonUser:userDict cache:YES]
            : nil;
        NSString *guildId = [d objectForKey:@"guild_id"];
        if (user && guildId) {
            id nick = [d objectForKey:@"nick"];
            if (!user.guildNicknames) user.guildNicknames = NSMutableDictionary.new;
            if ([nick isKindOfClass:[NSString class]] && [nick length] > 0)
                [user.guildNicknames setObject:nick forKey:guildId];
            else if (nick == [NSNull null] || nick != nil)
                [user.guildNicknames removeObjectForKey:guildId];

            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD USER DATA"
                                  object:user];
            });
        }
        return;
    } else if ([t isEqualToString:@"USER_SETTINGS_PROTO_UPDATE"]) {
        [self handleUserSettingsProtoUpdateWithData:d];
        return;
    } else if ([t isEqualToString:RESUMED]) {
        DBGLOG(@"Gateway RESUMED successfully at sequence %li", (long)self.sequenceNumber);
        self.didAuthenticate = true;
        self.reconnectAttempts = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.alertView dismissWithClickedButtonIndex:0 animated:YES];
            [self dismissNotification];

            [NSNotificationCenter.defaultCenter
                postNotificationName:@"CONNECTION_RESTORED"
                              object:self];
        });
        return;
    } else if ([t isEqualToString:MESSAGE_CREATE]) {
        [self handleMessageCreateWithData:d];
        return;
    } else if ([t isEqualToString:MESSAGE_UPDATE]) {
        [self handleMessageUpdateWithData:d];
        return;
    } else if ([t isEqualToString:MESSAGE_DELETE]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE DELETE" object:self userInfo:d];
        });
        return;
    } else if ([t isEqualToString:MESSAGE_ACK]) {
        NSString *channelId = [d objectForKey:@"channel_id"];
        NSString *messageId = [d objectForKey:@"message_id"];
        DCChannel *channel = [self.channels objectForKey:channelId];
        if (channel) {
            channel.lastReadMessageId = messageId;
            channel.mentionCount = 0;
            [channel checkIfRead];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE ACK" 
                                                              object:self
                                                            userInfo:@{@"channelId": channelId}];
        });
        return;
    } else if ([t isEqualToString:TYPING_START]) {
        if (![d[@"channel_id"] isEqualToString:self.selectedChannel.snowflake]
            || ![d[@"guild_id"] isEqualToString:self.selectedChannel.parentGuild.snowflake]) {
            DBGLOG(@"Ignoring typing start event for channel %@ in guild %@, not currently selected channel/guild", d[@"channel_id"], d[@"guild_id"]);
            return;
        }
        DBGLOG(@"Got typing start event for channel %@ in guild %@", d[@"channel_id"], d[@"guild_id"]);
        if (![self userForSnowflake:d[@"user_id"]]
            || [self userForSnowflake:d[@"user_id"]] == [NSNull null]) {
            [DCTools convertJsonUser:[d valueForKeyPath:@"member.user"] cache:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"TYPING START"
                              object:d[@"user_id"]];
        });
    } else if ([t isEqualToString:GUILD_CREATE]) {
        [self handleGuildCreateWithData:d];
        return;
    } else if ([t isEqualToString:GUILD_UPDATE]) {
        [self handleGuildUpdateWithData:d];
        return;
    } else if ([t isEqualToString:GUILD_DELETE]) {
        [self handleGuildDeleteWithData:d];
        return;
    } else if ([t isEqualToString:THREAD_CREATE] || [t isEqualToString:CHANNEL_CREATE]) {
        [self handleChannelCreateWithData:d];
        return;
    } else if ([t isEqualToString:THREAD_UPDATE] || [t isEqualToString:CHANNEL_UPDATE]) {
        [self handleChannelUpdateWithData:d];
        return;
    } else if ([t isEqualToString:THREAD_DELETE] || [t isEqualToString:CHANNEL_DELETE]) {
        [self handleChannelDeleteWithData:d];
        return;
    } else if ([t isEqualToString:CHANNEL_UNREAD_UPDATE]) {
        if (!self.channels) {
            return;
        }
        NSArray *unreads = [d objectForKey:@"channel_unread_updates"];
        for (NSDictionary *unread in unreads) {
            NSString *channelId = [unread objectForKey:@"id"];
            DCChannel *channel  = [self.channels objectForKey:channelId];
            if (channel) {
                channel.lastMessageId = [unread objectForKey:@"last_message_id"];
                // #ifdef DEBUG
                //                 BOOL oldUnread        = channel.unread;
                [channel checkIfRead];
                //                 if (oldUnread != channel.unread) {
                //                     NSLog(@"Channel %@ (%@) unread state changed to %d", channel.name, channel.snowflake, channel.unread);
                //                 }
                // #endif
            }
        }
    } else if ([t isEqualToString:GUILD_MEMBER_LIST_UPDATE]) {
        [self handleGuildMemberListUpdateWithData:d];
        return;
    } else if ([t isEqualToString:@"GUILD_MEMBERS_CHUNK"]) {
        NSString *guildId = [d objectForKey:@"guild_id"];
        NSArray *members  = [d objectForKey:@"members"];
        DCGuild *guild = nil;
        for (DCGuild *g in self.guilds) {
            if ([g.snowflake isEqualToString:guildId]) { guild = g; break; }
        }
        if (!guild || !members) return;
        for (NSDictionary *memberDict in members) {
            DCUser *user = [DCTools convertJsonUser:[memberDict objectForKey:@"user"]
                                              cache:YES];
            if (!user) continue;
            NSString *nick = [memberDict objectForKey:@"nick"];
            if ([nick isKindOfClass:[NSString class]] && nick.length > 0) {
                if (!user.guildNicknames) user.guildNicknames = NSMutableDictionary.new;
                user.guildNicknames[guildId] = nick;
            }
        }
        if (self.selectedChannel &&
            [self.selectedChannel.parentGuild.snowflake isEqualToString:guildId]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"GuildMemberListUpdated" object:nil];
            });
        }
    } else {
        DBGLOG(@"Unhandled event type: %@, content: %@", t, d);
        return;
    }
}

- (void)handleBackgroundEntry {
    self.applicationSuspended = YES;

    /*
     * Invalidate any delayed reconnect block. It will check this
     * generation before starting a replacement socket.
     */
    self.reconnectGeneration++;

    if (self.isReconnecting) {
        self.isReconnecting = NO;
        self.reconnectPendingAfterForeground = YES;
    }

    [self stopHeartbeatTimer];

    DBGLOG(@"[Background] Heartbeat and reconnect work suspended");
}

- (void)handleForegroundEntry {
    self.applicationSuspended = NO;

    BOOL definitelyNeedsReconnect =
        self.reconnectPendingAfterForeground ||
        !self.websocket ||
        !self.didAuthenticate;

    self.reconnectPendingAfterForeground = NO;

    if (definitelyNeedsReconnect) {
        DBGLOG(@"[Foreground] Connection unavailable — reconnecting");
        [self reconnect];
        return;
    }

    /*
     * Do not call sendHeartbeat: here. That method contains the normal
     * periodic missing-ACK watchdog and may reconnect based on stale
     * pre-suspension state.
     */
    NSDate *probeTime = [NSDate date];
    self.gotHeartbeat = NO;

    DBGLOG(@"[Foreground] Sending direct probe heartbeat");

    [self sendJSON:@{
        @"op" : @(DCGatewayOpCodeHeartbeat),
        @"d"  : @(self.sequenceNumber)
    }];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(5.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            /*
             * User may have backgrounded the app again while the
             * probe was outstanding.
             */
            if (self.applicationSuspended) {
                return;
            }

            BOOL ackReceived =
                self.lastHeartbeatAckDate &&
                [self.lastHeartbeatAckDate
                    timeIntervalSinceDate:probeTime] > 0.0;

            if (!ackReceived) {
                DBGLOG(@"[Foreground] Probe timed out — reconnecting");
                [self reconnect];
                return;
            }

            DBGLOG(@"[Foreground] Existing connection is healthy");

            [self restartHeartbeatTimerAfterProbe];

            [NSNotificationCenter.defaultCenter
                postNotificationName:@"CONNECTION_RESTORED"
                              object:nil];
        });
}

#pragma mark - WebSocket Handlers

- (void)startCommunicator {
    DBGLOG(@"Starting communicator!");

    if (self.token == nil) {
        DBGLOG(@"No token set, cannot start communicator");
        return;
    }

    if (self.websocket) {
        DBGLOG(@"Websocket already open, not doing anything");
        return;
    }

    [self initInflateStream];
    [self.alertView show];
    self.didAuthenticate = false;
    self.oldMode         = [[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"];

    // Dev
    // [DCTools checkForAppUpdate];
    // Devend

    

    DBGLOG(@"Start websocket");

    // To prevent retain cycle
    __weak typeof(self) weakSelf = self;

    
    // Establish websocket connection with Discord. If we still have a session
    // that handleHelloWithData: will attempt to RESUME, use the per-session
    // resume gateway supplied by READY.
    BOOL hasResumableSession =
        self.sequenceNumber != 0 && [self.sessionId length] > 0;

    NSString *gatewayBaseURL = self.gatewayURL;
    if (hasResumableSession && [self.resumeGatewayURL length] > 0) {
        gatewayBaseURL = self.resumeGatewayURL;
    }

    NSString *connectionURLString = DCConfiguredGatewayURL(gatewayBaseURL);
    NSURL *websocketUrl = [NSURL URLWithString:connectionURLString];

    if (hasResumableSession && [self.resumeGatewayURL length] > 0) {
        DBGLOG(@"Opening resume gateway: %@", connectionURLString);
    } else if (hasResumableSession) {
        DBGLOG(@"Resume state exists but no resume_gateway_url is cached; using primary gateway: %@",
               connectionURLString);
    } else {
        DBGLOG(@"Opening primary gateway: %@", connectionURLString);
    }

    WSWebSocket *thisSocket = [[WSWebSocket alloc] initWithURL:websocketUrl protocols:nil];
    self.websocket = thisSocket;

    self.websocket.closeCallback = ^(NSUInteger statusCode, NSString *message) {
        // If this socket has already been replaced, ignore the callback entirely
        if (weakSelf.websocket != thisSocket) {
            DBGLOG(@"Stale closeCallback ignored (socket already replaced)");
            return;
        }
        DBGLOG(@"Websocket closed with status code %lu and message: %@", (unsigned long)statusCode, message);
        if (statusCode == 1000) {
            // we closed it, do nothing
            return;
        } else if (statusCode == 2) {
            // kCFErrorDomainCFNetwork error 2 => DNS failure, likely not connected to the internet
            DBGLOG(@"DNS failure, likely not connected to the internet");
            [weakSelf reconnect];
        } else if (statusCode == 4004) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf performLogout];
            });
        } else {
            // some other error, try to reconnect
            [weakSelf reconnect];
        }
    };
    thisSocket.dataCallback = ^(NSData *data) {
        if (weakSelf.websocket != thisSocket) {
            DBGLOG(@"Ignoring data from stale WebSocket");
            return;
        }
        NSString *responseString = [weakSelf inflateGatewayData:data];
        if (!responseString) return; // incomplete message, waiting for more frames

        NSDictionary *parsedJsonResponse = [DCTools parseJSON:responseString];
        int op          = [[parsedJsonResponse objectForKey:@"op"] integerValue];
        NSDictionary *d = [parsedJsonResponse objectForKey:@"d"];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            switch (op) {
                case DCGatewayOpCodeHello: {
                    [weakSelf handleHelloWithData:d];
                    break;
                }
                case DCGatewayOpCodeDispatch: {
                    [weakSelf handleDispatchWithResponse:parsedJsonResponse];
                    break;
                }
                case DCGatewayOpCodeHeartbeat: {
                    // ack with our own heartbeat
                    [weakSelf sendJSON:@{
                        @"op" : @(DCGatewayOpCodeHeartbeat),
                        @"d" : @(weakSelf.sequenceNumber)
                    }];
                    break;
                    // fallthrough to HEARTBEAT_ACK
                }
                case DCGatewayOpCodeHeartbeatAck: {
                #ifdef DEBUG
                if (heartbeatTimer && heartbeatTimer.fireDate) {
                    NSDate *now = [NSDate date];
                    NSDate *previousFireDate =
                        [heartbeatTimer.fireDate
                            dateByAddingTimeInterval:
                                -heartbeatTimer.timeInterval];

                    DBGLOG(@"Got heartbeat ack in %f seconds!",
                           [now timeIntervalSinceDate:previousFireDate]);
                } else {
                    DBGLOG(@"Got heartbeat ACK");
                }
                #endif
                    weakSelf.gotHeartbeat = true;
                    weakSelf.lastHeartbeatAckDate = [NSDate date];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                    });
                    if (weakSelf.didAuthenticate && weakSelf.guilds.count > 0) {
                        DCCacheManager *cache = [DCCacheManager sharedInstance];
                        [cache saveGuilds:weakSelf.guilds];
                        [cache saveUserInfo:weakSelf.currentUserInfo];
                        DBGLOG(@"[HeartbeatACK] Flushed cold-start cache");
                    }
                    break;
                }
                case DCGatewayOpCodeReconnect: {
                    DBGLOG(@"Got RECONNECT, reconnecting...");
                    [weakSelf reconnect];
                    break;
                }
                case DCGatewayOpCodeInvalidSession: {
                    if ([(NSNumber *)d boolValue]) {
                        // Session is resumable — Discord says wait 1-5s before retrying
                        DBGLOG(@"INVALID_SESSION: resumable, retrying in 2s...");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [weakSelf reconnect];
                        });
                    } else {
                        // Hard invalidation — drop session state and do a clean identify
                        DBGLOG(@"INVALID_SESSION: invalidated, clearing session and reconnecting...");
                        weakSelf.sequenceNumber  = 0;
                        weakSelf.sessionId       = nil;
                        weakSelf.resumeGatewayURL = nil;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf reconnect];
                        });
                    }
                    break;
                }
                default: {
                    DBGLOG(@"Unhandled op code: %i, content: %@", op, d);
                    break;
                }
            }
        });
    };

    [self.websocket open];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 999 && buttonIndex == 0) {
        // following code by https://stackoverflow.com/a/17802404

        //home button press programmatically
        UIApplication *app = [UIApplication sharedApplication];
        [app performSelector:@selector(suspend)];
    
        //wait 2 seconds while app is going background
        [NSThread sleepForTimeInterval:2.0];
    
        //exit app when app is in background
        exit(EXIT_SUCCESS);
    }
}

- (void)reconnect {
    // Always marshal to main queue to serialize all reconnect logic
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.applicationSuspended) {
            DBGLOG(@"Reconnect requested while suspended — deferring");

            self.reconnectPendingAfterForeground = YES;
            return;
        }
        // Reentrance guard — drop duplicate calls while one is already queued
        if (self.isReconnecting) {
            DBGLOG(@"Reconnect already in progress, ignoring duplicate call");
            return;
        }
        self.isReconnecting = YES;

        NSUInteger reconnectGeneration = ++self.reconnectGeneration;

        // Tear down existing connection cleanly
        [heartbeatTimer invalidate];
        heartbeatTimer = nil;
        if (self.websocket) {
            [self.websocket close];
            [self resetInflateStream];
            self.websocket = nil;
        }

        if (self.guilds.count > 0 && self.selectedChannel) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:@"BACKGROUND_RECONNECT"
                                                                  object:nil];
            });
        }

        // Exponential backoff: 1s, 2s, 4s, 8s, ... capped at 60s
        NSTimeInterval backoff = MIN(pow(2.0, (double)self.reconnectAttempts), 60.0);
        self.reconnectAttempts++;

        // Also respect the identify cooldown if one is in effect
        NSTimeInterval cooldownRemaining = self.cooldownTimer 
            ? MAX(0.0, [self.cooldownTimer.fireDate timeIntervalSinceNow]) 
            : 0.0;
        NSTimeInterval delay = MAX(backoff, cooldownRemaining);

        DBGLOG(@"Reconnecting in %.1f seconds (attempt %ld)", delay, (long)self.reconnectAttempts);
        NSString *bannerTitle = (self.guilds.count > 0 && self.selectedChannel)
            ? @"Refreshing..."
            : @"Reconnecting...";
        [self showNonIntrusiveNotificationWithTitle:bannerTitle];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                /*
                 * A background transition, newer reconnect, or logout may have
                 * invalidated this attempt.
                 */
                if (reconnectGeneration != self.reconnectGeneration) {
                    DBGLOG(@"Discarding stale reconnect attempt");
                    return;
                }

                if (self.applicationSuspended) {
                    self.isReconnecting = NO;
                    self.reconnectPendingAfterForeground = YES;
                    return;
                }

                self.isReconnecting = NO;

                if (!self.token) {
                    return;
                }

                [self startCommunicator];
        });
    });
}

- (void)jitterBeat:(NSTimer *)timer {
    // Don't reset gotHeartbeat here — send the first heartbeat
    // but let the ACK arrive before arming the failure check
    [self sendJSON:@{
        @"op" : @(DCGatewayOpCodeHeartbeat),
        @"d" : @(self.sequenceNumber)
    }];
    DBGLOG(@"Sending jitterbeat, starting heartbeat cycle");
    float heartbeatInterval = [[timer.userInfo objectForKey:@"heartbeatInterval"] floatValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:heartbeatInterval
                                                          target:self
                                                        selector:@selector(sendHeartbeat:)
                                                        userInfo:nil
                                                         repeats:YES];
    });
}

- (void)sendHeartbeat:(NSTimer *)timer {
    if (!self.gotHeartbeat) {
        if (!self.didAuthenticate) {
            DBGLOG(@"Missing heartbeat ACK pre-READY, giving connection more time");
            return;
        }
        DBGLOG(@"Did not get heartbeat response, reconnecting...");
        [self reconnect];
        return;
    }
    // ACK was received — send next heartbeat and arm the check for next interval
    self.gotHeartbeat = false;
    [self sendJSON:@{
        @"op" : @(DCGatewayOpCodeHeartbeat),
        @"d" : @(self.sequenceNumber)
    }];
    DBGLOG(@"Sent heartbeat");
}

- (void)stopHeartbeatTimer {
    NSAssert([NSThread isMainThread],
             @"Heartbeat timer must be managed on the main thread");

    [heartbeatTimer invalidate];
    heartbeatTimer = nil;
}

- (void)restartHeartbeatTimerAfterProbe {
    NSAssert([NSThread isMainThread],
             @"Heartbeat timer must be managed on the main thread");

    [heartbeatTimer invalidate];
    heartbeatTimer = nil;

    if (self.heartbeatInterval <= 0.0 || self.applicationSuspended || !self.didAuthenticate) {
        return;
    }

    /*
     * The foreground probe was acknowledged, so the next timer firing
     * is allowed to send a new heartbeat.
     */
    self.gotHeartbeat = YES;

    heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:self.heartbeatInterval
                                                      target:self
                                                    selector:@selector(sendHeartbeat:)
                                                    userInfo:nil
                                                     repeats:YES];
}

// Once the 5 second identify cooldown is over
- (void)refreshcanIdentify:(NSTimer *)timer {
    self.canIdentify = true;
    DBGLOG(@"Authentication cooldown ended");
}

- (void)initInflateStream {
    if (self.inflateStreamReady) {
        inflateEnd(&_inflateStream);
    }
    memset(&_inflateStream, 0, sizeof(z_stream));
    int ret = inflateInit(&_inflateStream);
    if (ret != Z_OK) {
        DBGLOG(@"zlib inflateInit failed: %d", ret);
        self.inflateStreamReady = NO;
        return;
    }
    self.inflateStreamReady = YES;
    self.compressedBuffer = [NSMutableData dataWithCapacity:4096];
    DBGLOG(@"zlib inflate stream initialized");
}

- (void)resetInflateStream {
    if (self.inflateStreamReady) {
        inflateEnd(&_inflateStream);
        self.inflateStreamReady = NO;
    }
    self.compressedBuffer = nil;
}

- (NSString *)inflateGatewayData:(NSData *)data {
    if (!self.inflateStreamReady) return nil;

    [self.compressedBuffer appendData:data];

    // Check for zlib sync flush suffix: 0x00 0x00 0xFF 0xFF
    // Discord appends this to every complete message
    NSUInteger len = self.compressedBuffer.length;
    if (len < 4) return nil;
    const uint8_t *bytes = self.compressedBuffer.bytes;
    if (bytes[len-4] != 0x00 || bytes[len-3] != 0x00 ||
        bytes[len-2] != 0xFF || bytes[len-1] != 0xFF) {
        // Message not complete yet — more frames incoming
        return nil;
    }

    // Inflate the complete message
    NSMutableData *decompressed = [NSMutableData dataWithCapacity:len * 4];
    uint8_t outBuffer[32768];

    _inflateStream.next_in  = (Bytef *)self.compressedBuffer.bytes;
    _inflateStream.avail_in = (uInt)len;

    int ret;
    do {
        _inflateStream.next_out  = outBuffer;
        _inflateStream.avail_out = sizeof(outBuffer);
        ret = inflate(&_inflateStream, Z_SYNC_FLUSH);
        if (ret < 0) {
            DBGLOG(@"zlib inflate error: %d (%s)", ret,
                   _inflateStream.msg ? _inflateStream.msg : "unknown");
            [self resetInflateStream];
            [self initInflateStream]; // recover for next connection
            return nil;
        }
        [decompressed appendBytes:outBuffer
                           length:sizeof(outBuffer) - _inflateStream.avail_out];
    } while (_inflateStream.avail_in > 0);

    // Clear buffer for next message — but keep the z_stream context alive
    [self.compressedBuffer setLength:0];

    return [[NSString alloc] initWithData:decompressed encoding:NSUTF8StringEncoding];
}

- (void)sendJSON:(NSDictionary *)dictionary {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *writeError = nil;

        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:NSJSONWritingPrettyPrinted error:&writeError];

        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [self.websocket sendText:jsonString];
    });
}

- (void)description {
    NSLog(@"DCServerCommunicator lengths: \n"
           "channels: %lu (element %zu)\n"
           "guilds: %lu (element %zu)\n"
           "loadedUsers: %lu (element %zu)\n"
           "loadedRoles: %lu (element %zu)\n",
          (unsigned long)self.channels.count, malloc_size((__bridge const void *)(self.channels.allValues.firstObject)), (unsigned long)self.guilds.count, malloc_size((__bridge const void *)(self.guilds.firstObject)), (unsigned long)self.loadedUsers.count, malloc_size((__bridge const void *)(self.loadedUsers.allValues.firstObject)), (unsigned long)self.loadedRoles.count, malloc_size((__bridge const void *)(self.loadedRoles.allValues.firstObject)));
}

- (void)prepareForLogout {
    dispatch_async(dispatch_get_main_queue(), ^{
        [heartbeatTimer invalidate];
        heartbeatTimer = nil;
    });
    [self.cooldownTimer invalidate];
    self.cooldownTimer  = nil;
    self.canIdentify    = YES;
    self.sessionId        = nil;
    self.resumeGatewayURL = nil;
    self.sequenceNumber   = 0;
    [self.websocket close];
    self.websocket = nil;
    [self resetInflateStream];
    self.isReconnecting = NO;
    self.reconnectAttempts = 0;
}

- (void)performLogout {
    // Nil token first so callbacks during teardown can't trigger a reconnect
    self.token           = nil;
    self.didAuthenticate = NO;

    [self prepareForLogout];

    self.currentUserInfo     = nil;
    self.guilds              = nil;
    self.channels            = nil;
    self.loadedUsers         = nil;
    self.loadedRoles         = nil;
    self.loadedEmojis        = nil;
    self.selectedGuild       = nil;
    self.selectedChannel     = nil;
    self.userChannelSettings = nil;

    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"token"];
    [NSUserDefaults.standardUserDefaults synchronize];

    [[DCCacheManager sharedInstance] invalidateAllMessages];
    [[DCCacheManager sharedInstance] invalidateUserCache];
    [[DCCacheManager sharedInstance] handleMemoryWarning];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"DCUserDidLogOut" object:nil];
}

@end