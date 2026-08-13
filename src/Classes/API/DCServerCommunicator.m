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
#include <pthread.h>

/* The canonical user registry is shared across several queues. A reader/writer
 * lock keeps lookups synchronous with writes without introducing a dispatch
 * barrier backlog. */
static pthread_rwlock_t DCUserRegistryLock = PTHREAD_RWLOCK_INITIALIZER;

typedef NS_OPTIONS(NSUInteger, DCReadyChannelCommitFields) {
    DCReadyChannelCommitHasParentID      = 1 << 0,
    DCReadyChannelCommitHasName          = 1 << 1,
    DCReadyChannelCommitHasLastMessageID = 1 << 2,
    DCReadyChannelCommitHasType          = 1 << 3,
    DCReadyChannelCommitHasPosition      = 1 << 4,
    DCReadyChannelCommitHasIconID        = 1 << 5,
    DCReadyChannelCommitHasWriteability  = 1 << 6,
};

// Detached channel state prepared off-main and committed onto canonical objects.
@interface DCReadyChannelCommit : NSObject
@property (strong, nonatomic) NSString *snowflake;
@property (strong, nonatomic) NSString *parentID;
@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *lastMessageID;
@property (strong, nonatomic) NSString *iconID;
@property (assign, nonatomic) DCChannelType type;
@property (assign, nonatomic) NSInteger position;
@property (assign, nonatomic) BOOL writeable;
@property (assign, nonatomic) NSUInteger overwriteCount;
@property (assign, nonatomic) DCReadyChannelCommitFields fields;
@end

@implementation DCReadyChannelCommit
@end

typedef NS_OPTIONS(NSUInteger, DCReadyUserCommitFields) {
    DCReadyUserCommitHasUsername           = 1 << 0,
    DCReadyUserCommitHasGlobalName         = 1 << 1,
    DCReadyUserCommitHasAvatarID           = 1 << 2,
    DCReadyUserCommitHasAvatarDecorationID = 1 << 3,
    DCReadyUserCommitHasDiscriminator      = 1 << 4,
    DCReadyUserCommitHasStatus             = 1 << 5,
};

// Detached user state prepared off-main and committed onto canonical objects.
@interface DCReadyUserCommit : NSObject
@property (strong, nonatomic) NSString *snowflake;
@property (strong, nonatomic) NSString *username;
@property (strong, nonatomic) NSString *globalName;
@property (strong, nonatomic) NSString *avatarID;
@property (strong, nonatomic) NSString *avatarDecorationID;
@property (strong, nonatomic) NSString *relationshipNickname;
@property (assign, nonatomic) NSInteger discriminator;
@property (assign, nonatomic) DCUserStatus status;
@property (assign, nonatomic) DCReadyUserCommitFields fields;
@end

@implementation DCReadyUserCommit
@end

typedef struct {
    CFTimeInterval metadata;
    CFTimeInterval metadataCore;
    CFTimeInterval metadataRoles;
    CFTimeInterval metadataEmojis;
    CFTimeInterval metadataMembers;
    CFTimeInterval channelMerge;
    CFTimeInterval channelSetup;
    CFTimeInterval channelSort;
    CFTimeInterval channelResolve;
    CFTimeInterval channelProperties;
    CFTimeInterval channelPermissions;
    CFTimeInterval channelMembership;
    NSUInteger rolesProcessed;
    NSUInteger emojisProcessed;
    NSUInteger membersProcessed;
    NSUInteger channelsProcessed;
    NSUInteger channelsWithoutOverwrites;
    NSUInteger channelsWithOverwrites;
    NSUInteger permissionOverwriteEntries;
    NSUInteger staleChannelsRemoved;
} DCReadyGuildReconcilePerf;

@interface DCServerCommunicator (ReadyReconcilePrivate)
- (void)mergeGuildCreateSnapshot:(NSDictionary *)d
                       intoGuild:(DCGuild *)guild
                        forReady:(BOOL)forReady
          preparedChannelCommits:(NSDictionary *)preparedChannelCommits
              preparedChannelOrder:(NSArray *)preparedChannelOrder
                 preparedRoles:(NSMutableDictionary *)preparedRoles
                preparedEmojis:(NSMutableDictionary *)preparedEmojis
                            perf:(DCReadyGuildReconcilePerf *)perf;
- (void)mergeChannel:(DCChannel *)channel
             fromData:(NSDictionary *)d
                guild:(DCGuild *)guild
          userRoleSet:(NSSet *)userRoleSet
       preparedCommit:(DCReadyChannelCommit *)preparedCommit
                 perf:(DCReadyGuildReconcilePerf *)perf;
- (DCReadyUserCommit *)readyUserCommitFromJSON:(NSDictionary *)jsonUser;
- (DCUser *)applyReadyUserCommit:(DCReadyUserCommit *)commit;
- (NSDictionary *)prepareReadyCommitHints:(NSDictionary *)d;
- (void)handleReadyWithData:(NSDictionary *)d preparedHints:(NSDictionary *)preparedHints;
- (NSMutableArray *)reconcileReadyGuilds:(NSArray *)guildJsons
                           mergedMembers:(NSArray *)mergedMembers
                            privateGuild:(DCGuild *)privateGuild
                           preparedHints:(NSDictionary *)preparedHints;
@end

@implementation DCServerCommunicator
UIActivityIndicatorView *spinner;
NSTimer *heartbeatTimer = nil;
// Discord dispatch sequence numbers describe an ordered state stream. Keep
// state mutation on one serial queue so a durable sequence can never outrun an
// earlier event that is still being applied on another worker thread.
static dispatch_queue_t gatewayEventQueue = NULL;

// Bulk READY reconciliation uses local snapshots and publishes them once complete.
static NSThread *readyBulkCacheThread = nil;
static NSMutableDictionary *readyBulkUsers = nil;
static NSMutableDictionary *readyBulkRoles = nil;
static NSMutableDictionary *readyBulkEmojis = nil;

/*
 * READY provides resume_gateway_url without guaranteeing the initial Gateway
 * query parameters. Discord
 * requires Resume to use the same API version, encoding, and compression.
 *
 * Keep this helper Foundation-only so it remains compatible with iOS 5/6
 * (NSURLComponents is unavailable on the deployment target).
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
 * keep the guild sidebar synchronized is unnecessary on this deployment target, so
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
        // iOS 5 fallback: generate and persist a vendor ID
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
        if (!gatewayEventQueue) {
            gatewayEventQueue = dispatch_queue_create(
                "Discord::Gateway::State", DISPATCH_QUEUE_SERIAL);
        }

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
- (void)beginReadyBulkEntityCache {
    // Bulk maps are owned by the thread that opened the reconciliation pass.
    if (readyBulkCacheThread) return;

    NSDictionary *users = nil;
    __block NSDictionary *roles = nil;
    __block NSDictionary *emojis = nil;

    pthread_rwlock_rdlock(&DCUserRegistryLock);
    users = [NSDictionary dictionaryWithDictionary:self.loadedUsers ?: @{}];
    pthread_rwlock_unlock(&DCUserRegistryLock);

    dispatch_sync(self.accessQueue, ^{
        roles = [NSDictionary dictionaryWithDictionary:self.loadedRoles ?: @{}];
        emojis = [NSDictionary dictionaryWithDictionary:self.loadedEmojis ?: @{}];
    });

    readyBulkUsers = [users mutableCopy];
    readyBulkRoles = [roles mutableCopy];
    readyBulkEmojis = [emojis mutableCopy];
    readyBulkCacheThread = [NSThread currentThread];
}

- (void)endReadyBulkEntityCache {
    if (readyBulkCacheThread != [NSThread currentThread]) return;

    NSMutableDictionary *users = readyBulkUsers;
    NSMutableDictionary *roles = readyBulkRoles;
    NSMutableDictionary *emojis = readyBulkEmojis;

    // Stop routing lookups to local maps before publishing them.
    readyBulkCacheThread = nil;
    readyBulkUsers = nil;
    readyBulkRoles = nil;
    readyBulkEmojis = nil;

    pthread_rwlock_wrlock(&DCUserRegistryLock);
    if (!self.loadedUsers) self.loadedUsers = [NSMutableDictionary dictionary];
    // Merge so concurrent cache hydration is not discarded; live data wins.
    [self.loadedUsers addEntriesFromDictionary:users];
    pthread_rwlock_unlock(&DCUserRegistryLock);

    dispatch_barrier_sync(self.accessQueue, ^{
        if (!self.loadedRoles) self.loadedRoles = [NSMutableDictionary dictionary];
        if (!self.loadedEmojis) self.loadedEmojis = [NSMutableDictionary dictionary];
        [self.loadedRoles addEntriesFromDictionary:roles];
        [self.loadedEmojis addEntriesFromDictionary:emojis];
    });
}

- (DCUser *)userForSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    if (readyBulkCacheThread == [NSThread currentThread] && readyBulkUsers) {
        return [readyBulkUsers objectForKey:snowflake];
    }

    CFAbsoluteTime waitStart = CFAbsoluteTimeGetCurrent();
    pthread_rwlock_rdlock(&DCUserRegistryLock);
    DCUser *user = self.loadedUsers[snowflake];
    pthread_rwlock_unlock(&DCUserRegistryLock);
    NSTimeInterval waitTime = CFAbsoluteTimeGetCurrent() - waitStart;
    if (waitTime >= 0.020) {
        NSLog(@"[EntityPerf] user lookup %@ waited %.1fms%@",
              snowflake,
              waitTime * 1000.0,
              [NSThread isMainThread] ? @" on main" : @"");
    }
    return user;
}

- (void)setUser:(DCUser *)user forSnowflake:(NSString *)snowflake {
    if (!snowflake || !user) return;
    if (readyBulkCacheThread == [NSThread currentThread] && readyBulkUsers) {
        [readyBulkUsers setObject:user forKey:snowflake];
        return;
    }
    pthread_rwlock_wrlock(&DCUserRegistryLock);
    if (!self.loadedUsers) self.loadedUsers = [NSMutableDictionary dictionary];
    self.loadedUsers[snowflake] = user;
    pthread_rwlock_unlock(&DCUserRegistryLock);
}

- (void)ensureLoadedUsersRegistry {
    pthread_rwlock_wrlock(&DCUserRegistryLock);
    if (!self.loadedUsers) self.loadedUsers = [NSMutableDictionary dictionary];
    pthread_rwlock_unlock(&DCUserRegistryLock);
}

- (NSDictionary *)loadedUsersSnapshot {
    pthread_rwlock_rdlock(&DCUserRegistryLock);
    NSDictionary *snapshot = [NSDictionary dictionaryWithDictionary:self.loadedUsers ?: @{}];
    pthread_rwlock_unlock(&DCUserRegistryLock);
    return snapshot;
}

- (void)mergeCachedUsers:(NSDictionary *)cachedUsers {
    if (![cachedUsers isKindOfClass:[NSDictionary class]] || cachedUsers.count == 0)
        return;

    /* Merge cached users conservatively so live Gateway data wins. Release the
     * registry lock between records to keep readers responsive during hydration. */
    NSMutableArray *changedPlaceholders = [NSMutableArray array];
    [self ensureLoadedUsersRegistry];

    for (NSString *snowflake in cachedUsers) {
        DCUser *cached = [cachedUsers objectForKey:snowflake];
        if (![cached isKindOfClass:[DCUser class]] || !snowflake.length)
            continue;

        pthread_rwlock_wrlock(&DCUserRegistryLock);
        DCUser *existing = [self.loadedUsers objectForKey:snowflake];
        if (!existing) {
            // No live identity object exists yet, so the cached status is the
            // best available resumable baseline.
            [self.loadedUsers setObject:cached forKey:snowflake];
            pthread_rwlock_unlock(&DCUserRegistryLock);
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

        if (![self.livePresenceUserIDs containsObject:snowflake] &&
            existing.status != cached.status) {
            existing.status = cached.status;
            changed = YES;
        }

        if (!existing.guildNicknames)
            existing.guildNicknames = [NSMutableDictionary dictionary];
        for (NSString *guildID in cached.guildNicknames) {
            if (![existing.guildNicknames objectForKey:guildID]) {
                id nickname = [cached.guildNicknames objectForKey:guildID];
                if (nickname)
                    [existing.guildNicknames setObject:nickname forKey:guildID];
            }
        }
        pthread_rwlock_unlock(&DCUserRegistryLock);

        if (changed) [changedPlaceholders addObject:existing];
    }

    if (changedPlaceholders.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (DCUser *user in changedPlaceholders) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD USER DATA"
                                  object:user];
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"USER_PRESENCE_UPDATED"
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
    if (readyBulkCacheThread == [NSThread currentThread] && readyBulkRoles) {
        return [readyBulkRoles objectForKey:snowflake];
    }
    __block DCRole *role;
    dispatch_sync(self.accessQueue, ^{
        role = self.loadedRoles[snowflake];
    });
    return role;
}

- (void)setRole:(DCRole *)role forSnowflake:(NSString *)snowflake {
    if (!snowflake || !role) return;
    if (readyBulkCacheThread == [NSThread currentThread] && readyBulkRoles) {
        [readyBulkRoles setObject:role forKey:snowflake];
        return;
    }
    dispatch_barrier_async(self.accessQueue, ^{
        self.loadedRoles[snowflake] = role;
    });
}

- (DCEmoji *)emojiForSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    if (readyBulkCacheThread == [NSThread currentThread] && readyBulkEmojis) {
        return [readyBulkEmojis objectForKey:snowflake];
    }
    __block DCEmoji *emoji;
    dispatch_sync(self.accessQueue, ^{
        emoji = self.loadedEmojis[snowflake];
    });
    return emoji;
}

- (void)setEmoji:(DCEmoji *)emoji forSnowflake:(NSString *)snowflake {
    if (!snowflake || !emoji) return;
    if (readyBulkCacheThread == [NSThread currentThread] && readyBulkEmojis) {
        [readyBulkEmojis setObject:emoji forKey:snowflake];
        return;
    }
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
    for (DCGuild *guild in self.guilds) {
        for (DCChannel *channel in guild.channels) {
            if ([channel.snowflake isEqualToString:channelId]) {
                return channel;
            }
        }
    }
    return nil;
}

- (DCReadyUserCommit *)readyUserCommitFromJSON:(NSDictionary *)jsonUser {
    if (![jsonUser isKindOfClass:[NSDictionary class]]) return nil;
    NSString *snowflake = [jsonUser objectForKey:@"id"];
    if (![snowflake isKindOfClass:[NSString class]] || !snowflake.length) return nil;

    DCReadyUserCommit *commit = [DCReadyUserCommit new];
    commit.snowflake = snowflake;
    id value = [jsonUser objectForKey:@"username"];
    if ([value isKindOfClass:[NSString class]]) {
        commit.fields |= DCReadyUserCommitHasUsername;
        commit.username = value;
    }
    if ([jsonUser objectForKey:@"global_name"] != nil) {
        commit.fields |= DCReadyUserCommitHasGlobalName;
        value = [jsonUser objectForKey:@"global_name"];
        commit.globalName = [value isKindOfClass:[NSString class]] ? value : nil;
    }
    if ([jsonUser objectForKey:@"avatar"] != nil) {
        commit.fields |= DCReadyUserCommitHasAvatarID;
        value = [jsonUser objectForKey:@"avatar"];
        commit.avatarID = [value isKindOfClass:[NSString class]] ? value : nil;
    }
    if ([jsonUser objectForKey:@"avatar_decoration_data"] != nil) {
        commit.fields |= DCReadyUserCommitHasAvatarDecorationID;
        id decorationData = [jsonUser objectForKey:@"avatar_decoration_data"];
        if ([decorationData isKindOfClass:[NSDictionary class]]) {
            id asset = [decorationData objectForKey:@"asset"];
            commit.avatarDecorationID = [asset isKindOfClass:[NSString class]] ? asset : nil;
        }
    }
    value = [jsonUser objectForKey:@"discriminator"];
    if ([value respondsToSelector:@selector(integerValue)]) {
        commit.fields |= DCReadyUserCommitHasDiscriminator;
        commit.discriminator = [value integerValue];
    }
    return commit;
}

- (DCUser *)applyReadyUserCommit:(DCReadyUserCommit *)commit {
    if (![commit isKindOfClass:[DCReadyUserCommit class]] || !commit.snowflake.length) return nil;
    DCUser *user = [self userForSnowflake:commit.snowflake];
    BOOL createdUser = (user == nil);
    if (!user) {
        DCReadyUserCommitFields identityFields =
            DCReadyUserCommitHasUsername | DCReadyUserCommitHasGlobalName |
            DCReadyUserCommitHasAvatarID | DCReadyUserCommitHasAvatarDecorationID |
            DCReadyUserCommitHasDiscriminator;
        // The old READY path ignored presence/nickname-only records when the
        // corresponding canonical user was absent. Preserve that behavior
        // instead of manufacturing anonymous users solely from status data.
        if ((commit.fields & identityFields) == 0) return nil;
        user = [DCUser new];
    }
    user.snowflake = commit.snowflake;

    if (commit.fields & DCReadyUserCommitHasUsername)
        user.username = commit.username;
    if (commit.fields & DCReadyUserCommitHasGlobalName)
        user.globalName = commit.globalName;

    if (commit.fields & DCReadyUserCommitHasAvatarID) {
        NSString *oldAvatarID = [user.avatarID isKindOfClass:[NSString class]] ? (NSString *)user.avatarID : nil;
        NSString *newAvatarID = commit.avatarID;
        BOOL changed = (oldAvatarID != newAvatarID) && ![oldAvatarID isEqualToString:newAvatarID];
        if (changed) {
            user.avatarID = newAvatarID;
            user.profileImage = nil;
            user.rawProfileImage = nil;
        } else if (createdUser) {
            user.avatarID = newAvatarID;
        }
    }

    if (commit.fields & DCReadyUserCommitHasAvatarDecorationID) {
        NSString *oldDecorationID = [user.avatarDecorationID isKindOfClass:[NSString class]]
            ? (NSString *)user.avatarDecorationID : nil;
        NSString *newDecorationID = commit.avatarDecorationID;
        BOOL changed = (oldDecorationID != newDecorationID) && ![oldDecorationID isEqualToString:newDecorationID];
        if (changed) {
            user.avatarDecorationID = newDecorationID;
            user.avatarDecoration = nil;
            user.profileImage = nil;
        } else if (createdUser) {
            user.avatarDecorationID = newDecorationID;
        }
    }

    if (commit.fields & DCReadyUserCommitHasDiscriminator)
        user.discriminator = commit.discriminator;
    if (createdUser)
        user.status = DCUserStatusOffline;
    if (commit.fields & DCReadyUserCommitHasStatus)
        user.status = commit.status;
    if (!user.guildNicknames) user.guildNicknames = [NSMutableDictionary dictionary];
    if (commit.relationshipNickname.length) user.globalName = commit.relationshipNickname;

    [self setUser:user forSnowflake:commit.snowflake];
    return user;
}

- (NSDictionary *)prepareReadyCommitHints:(NSDictionary *)d {
    NSArray *guildJsons = [d objectForKey:@"guilds"];
    NSArray *mergedMembers = [d objectForKey:@"merged_members"];
    NSString *currentUserID = [d valueForKeyPath:@"user.id"];
    if (![guildJsons isKindOfClass:[NSArray class]] ||
        ![currentUserID isKindOfClass:[NSString class]]) {
        return [NSDictionary dictionary];
    }

    NSMutableDictionary *channelCommitsByID =
        [NSMutableDictionary dictionaryWithCapacity:4096];
    NSMutableDictionary *orderByGuildID =
        [NSMutableDictionary dictionaryWithCapacity:guildJsons.count];
    NSMutableDictionary *rolesByGuildID =
        [NSMutableDictionary dictionaryWithCapacity:guildJsons.count];
    NSMutableDictionary *emojisByGuildID =
        [NSMutableDictionary dictionaryWithCapacity:guildJsons.count];
    NSArray *rawReadyUsers = [d objectForKey:@"users"];
    NSMutableDictionary *userCommitsByID = [NSMutableDictionary dictionaryWithCapacity:
        ([rawReadyUsers isKindOfClass:[NSArray class]] ? rawReadyUsers.count : 0) + 1];
    NSMutableSet *livePresenceIDs = [NSMutableSet set];

    CFAbsoluteTime userPrepareStarted = CFAbsoluteTimeGetCurrent();
    NSUInteger preparedUsers = 0;
    DCReadyUserCommit *currentUserCommit = [self readyUserCommitFromJSON:[d objectForKey:@"user"]];
    if (currentUserCommit) {
        [userCommitsByID setObject:currentUserCommit forKey:currentUserCommit.snowflake];
        preparedUsers++;
    }
    if ([rawReadyUsers isKindOfClass:[NSArray class]]) {
        for (NSDictionary *userData in rawReadyUsers) {
            DCReadyUserCommit *commit = [self readyUserCommitFromJSON:userData];
            if (!commit) continue;
            [userCommitsByID setObject:commit forKey:commit.snowflake];
            preparedUsers++;
        }
    }

    NSArray *relationships = [d objectForKey:@"relationships"];
    if ([relationships isKindOfClass:[NSArray class]]) {
        for (NSDictionary *relationship in relationships) {
            if (![relationship isKindOfClass:[NSDictionary class]]) continue;
            NSString *userID = [relationship objectForKey:@"id"];
            if (![userID isKindOfClass:[NSString class]])
                userID = [relationship valueForKeyPath:@"user.id"];
            if (![userID isKindOfClass:[NSString class]] || !userID.length) continue;
            DCReadyUserCommit *commit = [userCommitsByID objectForKey:userID];
            if (!commit) {
                commit = [self readyUserCommitFromJSON:[relationship objectForKey:@"user"]];
                if (!commit) {
                    commit = [DCReadyUserCommit new];
                    commit.snowflake = userID;
                }
                [userCommitsByID setObject:commit forKey:userID];
            }
            id nickname = [relationship objectForKey:@"nickname"];
            if ([nickname isKindOfClass:[NSString class]] && [(NSString *)nickname length])
                commit.relationshipNickname = nickname;
        }
    }

    NSDictionary *mergedPresences = [d objectForKey:@"merged_presences"];
    NSArray *friendPresences = [mergedPresences objectForKey:@"friends"];
    NSArray *guildPresenceGroups = [mergedPresences objectForKey:@"guilds"];
    NSMutableArray *presenceArrays = [NSMutableArray array];
    if ([friendPresences isKindOfClass:[NSArray class]]) [presenceArrays addObject:friendPresences];
    if ([guildPresenceGroups isKindOfClass:[NSArray class]]) {
        for (id group in guildPresenceGroups)
            if ([group isKindOfClass:[NSArray class]]) [presenceArrays addObject:group];
    }
    for (NSArray *presenceArray in presenceArrays) {
        for (NSDictionary *presence in presenceArray) {
            if (![presence isKindOfClass:[NSDictionary class]]) continue;
            NSString *userID = [presence objectForKey:@"user_id"];
            NSString *status = [presence objectForKey:@"status"];
            if (![userID isKindOfClass:[NSString class]] || !userID.length ||
                ![status isKindOfClass:[NSString class]]) continue;
            DCReadyUserCommit *commit = [userCommitsByID objectForKey:userID];
            if (!commit) {
                commit = [DCReadyUserCommit new];
                commit.snowflake = userID;
                [userCommitsByID setObject:commit forKey:userID];
            }
            commit.fields |= DCReadyUserCommitHasStatus;
            commit.status = [DCUser statusFromString:status];
            [livePresenceIDs addObject:userID];
        }
    }
    CFTimeInterval userPrepareElapsed = CFAbsoluteTimeGetCurrent() - userPrepareStarted;

    // Roles and emojis are plain model objects derived exclusively from READY
    // JSON. Build replacement dictionaries here without touching any live
    // guild or global cache; the main-thread commit will only preserve loaded
    // bitmaps and swap the dictionaries into place.
    CFAbsoluteTime metadataPrepareStarted = CFAbsoluteTimeGetCurrent();
    CFTimeInterval preparedRoleTime = 0;
    CFTimeInterval preparedEmojiTime = 0;
    NSUInteger preparedRoles = 0;
    NSUInteger preparedEmojis = 0;
    for (NSDictionary *guildData in guildJsons) {
        if (![guildData isKindOfClass:[NSDictionary class]]) continue;
        NSString *guildID = [guildData objectForKey:@"id"];
        if (![guildID isKindOfClass:[NSString class]]) continue;

        NSArray *rawRoles = [guildData objectForKey:@"roles"];
        if ([rawRoles isKindOfClass:[NSArray class]]) {
            CFAbsoluteTime partStarted = CFAbsoluteTimeGetCurrent();
            NSMutableDictionary *roles =
                [NSMutableDictionary dictionaryWithCapacity:rawRoles.count];
            for (NSDictionary *roleData in rawRoles) {
                if (![roleData isKindOfClass:[NSDictionary class]]) continue;
                DCRole *role = [DCTools convertJsonRole:roleData cache:NO];
                NSString *roleID = [roleData objectForKey:@"id"];
                if (role && [roleID isKindOfClass:[NSString class]]) {
                    [roles setObject:role forKey:roleID];
                    preparedRoles++;
                }
            }
            [rolesByGuildID setObject:roles forKey:guildID];
            preparedRoleTime += CFAbsoluteTimeGetCurrent() - partStarted;
        }

        NSArray *rawEmojis = [guildData objectForKey:@"emojis"];
        if ([rawEmojis isKindOfClass:[NSArray class]]) {
            CFAbsoluteTime partStarted = CFAbsoluteTimeGetCurrent();
            NSMutableDictionary *emojis =
                [NSMutableDictionary dictionaryWithCapacity:rawEmojis.count];
            for (NSDictionary *emojiData in rawEmojis) {
                if (![emojiData isKindOfClass:[NSDictionary class]]) continue;
                DCEmoji *emoji = [DCTools convertJsonEmoji:emojiData cache:NO];
                NSString *emojiID = [emojiData objectForKey:@"id"];
                if (emoji && [emojiID isKindOfClass:[NSString class]]) {
                    [emojis setObject:emoji forKey:emojiID];
                    preparedEmojis++;
                }
            }
            [emojisByGuildID setObject:emojis forKey:guildID];
            preparedEmojiTime += CFAbsoluteTimeGetCurrent() - partStarted;
        }
    }
    CFTimeInterval metadataPrepareElapsed = CFAbsoluteTimeGetCurrent() - metadataPrepareStarted;

    CFTimeInterval channelPropertyPrepareTime = 0;
    CFTimeInterval permissionPrepareTime = 0;
    NSUInteger preparedChannels = 0;
    NSUInteger preparedOverwrites = 0;

    for (NSUInteger i = 0; i < guildJsons.count; i++) {
        NSDictionary *guildData = [guildJsons objectAtIndex:i];
        if (![guildData isKindOfClass:[NSDictionary class]]) continue;
        NSString *guildID = [guildData objectForKey:@"id"];
        if (![guildID isKindOfClass:[NSString class]]) continue;

        NSMutableSet *roleSet = [NSMutableSet setWithObject:guildID];
        if ([mergedMembers isKindOfClass:[NSArray class]] && i < mergedMembers.count) {
            id memberGroup = [mergedMembers objectAtIndex:i];
            if ([memberGroup isKindOfClass:[NSArray class]]) {
                for (NSDictionary *member in (NSArray *)memberGroup) {
                    if (![member isKindOfClass:[NSDictionary class]]) continue;
                    NSString *memberID = [member objectForKey:@"user_id"];
                    if (![memberID isKindOfClass:[NSString class]])
                        memberID = [member valueForKeyPath:@"user.id"];
                    if (![memberID isEqualToString:currentUserID]) continue;
                    id roles = [member objectForKey:@"roles"];
                    if ([roles isKindOfClass:[NSArray class]])
                        [roleSet addObjectsFromArray:roles];
                    break;
                }
            }
        }

        NSString *ownerID = [guildData objectForKey:@"owner_id"];
        NSArray *rawChannels = [guildData objectForKey:@"channels"];
        NSArray *rawThreads = [guildData objectForKey:@"threads"];
        NSUInteger rawChannelCount = [rawChannels isKindOfClass:[NSArray class]] ? rawChannels.count : 0;
        NSUInteger rawThreadCount = [rawThreads isKindOfClass:[NSArray class]] ? rawThreads.count : 0;
        NSUInteger combinedCount = rawChannelCount + rawThreadCount;

        for (NSUInteger combinedIndex = 0; combinedIndex < combinedCount; combinedIndex++) {
            NSDictionary *channelData = combinedIndex < rawChannelCount
                ? [rawChannels objectAtIndex:combinedIndex]
                : [rawThreads objectAtIndex:(combinedIndex - rawChannelCount)];
            if (![channelData isKindOfClass:[NSDictionary class]]) continue;
            NSString *channelID = [channelData objectForKey:@"id"];
            if (![channelID isKindOfClass:[NSString class]]) continue;

            // Normalize the simple channel fields once on the Gateway queue so
            // the main-thread commit does not repeatedly probe/class-check raw
            // JSON dictionaries for every channel. Presence bits preserve the
            // old merge semantics for omitted versus explicit-null fields.
            CFAbsoluteTime propertyStarted = CFAbsoluteTimeGetCurrent();
            DCReadyChannelCommit *commit = [DCReadyChannelCommit new];
            commit.snowflake = channelID;
            id commitValue = nil;
            if ([channelData objectForKey:@"parent_id"] != nil) {
                commit.fields |= DCReadyChannelCommitHasParentID;
                commitValue = [channelData objectForKey:@"parent_id"];
                commit.parentID = [commitValue isKindOfClass:[NSString class]] ? commitValue : nil;
            }
            if ([channelData objectForKey:@"name"] != nil) {
                commit.fields |= DCReadyChannelCommitHasName;
                commitValue = [channelData objectForKey:@"name"];
                commit.name = [commitValue isKindOfClass:[NSString class]] ? commitValue : nil;
            }
            if ([channelData objectForKey:@"last_message_id"] != nil) {
                commit.fields |= DCReadyChannelCommitHasLastMessageID;
                commitValue = [channelData objectForKey:@"last_message_id"];
                commit.lastMessageID = [commitValue isKindOfClass:[NSString class]] ? commitValue : nil;
            }
            commitValue = [channelData objectForKey:@"type"];
            if ([commitValue respondsToSelector:@selector(integerValue)]) {
                commit.fields |= DCReadyChannelCommitHasType;
                commit.type = (DCChannelType)[commitValue integerValue];
            }
            commitValue = [channelData objectForKey:@"position"];
            if ([commitValue respondsToSelector:@selector(integerValue)]) {
                commit.fields |= DCReadyChannelCommitHasPosition;
                commit.position = [commitValue integerValue];
            }
            if ([channelData objectForKey:@"icon"] != nil) {
                commit.fields |= DCReadyChannelCommitHasIconID;
                commitValue = [channelData objectForKey:@"icon"];
                commit.iconID = [commitValue isKindOfClass:[NSString class]] ? commitValue : nil;
            }
            channelPropertyPrepareTime += CFAbsoluteTimeGetCurrent() - propertyStarted;

            CFAbsoluteTime permissionPartStarted = CFAbsoluteTimeGetCurrent();
            BOOL canWrite = YES;
            NSArray *overwrites = [channelData objectForKey:@"permission_overwrites"];
            if ([overwrites isKindOfClass:[NSArray class]]) {
                commit.fields |= DCReadyChannelCommitHasWriteability;
                commit.overwriteCount = overwrites.count;
                preparedOverwrites += overwrites.count;
                if (![ownerID isEqualToString:currentUserID] && overwrites.count) {
                    BOOL everyoneDeny = NO, everyoneAllow = NO;
                    BOOL roleDeny = NO, roleAllow = NO;
                    BOOL memberDeny = NO, memberAllow = NO;
                    for (NSDictionary *permission in overwrites) {
                        if (![permission isKindOfClass:[NSDictionary class]]) continue;
                        NSString *identifier = [permission objectForKey:@"id"];
                        if (![identifier isKindOfClass:[NSString class]]) continue;
                        NSInteger type = [[permission objectForKey:@"type"] integerValue];
                        uint64_t deny = [[permission objectForKey:@"deny"] longLongValue];
                        uint64_t allow = [[permission objectForKey:@"allow"] longLongValue];
                        BOOL deniesSend = (deny & DCPermissionSendMessages) == DCPermissionSendMessages;
                        BOOL allowsSend = (allow & DCPermissionSendMessages) == DCPermissionSendMessages;
                        if (!deniesSend && !allowsSend) continue;

                        if (type == 0) {
                            if ([identifier isEqualToString:guildID]) {
                                everyoneDeny |= deniesSend;
                                everyoneAllow |= allowsSend;
                            } else if ([roleSet containsObject:identifier]) {
                                roleDeny |= deniesSend;
                                roleAllow |= allowsSend;
                            }
                        } else if (type == 1 && [identifier isEqualToString:currentUserID]) {
                            memberDeny |= deniesSend;
                            memberAllow |= allowsSend;
                        }
                    }
                    if (everyoneDeny) canWrite = NO;
                    if (everyoneAllow) canWrite = YES;
                    if (roleDeny) canWrite = NO;
                    if (roleAllow) canWrite = YES;
                    if (memberDeny) canWrite = NO;
                    if (memberAllow) canWrite = YES;
                }
                commit.writeable = canWrite;
            }
            permissionPrepareTime += CFAbsoluteTimeGetCurrent() - permissionPartStarted;
            [channelCommitsByID setObject:commit forKey:channelID];
            preparedChannels++;
        }
    }

    CFAbsoluteTime sortStarted = CFAbsoluteTimeGetCurrent();
    for (NSDictionary *guildData in guildJsons) {
        if (![guildData isKindOfClass:[NSDictionary class]]) continue;
        NSString *guildID = [guildData objectForKey:@"id"];
        NSArray *rawChannels = [guildData objectForKey:@"channels"];
        if (![guildID isKindOfClass:[NSString class]] ||
            ![rawChannels isKindOfClass:[NSArray class]]) continue;

        NSMutableArray *categories = [NSMutableArray array];
        NSMutableArray *channels = [NSMutableArray array];
        NSMutableDictionary *categoryPositions = [NSMutableDictionary dictionary];
        NSMutableDictionary *categoriesByID = [NSMutableDictionary dictionary];

        for (NSDictionary *channelData in rawChannels) {
            if (![channelData isKindOfClass:[NSDictionary class]]) continue;
            NSString *channelID = [channelData objectForKey:@"id"];
            if (![channelID isKindOfClass:[NSString class]]) continue;
            NSInteger type = [[channelData objectForKey:@"type"] integerValue];
            if (type == DCChannelTypeGuildCategory) {
                [categories addObject:channelData];
                [categoryPositions setObject:[NSNumber numberWithInteger:[[channelData objectForKey:@"position"] integerValue]]
                                      forKey:channelID];
                [categoriesByID setObject:channelData forKey:channelID];
            } else if (type == DCChannelTypeGuildText ||
                       type == DCChannelTypeGuildAnnouncement) {
                [channels addObject:channelData];
            }
        }

        [categories sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSInteger positionA = [[a objectForKey:@"position"] integerValue];
            NSInteger positionB = [[b objectForKey:@"position"] integerValue];
            if (positionA < positionB) return NSOrderedAscending;
            if (positionA > positionB) return NSOrderedDescending;
            return [[a objectForKey:@"id"] compare:[b objectForKey:@"id"]];
        }];

        [channels sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *parentA = [[a objectForKey:@"parent_id"] isKindOfClass:[NSString class]]
                ? [a objectForKey:@"parent_id"] : nil;
            NSString *parentB = [[b objectForKey:@"parent_id"] isKindOfClass:[NSString class]]
                ? [b objectForKey:@"parent_id"] : nil;
            BOOL hasParentA = parentA != nil;
            BOOL hasParentB = parentB != nil;
            if (hasParentA != hasParentB)
                return hasParentA ? NSOrderedDescending : NSOrderedAscending;
            if (hasParentA && ![parentA isEqualToString:parentB]) {
                NSInteger parentPositionA = [[categoryPositions objectForKey:parentA] integerValue];
                NSInteger parentPositionB = [[categoryPositions objectForKey:parentB] integerValue];
                if (parentPositionA < parentPositionB) return NSOrderedAscending;
                if (parentPositionA > parentPositionB) return NSOrderedDescending;
            }
            NSInteger positionA = [[a objectForKey:@"position"] integerValue];
            NSInteger positionB = [[b objectForKey:@"position"] integerValue];
            if (positionA < positionB) return NSOrderedAscending;
            if (positionA > positionB) return NSOrderedDescending;
            return [[a objectForKey:@"id"] compare:[b objectForKey:@"id"]];
        }];

        NSMutableSet *insertedCategoryIDs = [NSMutableSet setWithCapacity:categories.count];
        NSMutableArray *orderedIDs =
            [NSMutableArray arrayWithCapacity:categories.count + channels.count];
        for (NSDictionary *channelData in channels) {
            NSString *parentID = [[channelData objectForKey:@"parent_id"] isKindOfClass:[NSString class]]
                ? [channelData objectForKey:@"parent_id"] : nil;
            if (parentID && [categoriesByID objectForKey:parentID] &&
                ![insertedCategoryIDs containsObject:parentID]) {
                [orderedIDs addObject:parentID];
                [insertedCategoryIDs addObject:parentID];
            }
            NSString *channelID = [channelData objectForKey:@"id"];
            if (channelID) [orderedIDs addObject:channelID];
        }
        for (NSDictionary *categoryData in categories) {
            NSString *categoryID = [categoryData objectForKey:@"id"];
            if (categoryID && ![insertedCategoryIDs containsObject:categoryID])
                [orderedIDs addObject:categoryID];
        }
        [orderByGuildID setObject:orderedIDs forKey:guildID];
    }
    CFTimeInterval sortElapsed = CFAbsoluteTimeGetCurrent() - sortStarted;

    DBGLOG(@"[GatewayPerf] READY prepare detail users %.3fs/%lu, metadata %.3fs (roles %.3fs/%lu, emojis %.3fs/%lu), channel props %.3fs, permissions %.3fs, order %.3fs (%lu channels, %lu overwrites)",
           userPrepareElapsed, (unsigned long)preparedUsers,
           metadataPrepareElapsed,
           preparedRoleTime, (unsigned long)preparedRoles,
           preparedEmojiTime, (unsigned long)preparedEmojis,
           channelPropertyPrepareTime, permissionPrepareTime, sortElapsed,
           (unsigned long)preparedChannels,
           (unsigned long)preparedOverwrites);

    return [NSDictionary dictionaryWithObjectsAndKeys:
        userCommitsByID, @"user_commits",
        livePresenceIDs, @"live_presence_ids",
        channelCommitsByID, @"channel_commits",
        orderByGuildID, @"channel_order",
        rolesByGuildID, @"guild_roles",
        emojisByGuildID, @"guild_emojis",
        nil];
}

#pragma mark - Discord Event Handlers

- (void)handleReadyWithData:(NSDictionary *)d {
    [self handleReadyWithData:d preparedHints:nil];
}

- (void)handleReadyWithData:(NSDictionary *)d preparedHints:(NSDictionary *)preparedHints {
    CFAbsoluteTime readyStarted = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime readyEntityStarted = readyStarted;
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
    // Bulk mode keeps READY's canonical entity traffic local instead of paying
    // a synchronized Discord::Data::Access round-trip for every object.
    [self beginReadyBulkEntityCache];

    CFAbsoluteTime readyUsersStarted = CFAbsoluteTimeGetCurrent();
    NSDictionary *preparedUserCommits = [preparedHints objectForKey:@"user_commits"];
    NSSet *preparedLivePresenceIDs = [preparedHints objectForKey:@"live_presence_ids"];
    if ([preparedUserCommits isKindOfClass:[NSDictionary class]]) {
        for (DCReadyUserCommit *commit in [preparedUserCommits allValues])
            [self applyReadyUserCommit:commit];
        if ([preparedLivePresenceIDs isKindOfClass:[NSSet class]])
            self.livePresenceUserIDs = [preparedLivePresenceIDs mutableCopy];
    } else {
        [DCTools convertJsonUser:[d objectForKey:@"user"] cache:YES];
        for (NSDictionary *user in [d objectForKey:@"users"]) {
            @autoreleasepool {
                DCUser *dcUser = [DCTools convertJsonUser:user cache:YES];
                if (!dcUser) DBGLOG(@"[READY] Failed to convert user: %@", user);
            }
        }

        NSArray *relationships = [d objectForKey:@"relationships"];
        for (NSDictionary *relationship in relationships) {
            NSString *friendNick = [relationship objectForKey:@"nickname"];
            NSString *userId = [relationship valueForKeyPath:@"id"];
            if (!friendNick || (NSNull *)friendNick == [NSNull null] || friendNick.length == 0)
                continue;
            DCUser *user = [self userForSnowflake:userId];
            if (!user) user = [DCTools convertJsonUser:[relationship objectForKey:@"user"] cache:YES];
            user.globalName = friendNick;
        }

        NSDictionary *merged_presences = [d objectForKey:@"merged_presences"];
        NSArray *friendPresences = [merged_presences objectForKey:@"friends"];
        NSArray *guildPresenceGroups = [merged_presences objectForKey:@"guilds"];
        if (!self.livePresenceUserIDs) self.livePresenceUserIDs = [NSMutableSet set];
        for (NSDictionary *presence in friendPresences) {
            NSString *userId = [presence objectForKey:@"user_id"];
            NSString *status = [presence objectForKey:@"status"];
            if (!userId || !status) continue;
            DCUser *user = [self userForSnowflake:userId];
            if (!user) continue;
            [self.livePresenceUserIDs addObject:userId];
            user.status = [DCUser statusFromString:status];
        }
        for (NSArray *guildPresences in guildPresenceGroups) {
            for (NSDictionary *presence in guildPresences) {
                NSString *userId = [presence objectForKey:@"user_id"];
                NSString *status = [presence objectForKey:@"status"];
                if (!userId || !status) continue;
                DCUser *user = [self userForSnowflake:userId];
                if (!user) continue;
                [self.livePresenceUserIDs addObject:userId];
                user.status = [DCUser statusFromString:status];
            }
        }
    }
    CFTimeInterval readyUsersElapsed = CFAbsoluteTimeGetCurrent() - readyUsersStarted;

    CFAbsoluteTime readyPrivateStarted = CFAbsoluteTimeGetCurrent();
    // Reconcile READY's private-channel snapshot into the cached DM guild.
    // Existing channel objects survive so a visible menu/chat never has its
    // model swapped out underneath it after a failed RESUME.
    DCGuild *privateGuild = [self reconcilePrivateChannelsFromReady:
        [d objectForKey:@"private_channels"]];
    CFTimeInterval readyPrivateElapsed = CFAbsoluteTimeGetCurrent() - readyPrivateStarted;

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD CHANNEL LIST" object:nil];
    });

    CFAbsoluteTime readyDMFinalizeStarted = CFAbsoluteTimeGetCurrent();
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
                BOOL firstRecipient = YES;
                for (DCUser *recipient in recipientSnapshot) {
                    if (!firstRecipient) [fullChannelName appendString:@", "];
                    [fullChannelName appendString:[recipient displayName]];
                    firstRecipient = NO;
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
        // Snowflakes are unsigned decimal integers. Length + literal compare is
        // substantially cheaper than locale-aware natural-language collation.
        if (idA.length < idB.length) return NSOrderedDescending;
        if (idA.length > idB.length) return NSOrderedAscending;
        return [idB compare:idA options:NSLiteralSearch];
    }];
    CFTimeInterval readyDMFinalizeElapsed = CFAbsoluteTimeGetCurrent() - readyDMFinalizeStarted;
    DBGLOG(@"[GatewayPerf] READY entity detail users %.3fs, private %.3fs, DM finalize %.3fs",
           readyUsersElapsed, readyPrivateElapsed, readyDMFinalizeElapsed);
    // Reconcile server snapshots in place instead of replacing the complete
    // cached entity graph. New/deleted guilds are still inserted/removed, but
    // stable snowflakes keep stable Objective-C object identity.
    NSArray *mergedMembers = [d objectForKey:@"merged_members"];
    NSArray *guildJsons    = [d objectForKey:@"guilds"];
    CFAbsoluteTime guildReconcileStarted = CFAbsoluteTimeGetCurrent();
    NSMutableArray *guilds = [self reconcileReadyGuilds:guildJsons
                                           mergedMembers:mergedMembers
                                            privateGuild:privateGuild
                                           preparedHints:preparedHints];
    CFAbsoluteTime guildReconcileFinished = CFAbsoluteTimeGetCurrent();
    [self endReadyBulkEntityCache];
    CFAbsoluteTime entityFinished = CFAbsoluteTimeGetCurrent();
    DBGLOG(@"[GatewayPerf] READY entities/private/presence %.3fs, guild reconcile %.3fs, bulk publish %.3fs",
           guildReconcileStarted - readyEntityStarted,
           guildReconcileFinished - guildReconcileStarted,
           entityFinished - guildReconcileFinished);

    // Build a one-pass lookup for the settings/folder work below.
    NSMutableDictionary *readyGuildsByID = [NSMutableDictionary dictionaryWithCapacity:guilds.count];
    for (DCGuild *guild in guilds) {
        if (guild.snowflake.length) [readyGuildsByID setObject:guild forKey:guild.snowflake];
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
                for (NSInteger i = (NSInteger)guildIds.count - 1; i >= 0; i--) {
                    NSString *guildId = [guildIds objectAtIndex:(NSUInteger)i];
                    if (![readyGuildsByID objectForKey:guildId]) {
                        DBGLOG(@"[READY] Guild ID %@ not found in guilds array!", guildId);
                        [guildIds removeObjectAtIndex:(NSUInteger)i];
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
            if (guilds.count > 0)
                ((DCGuild *)[guilds objectAtIndex:0]).muted = [[guildSettings objectForKey:@"muted"] boolValue];
            continue;
        }
        DCGuild *guild = [readyGuildsByID objectForKey:guildId];
        if (guild) guild.muted = [[guildSettings objectForKey:@"muted"] boolValue];
    }
    if (!self.guilds)
        self.guilds = [NSMutableArray array];
    [self.guilds setArray:guilds];
    // The ordering payload may have changed even though entity instances were
    // preserved. Rebuild only the lightweight display layout on demand.
    self.cachedDisplayLayout = nil;
    self.guildsIsSorted = NO;
    // READY read states provide the last-read message and mention count per channel.
    NSArray *readstatesArray = [d objectForKey:@"read_state"];
    for (NSDictionary *readstate in readstatesArray) {
        NSString *readstateChannelId = [readstate objectForKey:@"id"];
        NSString *readstateMessageId = [readstate objectForKey:@"last_message_id"];
        NSInteger mentionCount = [[readstate objectForKey:@"mention_count"] integerValue];
        DCChannel *channelOfReadstate = [self.channels objectForKey:readstateChannelId];
        channelOfReadstate.lastReadMessageId = readstateMessageId;
        channelOfReadstate.mentionCount = mentionCount;
        if (channelOfReadstate) {
            channelOfReadstate.unread =
                (channelOfReadstate.mentionCount > 0) ||
                (channelOfReadstate.lastMessageId &&
                 channelOfReadstate.lastMessageId != (id)NSNull.null &&
                 [channelOfReadstate.lastMessageId isKindOfClass:[NSString class]] &&
                 ![channelOfReadstate.lastMessageId isEqualToString:channelOfReadstate.lastReadMessageId]);
        }
    }
    // Wire up channel mute state from userChannelSettings
    for (DCGuild *guild in self.guilds) {
        for (DCChannel *channel in guild.channels) {
            NSNumber *muteValue = self.userChannelSettings[channel.snowflake];
            if (muteValue) {
                channel.muted = [muteValue boolValue];
            }
        }
        // Read-state import used to rescan the complete guild once per channel.
        // All channel flags are now established, so one aggregate pass is enough.
        [guild checkIfRead];
    }
    // Keep communicator selection canonical too. With reconciliation this is
    // normally already the same object; the lookup only matters if READY
    // authoritatively removed the previously selected guild.
    if (self.selectedGuild) {
        if (self.selectedGuild.snowflake.length > 0) {
            DCGuild *canonicalSelectedGuild =
                [self guildWithSnowflake:self.selectedGuild.snowflake];
            self.selectedGuild = canonicalSelectedGuild ?: privateGuild;
        } else {
            self.selectedGuild = privateGuild;
        }
    }

    // Re-resolve selectedChannel from fresh READY data and re-subscribe
    if (self.selectedChannel) {
        NSString *channelSnowflake = self.selectedChannel.snowflake;
        DCChannel *freshChannel = [self.channels objectForKey:channelSnowflake];
        if (freshChannel && freshChannel.parentGuild) {
            // Normally this is the exact same object after reconciliation.
            self.selectedChannel = freshChannel;
            self.selectedGuild = freshChannel.parentGuild;
            if (freshChannel.parentGuild.snowflake.length > 0) {
                [self sendGuildSubscriptionWithGuildId:freshChannel.parentGuild.snowflake
                                             channelId:freshChannel.snowflake];
            }
            DBGLOG(@"[READY-Reconcile] Kept selected channel %@ in place", channelSnowflake);
        } else {
            DBGLOG(@"[READY-Reconcile] Selected channel %@ no longer exists", channelSnowflake);
            [[DCCacheManager sharedInstance] clearLastActiveChatChannel];
            self.selectedChannel = nil;
            self.selectedGuild = privateGuild;
        }
    }
    // Persist the freshly established baseline and, only after those writes
    // complete, publish a sequence/session cursor that a future process may
    // safely use for RESUME.
        [self persistDurableGatewayStateWithCompletion:nil];

        DBGLOG(@"[GatewayPerf] READY handler total %.3fs",
               CFAbsoluteTimeGetCurrent() - readyStarted);
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

        if (!self.livePresenceUserIDs)
            self.livePresenceUserIDs = [NSMutableSet set];
        [self.livePresenceUserIDs addObject:userId];
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
            dispatch_async(dispatch_get_main_queue(), ^{
                // Send notification with the new message
                // will be recieved by DCChatViewController
                [NSNotificationCenter.defaultCenter postNotificationName:@"MESSAGE CREATE" object:self userInfo:d];
            }); // Update current channel & read state last message
            [self.selectedChannel setLastMessageId:messageId];
            // Acknowledge messages in the currently viewed channel.
            [self.selectedChannel ackMessage:messageId];
        } else {
            DCChannel *channelOfMessage = [self.channels objectForKey:channelIdOfMessage];
            channelOfMessage.lastMessageId = messageId;
            
            // Messages authored by the current user remain read.
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
                // Advance lastReadMessageId for messages authored by the current user.
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
        // Acknowledge messages in the currently viewed channel.
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


/*
 * READY reconciliation helpers
 * ----------------------------
 * A fresh IDENTIFY/READY is authoritative, but it should not force the UI to
 * abandon the cached objects it is already displaying. Reuse canonical guild
 * and channel instances whenever their snowflakes still exist, patch them from
 * READY, and only allocate/remove entities for actual structural differences.
 */
- (DCGuild *)reconcilePrivateChannelsFromReady:(NSArray *)privateChannels {
    DCGuild *privateGuild = [self privateGuild];
    if (!privateGuild) {
        privateGuild = [DCGuild new];
        privateGuild.name = @"Direct Messages";
        privateGuild.snowflake = nil;
        privateGuild.channels = [NSMutableArray array];
        if (self.oldMode == NO)
            privateGuild.icon = [UIImage imageNamed:@"privateGuildLogo"];
    }

    if (!self.channels)
        self.channels = [NSMutableDictionary dictionary];
    if (!privateGuild.channels)
        privateGuild.channels = [NSMutableArray array];

    NSMutableArray *orderedChannels = [NSMutableArray array];
    NSMutableSet *incomingIDs = [NSMutableSet set];

    if ([privateChannels isKindOfClass:[NSArray class]]) {
        for (NSDictionary *payload in privateChannels) {
            if (![payload isKindOfClass:[NSDictionary class]]) continue;
            NSString *channelID = [payload objectForKey:@"id"];
            if (![channelID isKindOfClass:[NSString class]] || channelID.length == 0)
                continue;

            [incomingIDs addObject:channelID];
            DCChannel *channel = [self.channels objectForKey:channelID];
            if (!channel || (channel.parentGuild && channel.parentGuild.snowflake))
                channel = [self channelInGuild:privateGuild withSnowflake:channelID];

            BOOL created = (channel == nil);
            if (!channel) channel = [DCChannel new];

            UIImage *existingIcon = channel.icon;
            [self mergeChannel:channel fromData:payload guild:privateGuild];
            channel.writeable = YES;

            if (created && !channel.icon) {
                unsigned long long value = [channelID longLongValue];
                NSUInteger selector = (NSUInteger)((value >> 22) % 6);
                NSArray *defaults = [DCUser defaultAvatars];
                if (selector < defaults.count) {
                    channel.icon = [DCContentManager
                        processedIcon:[defaults objectAtIndex:selector]
                              context:DCAssetContextList];
                }
            } else if (existingIcon && !channel.icon) {
                channel.icon = existingIcon;
            }

            id rawName = [payload objectForKey:@"name"];
            if (![rawName isKindOfClass:[NSString class]] || [(NSString *)rawName length] == 0) {
                if (channel.type == DCChannelTypeDM && channel.recipients.count == 1) {
                    NSString *name = [[channel.recipients objectAtIndex:0] displayName];
                    if (name.length) channel.name = name;
                } else if (channel.type == DCChannelTypeGroupDM && channel.recipients.count) {
                    NSMutableArray *names = [NSMutableArray array];
                    for (DCUser *recipient in channel.recipients) {
                        NSString *name = [recipient displayName];
                        if (name.length) [names addObject:name];
                    }
                    if (names.count) channel.name = [names componentsJoinedByString:@", "];
                }
            }

            // Preserve the normal READY behavior for DM assets. Existing cached
            // images are reused when present; missing/hash-versioned assets go
            // through SDWebImage, which will normally resolve from disk.
            if (channel.iconID.length > 0 && !channel.icon) {
                NSURL *iconURL = [NSURL URLWithString:[NSString stringWithFormat:
                    @"https://cdn.discordapp.com/channel-icons/%@/%@.png?size=64",
                    channel.snowflake, channel.iconID]];
                [[SDWebImageManager sharedManager]
                    downloadImageWithURL:iconURL
                                 options:0
                                progress:nil
                               completed:^(UIImage *icon, NSError *error,
                                           SDImageCacheType cacheType, BOOL finished,
                                           NSURL *imageURL) {
                    if (!icon || !finished) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        channel.icon = [DCContentManager processedIcon:icon
                                                               context:DCAssetContextList];
                        [NSNotificationCenter.defaultCenter
                            postNotificationName:@"RELOAD CHANNEL LIST" object:channel];
                    });
                }];
            } else if (channel.iconID.length == 0 && channel.recipients.count > 0) {
                DCUser *recipient = [channel.recipients objectAtIndex:0];
                if (channel.type == DCChannelTypeDM) {
                    if (!recipient.profileImage) [DCTools getUserAvatar:recipient];
                } else if (channel.type == DCChannelTypeGroupDM &&
                           (!channel.icon || created)) {
                    NSString *avatarID = [recipient.avatarID isKindOfClass:[NSString class]]
                        ? recipient.avatarID : nil;
                    if (avatarID.length > 0) {
                        NSURL *avatarURL = [NSURL URLWithString:[NSString stringWithFormat:
                            @"https://cdn.discordapp.com/avatars/%@/%@.png?size=64",
                            recipient.snowflake, avatarID]];
                        [[SDWebImageManager sharedManager]
                            downloadImageWithURL:avatarURL
                                         options:0
                                        progress:nil
                                       completed:^(UIImage *image, NSError *error,
                                                   SDImageCacheType cacheType, BOOL finished,
                                                   NSURL *imageURL) {
                            if (!image || !finished) return;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                channel.icon = [DCContentManager processedIcon:image
                                                                       context:DCAssetContextList];
                                [NSNotificationCenter.defaultCenter
                                    postNotificationName:@"RELOAD CHANNEL LIST" object:channel];
                            });
                        }];
                    }
                }
            }

            [self.channels setObject:channel forKey:channelID];
            [orderedChannels addObject:channel];
        }
    }

    // READY's private_channels array is a complete snapshot. Remove only DMs
    // that genuinely disappeared; server channels are untouched here.
    NSArray *oldPrivate = [privateGuild.channels copy];
    for (DCChannel *oldChannel in oldPrivate) {
        if (![incomingIDs containsObject:oldChannel.snowflake]) {
            [self.channels removeObjectForKey:oldChannel.snowflake];
            [[DCMessageStore sharedInstance] removeWindowForChannel:oldChannel.snowflake];
        }
    }

    [orderedChannels sortUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
        NSString *idA = [a.lastMessageId isKindOfClass:[NSString class]] ? a.lastMessageId : @"0";
        NSString *idB = [b.lastMessageId isKindOfClass:[NSString class]] ? b.lastMessageId : @"0";
        return [idB localizedStandardCompare:idA];
    }];
    [privateGuild.channels setArray:orderedChannels];
    [privateGuild checkIfRead];
    return privateGuild;
}

- (NSMutableArray *)reconcileReadyGuilds:(NSArray *)guildJsons
                           mergedMembers:(NSArray *)mergedMembers
                            privateGuild:(DCGuild *)privateGuild
                           preparedHints:(NSDictionary *)preparedHints {
    NSMutableArray *result = [NSMutableArray array];
    if (privateGuild) [result addObject:privateGuild];

    NSMutableSet *incomingGuildIDs = [NSMutableSet set];
    NSMutableSet *authoritativeChannelGuildIDs = [NSMutableSet set];
    NSMutableSet *incomingChannelIDs = [NSMutableSet set];
    NSUInteger reusedGuilds = 0;
    NSUInteger newGuilds = 0;
    DCReadyGuildReconcilePerf perf = {0};
    NSDictionary *preparedChannelCommits = [preparedHints objectForKey:@"channel_commits"];
    NSDictionary *preparedOrders = [preparedHints objectForKey:@"channel_order"];
    NSDictionary *preparedRolesByGuild = [preparedHints objectForKey:@"guild_roles"];
    NSDictionary *preparedEmojisByGuild = [preparedHints objectForKey:@"guild_emojis"];

    if (![guildJsons isKindOfClass:[NSArray class]]) guildJsons = [NSArray array];
    if (![mergedMembers isKindOfClass:[NSArray class]]) mergedMembers = [NSArray array];

    // READY repeatedly needs to resolve guilds by snowflake. Build the lookup
    // once instead of linearly walking self.guilds for every snapshot.
    NSMutableDictionary *existingGuildsByID =
        [NSMutableDictionary dictionaryWithCapacity:self.guilds.count];
    for (DCGuild *existingGuild in self.guilds) {
        if (existingGuild.snowflake.length)
            [existingGuildsByID setObject:existingGuild forKey:existingGuild.snowflake];
    }

    for (NSUInteger i = 0; i < guildJsons.count; i++) {
        NSDictionary *guildData = [guildJsons objectAtIndex:i];
        if (![guildData isKindOfClass:[NSDictionary class]]) continue;
        NSString *guildID = [guildData objectForKey:@"id"];
        if (![guildID isKindOfClass:[NSString class]] || guildID.length == 0)
            continue;

        [incomingGuildIDs addObject:guildID];

        // A READY guild with a channels array is authoritative for channel
        // membership. Accumulate one global set now, then retire stale server
        // channels with a single registry sweep after all guilds are merged.
        NSArray *readyChannels = [guildData objectForKey:@"channels"];
        if ([readyChannels isKindOfClass:[NSArray class]]) {
            [authoritativeChannelGuildIDs addObject:guildID];
            for (NSDictionary *channelData in readyChannels) {
                if (![channelData isKindOfClass:[NSDictionary class]]) continue;
                NSString *channelID = [channelData objectForKey:@"id"];
                if ([channelID isKindOfClass:[NSString class]])
                    [incomingChannelIDs addObject:channelID];
            }
            NSArray *readyThreads = [guildData objectForKey:@"threads"];
            if ([readyThreads isKindOfClass:[NSArray class]]) {
                for (NSDictionary *threadData in readyThreads) {
                    if (![threadData isKindOfClass:[NSDictionary class]]) continue;
                    NSString *threadID = [threadData objectForKey:@"id"];
                    if ([threadID isKindOfClass:[NSString class]])
                        [incomingChannelIDs addObject:threadID];
                }
            }
        }

        NSArray *members = (i < mergedMembers.count &&
                            [[mergedMembers objectAtIndex:i] isKindOfClass:[NSArray class]])
            ? [mergedMembers objectAtIndex:i] : nil;

        DCGuild *guild = [existingGuildsByID objectForKey:guildID];
        if (guild) {
            NSMutableDictionary *snapshot = [guildData mutableCopy];
            if (members) [snapshot setObject:members forKey:@"members"];
            [self mergeGuildCreateSnapshot:snapshot
                                  intoGuild:guild
                                   forReady:YES
                     preparedChannelCommits:preparedChannelCommits
                         preparedChannelOrder:[preparedOrders objectForKey:guildID]
                            preparedRoles:[preparedRolesByGuild objectForKey:guildID]
                           preparedEmojis:[preparedEmojisByGuild objectForKey:guildID]
                                       perf:&perf];
            reusedGuilds++;
        } else {
            guild = [DCTools convertJsonGuild:guildData withMembers:members];
            if (!guild) continue;
            newGuilds++;
        }

        [result addObject:guild];
        for (DCChannel *channel in guild.channels) {
            if (channel.snowflake)
                [self.channels setObject:channel forKey:channel.snowflake];
        }
    }

    // The old code scanned the complete global channel dictionary once for
    // every guild. READY can make the same authoritative decision in one pass.
    CFAbsoluteTime staleSweepStarted = CFAbsoluteTimeGetCurrent();
    NSArray *allKnownChannelIDs = [[self.channels allKeys] copy];
    for (NSString *channelID in allKnownChannelIDs) {
        DCChannel *channel = [self.channels objectForKey:channelID];
        NSString *parentGuildID = channel.parentGuild.snowflake;
        if (![parentGuildID isKindOfClass:[NSString class]]) continue;
        if (![authoritativeChannelGuildIDs containsObject:parentGuildID]) continue;
        if ([incomingChannelIDs containsObject:channelID]) continue;

        [self.channels removeObjectForKey:channelID];
        [[DCMessageStore sharedInstance] removeWindowForChannel:channelID];
        perf.staleChannelsRemoved++;
    }
    CFTimeInterval staleSweep = CFAbsoluteTimeGetCurrent() - staleSweepStarted;

    // A full READY is authoritative membership state. Quietly retire guilds
    // that are no longer present without running per-guild checkpoint/UI work.
    NSMutableArray *retiredGuildIDs = [NSMutableArray array];
    NSArray *previousGuilds = [self.guilds copy];
    for (DCGuild *oldGuild in previousGuilds) {
        NSString *oldGuildID = oldGuild.snowflake;
        if (!oldGuildID || [incomingGuildIDs containsObject:oldGuildID]) continue;

        [retiredGuildIDs addObject:oldGuildID];
        for (DCChannel *channel in [oldGuild.channels copy]) {
            if (channel.snowflake) {
                [self.channels removeObjectForKey:channel.snowflake];
                [[DCMessageStore sharedInstance] removeWindowForChannel:channel.snowflake];
            }
        }
    }
    if (retiredGuildIDs.count) {
        NSDictionary *users = [self loadedUsersSnapshot];
        for (DCUser *user in [users allValues]) {
            for (NSString *retiredGuildID in retiredGuildIDs)
                [user.guildNicknames removeObjectForKey:retiredGuildID];
        }
    }

    DBGLOG(@"[READY-Reconcile] Reused %lu guilds, inserted %lu, authoritative total %lu",
           (unsigned long)reusedGuilds, (unsigned long)newGuilds,
           (unsigned long)(result.count > 0 ? result.count - 1 : 0));
    DBGLOG(@"[GatewayPerf] READY guild detail metadata %.3fs, channel merge %.3fs, channel sort %.3fs, stale sweep %.3fs (%lu channels, %lu stale)",
           perf.metadata, perf.channelMerge, perf.channelSort, staleSweep,
           (unsigned long)perf.channelsProcessed,
           (unsigned long)perf.staleChannelsRemoved);
    DBGLOG(@"[GatewayPerf] READY metadata detail core %.3fs, roles %.3fs (%lu), emojis %.3fs (%lu), members %.3fs (%lu)",
           perf.metadataCore, perf.metadataRoles,
           (unsigned long)perf.rolesProcessed,
           perf.metadataEmojis, (unsigned long)perf.emojisProcessed,
           perf.metadataMembers, (unsigned long)perf.membersProcessed);
    DBGLOG(@"[GatewayPerf] READY channel detail setup %.3fs, resolve %.3fs, properties %.3fs, permissions %.3fs, membership %.3fs; overwrites %lu empty / %lu nonempty / %lu entries",
           perf.channelSetup, perf.channelResolve, perf.channelProperties,
           perf.channelPermissions, perf.channelMembership,
           (unsigned long)perf.channelsWithoutOverwrites,
           (unsigned long)perf.channelsWithOverwrites,
           (unsigned long)perf.permissionOverwriteEntries);
    return result;
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

        dispatch_async(dispatch_get_global_queue(
            DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            CGSize itemSize = CGSizeMake(40.0f, 40.0f);
            UIGraphicsBeginImageContextWithOptions(itemSize, NO,
                                                   UIScreen.mainScreen.scale);
            [image drawInRect:CGRectMake(0.0f, 0.0f,
                                         itemSize.width, itemSize.height)];
            UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            UIImage *source = resized ?: image;
            [DCContentManager processedGuildIcon:source];
            [DCContentManager processedFolderMiniGuildIcon:source];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (![guild.iconID isEqualToString:iconHash]) return;
                guild.icon = source;
                [NSNotificationCenter.defaultCenter postNotificationName:@"RELOAD GUILD"
                                                                  object:guild];
            });
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
    [self mergeGuildCreateSnapshot:d
                         intoGuild:guild
                          forReady:NO
            preparedChannelCommits:nil
                preparedChannelOrder:nil
                   preparedRoles:nil
                  preparedEmojis:nil
                              perf:NULL];
}

- (void)mergeGuildCreateSnapshot:(NSDictionary *)d
                       intoGuild:(DCGuild *)guild
                        forReady:(BOOL)forReady
          preparedChannelCommits:(NSDictionary *)preparedChannelCommits
              preparedChannelOrder:(NSArray *)preparedChannelOrder
                 preparedRoles:(NSMutableDictionary *)preparedRoles
                preparedEmojis:(NSMutableDictionary *)preparedEmojis
                            perf:(DCReadyGuildReconcilePerf *)perf {
    CFAbsoluteTime metadataStarted = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime metadataPartStarted = metadataStarted;
    [self mergeGuild:guild fromData:d];
    if (perf)
        perf->metadataCore += CFAbsoluteTimeGetCurrent() - metadataPartStarted;

    // GUILD_CREATE is also the authoritative rehydration event after a guild
    // was temporarily unavailable. Refresh roles/emojis if supplied before
    // recalculating channel permission state.
    metadataPartStarted = CFAbsoluteTimeGetCurrent();
    id rawRoles = [d objectForKey:@"roles"];
    if (forReady && [preparedRoles isKindOfClass:[NSMutableDictionary class]]) {
        // These role objects were created from immutable READY JSON on the
        // Gateway queue. Preserve any already-loaded icon bitmap from the old
        // canonical objects, then publish the replacement dictionary in one
        // short main-thread operation.
        NSDictionary *oldRoles = guild.roles;
        for (NSString *roleID in preparedRoles) {
            DCRole *newRole = [preparedRoles objectForKey:roleID];
            DCRole *oldRole = [oldRoles objectForKey:roleID];
            if (oldRole.icon && !newRole.icon) newRole.icon = oldRole.icon;
        }
        guild.roles = preparedRoles;
        if (readyBulkCacheThread == [NSThread currentThread] && readyBulkRoles)
            [readyBulkRoles addEntriesFromDictionary:preparedRoles];
        else {
            for (NSString *roleID in preparedRoles)
                [self setRole:[preparedRoles objectForKey:roleID] forSnowflake:roleID];
        }
        if (perf) perf->rolesProcessed += preparedRoles.count;
        if (!guild.userRoles) guild.userRoles = [NSMutableArray array];
        if (guild.snowflake && ![guild.userRoles containsObject:guild.snowflake])
            [guild.userRoles insertObject:guild.snowflake atIndex:0];
    } else if ([rawRoles isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *roles = [NSMutableDictionary dictionaryWithCapacity:[rawRoles count]];
        for (NSDictionary *roleData in rawRoles) {
            if (![roleData isKindOfClass:[NSDictionary class]]) continue;
            DCRole *role = [DCTools convertJsonRole:roleData cache:YES];
            NSString *roleID = [roleData objectForKey:@"id"];
            if (role && [roleID isKindOfClass:[NSString class]]) {
                [roles setObject:role forKey:roleID];
                if (perf) perf->rolesProcessed++;
            }
        }
        guild.roles = roles;
        if (!guild.userRoles) guild.userRoles = [NSMutableArray array];
        // @everyone's role ID is the guild ID and always applies.
        if (guild.snowflake && ![guild.userRoles containsObject:guild.snowflake])
            [guild.userRoles insertObject:guild.snowflake atIndex:0];
    }
    if (perf)
        perf->metadataRoles += CFAbsoluteTimeGetCurrent() - metadataPartStarted;

    metadataPartStarted = CFAbsoluteTimeGetCurrent();
    id rawEmojis = [d objectForKey:@"emojis"];
    if (forReady && [preparedEmojis isKindOfClass:[NSMutableDictionary class]]) {
        NSDictionary *oldEmojis = guild.emojis;
        for (NSString *emojiID in preparedEmojis) {
            DCEmoji *newEmoji = [preparedEmojis objectForKey:emojiID];
            DCEmoji *oldEmoji = [oldEmojis objectForKey:emojiID];
            if (oldEmoji.image && !newEmoji.image) newEmoji.image = oldEmoji.image;
        }
        guild.emojis = preparedEmojis;
        if (readyBulkCacheThread == [NSThread currentThread] && readyBulkEmojis)
            [readyBulkEmojis addEntriesFromDictionary:preparedEmojis];
        else {
            for (NSString *emojiID in preparedEmojis)
                [self setEmoji:[preparedEmojis objectForKey:emojiID] forSnowflake:emojiID];
        }
        if (perf) perf->emojisProcessed += preparedEmojis.count;
    } else if ([rawEmojis isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *emojis = [NSMutableDictionary dictionaryWithCapacity:[rawEmojis count]];
        for (NSDictionary *emojiData in rawEmojis) {
            if (![emojiData isKindOfClass:[NSDictionary class]]) continue;
            DCEmoji *emoji = [DCTools convertJsonEmoji:emojiData cache:YES];
            NSString *emojiID = [emojiData objectForKey:@"id"];
            if (emoji && [emojiID isKindOfClass:[NSString class]]) {
                [emojis setObject:emoji forKey:emojiID];
                if (perf) perf->emojisProcessed++;
            }
        }
        guild.emojis = emojis;
    }
    if (perf)
        perf->metadataEmojis += CFAbsoluteTimeGetCurrent() - metadataPartStarted;

    metadataPartStarted = CFAbsoluteTimeGetCurrent();
    id rawMembers = [d objectForKey:@"members"];
    if ([rawMembers isKindOfClass:[NSArray class]]) {
        for (NSDictionary *member in rawMembers) {
            if (![member isKindOfClass:[NSDictionary class]]) continue;
            if (perf) perf->membersProcessed++;
            NSDictionary *userData = [member objectForKey:@"user"];
            DCUser *user = [userData isKindOfClass:[NSDictionary class]]
                ? [DCTools convertJsonUser:userData cache:YES] : nil;
            NSString *userID = user.snowflake;
            if (!userID.length) {
                id mergedUserID = [member objectForKey:@"user_id"];
                if ([mergedUserID isKindOfClass:[NSString class]]) {
                    userID = mergedUserID;
                    user = [self userForSnowflake:userID];
                }
            }
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
    if (perf) {
        perf->metadataMembers += CFAbsoluteTimeGetCurrent() - metadataPartStarted;
        perf->metadata += CFAbsoluteTimeGetCurrent() - metadataStarted;
    }

    NSArray *rawChannels = [d objectForKey:@"channels"];
    NSArray *rawThreads = [d objectForKey:@"threads"];
    BOOL hasChannelSnapshot = [rawChannels isKindOfClass:[NSArray class]];
    if (!hasChannelSnapshot && ![rawThreads isKindOfClass:[NSArray class]]) return;

    CFAbsoluteTime channelMergeStarted = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime channelSetupStarted = channelMergeStarted;
    NSUInteger rawChannelCount = [rawChannels isKindOfClass:[NSArray class]] ? [rawChannels count] : 0;
    NSUInteger rawThreadCount = [rawThreads isKindOfClass:[NSArray class]] ? [rawThreads count] : 0;
    NSUInteger combinedCount = rawChannelCount + rawThreadCount;

    if (!guild.channels) guild.channels = [NSMutableArray array];
    if (!self.channels) self.channels = [NSMutableDictionary dictionary];

    // Build one per-guild channel index up front for O(1) channel resolution.
    NSMutableDictionary *listedByID =
        [NSMutableDictionary dictionaryWithCapacity:guild.channels.count];
    for (DCChannel *listedChannel in guild.channels) {
        if (listedChannel.snowflake.length)
            [listedByID setObject:listedChannel forKey:listedChannel.snowflake];
    }

    NSMutableArray *authoritativeVisibleChannels = hasChannelSnapshot
        ? [NSMutableArray arrayWithCapacity:combinedCount] : nil;
    NSMutableSet *authoritativeVisibleIDs = hasChannelSnapshot
        ? [NSMutableSet setWithCapacity:combinedCount] : nil;
    NSMutableSet *liveIncomingIDs = (!forReady && hasChannelSnapshot)
        ? [NSMutableSet setWithCapacity:combinedCount] : nil;

    // Permission checks happen once per incoming channel. READY already knows
    // the current member's complete role list, so make membership O(1).
    NSSet *readyUserRoleSet = forReady
        ? [NSSet setWithArray:(guild.userRoles ?: [NSArray array])] : nil;
    if (perf)
        perf->channelSetup += CFAbsoluteTimeGetCurrent() - channelSetupStarted;

    for (NSUInteger combinedIndex = 0; combinedIndex < combinedCount; combinedIndex++) {
        NSDictionary *rawChannel = combinedIndex < rawChannelCount
            ? [rawChannels objectAtIndex:combinedIndex]
            : [rawThreads objectAtIndex:(combinedIndex - rawChannelCount)];
        if (![rawChannel isKindOfClass:[NSDictionary class]]) continue;
        NSString *channelID = [rawChannel objectForKey:@"id"];
        if (![channelID isKindOfClass:[NSString class]]) continue;
        if (perf) perf->channelsProcessed++;
        if (liveIncomingIDs) [liveIncomingIDs addObject:channelID];

        CFAbsoluteTime resolveStarted = CFAbsoluteTimeGetCurrent();
        DCChannel *channel = [self.channels objectForKey:channelID];
        if (!channel) channel = [listedByID objectForKey:channelID];
        if (!channel) channel = [DCChannel new];
        if (perf)
            perf->channelResolve += CFAbsoluteTimeGetCurrent() - resolveStarted;

        // mergeChannel receives the parent guild directly; avoid copying channel JSON.
        [self mergeChannel:channel
                   fromData:rawChannel
                      guild:guild
                userRoleSet:readyUserRoleSet
             preparedCommit:[preparedChannelCommits objectForKey:channelID]
                       perf:perf];

        CFAbsoluteTime membershipStarted = CFAbsoluteTimeGetCurrent();
        [self.channels setObject:channel forKey:channelID];
        [listedByID setObject:channel forKey:channelID];

        BOOL shouldAppear = DCChannelTypeAppearsInGuildList(channel.type);
        if (hasChannelSnapshot) {
            if (shouldAppear && ![authoritativeVisibleIDs containsObject:channelID]) {
                [authoritativeVisibleIDs addObject:channelID];
                [authoritativeVisibleChannels addObject:channel];
            }
        } else {
            // Threads-only GUILD_CREATE updates are not authoritative for the
            // whole guild list. Preserve the old incremental membership rules.
            DCChannel *listed = [listedByID objectForKey:channelID];
            if (!shouldAppear) {
                if (listed) {
                    [guild.channels removeObjectIdenticalTo:listed];
                    [listedByID removeObjectForKey:channelID];
                }
            } else if (!listed) {
                [guild.channels addObject:channel];
                [listedByID setObject:channel forKey:channelID];
            } else if (listed != channel) {
                NSUInteger index = [guild.channels indexOfObjectIdenticalTo:listed];
                if (index != NSNotFound)
                    [guild.channels replaceObjectAtIndex:index withObject:channel];
                [listedByID setObject:channel forKey:channelID];
            }
        }
        if (perf)
            perf->channelMembership += CFAbsoluteTimeGetCurrent() - membershipStarted;
    }

    if (hasChannelSnapshot) {
        // Rebuild the visible membership array directly. This replaces a
        // per-channel linear membership scan plus a second stale-list pass.
        [guild.channels setArray:authoritativeVisibleChannels];

        if (!forReady) {
            // Live GUILD_CREATE still needs immediate stale retirement. READY
            // defers this to one global sweep in reconcileReadyGuilds:.
            NSArray *allKnownIDs = [[self.channels allKeys] copy];
            for (NSString *channelID in allKnownIDs) {
                DCChannel *channel = [self.channels objectForKey:channelID];
                if (channel.parentGuild == guild && ![liveIncomingIDs containsObject:channelID]) {
                    [self.channels removeObjectForKey:channelID];
                    [[DCMessageStore sharedInstance] removeWindowForChannel:channelID];
                }
            }
        }
    }

    if (perf)
        perf->channelMerge += CFAbsoluteTimeGetCurrent() - channelMergeStarted;

    CFAbsoluteTime sortStarted = CFAbsoluteTimeGetCurrent();
    BOOL appliedPreparedOrder = NO;
    if (forReady && [preparedChannelOrder isKindOfClass:[NSArray class]] &&
        preparedChannelOrder.count == guild.channels.count) {
        NSMutableArray *ordered =
            [NSMutableArray arrayWithCapacity:preparedChannelOrder.count];
        for (NSString *channelID in preparedChannelOrder) {
            DCChannel *orderedChannel = [listedByID objectForKey:channelID];
            if (orderedChannel && DCChannelTypeAppearsInGuildList(orderedChannel.type))
                [ordered addObject:orderedChannel];
        }
        if (ordered.count == guild.channels.count) {
            [guild.channels setArray:ordered];
            appliedPreparedOrder = YES;
        }
    }
    if (!appliedPreparedOrder) [self resortChannelsForGuild:guild];
    if (perf)
        perf->channelSort += CFAbsoluteTimeGetCurrent() - sortStarted;

    // READY imports authoritative read_state after all guilds are reconciled
    // and performs one aggregate check per guild there. Live GUILD_CREATE still
    // needs its immediate read-state refresh.
    if (!forReady) [guild checkIfRead];
}

- (void)invalidateGuildDisplayLayout {
    self.cachedDisplayLayout = nil;
    self.guildsIsSorted = NO;
    [[DCCacheManager sharedInstance] invalidateDisplayLayout];
}

- (void)checkpointGuildState {
    /* Structural Gateway events update memory only. Durable checkpoints persist
     * the guild graph before publishing the matching Gateway sequence. */
}

- (void)handleUserSettingsProtoUpdateWithData:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *settings = [d objectForKey:@"settings"];
    if (![settings isKindOfClass:[NSDictionary class]]) return;

    // Type 1 is PreloadedUserSettings. Other settings protos (frecency, etc.)
    // do not contain the required guild sidebar layout.
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
        // after a cache miss. Create a minimal canonical shell rather than
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

- (void)handleGuildRoleUpsertWithData:(NSDictionary *)d {
    NSString *guildID = [d objectForKey:@"guild_id"];
    NSDictionary *roleData = [d objectForKey:@"role"];
    if (![guildID isKindOfClass:[NSString class]] ||
        ![roleData isKindOfClass:[NSDictionary class]]) return;

    NSString *roleID = [roleData objectForKey:@"id"];
    DCGuild *guild = [self guildWithSnowflake:guildID];
    if (!guild || ![roleID isKindOfClass:[NSString class]]) return;

    DCRole *role = [DCTools convertJsonRole:roleData cache:YES];
    if (!role) return;
    if (!guild.roles) guild.roles = [NSMutableDictionary dictionary];
    [guild.roles setObject:role forKey:roleID];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD MESSAGE DATA" object:nil];
    });
}

- (void)handleGuildRoleDeleteWithData:(NSDictionary *)d {
    NSString *guildID = [d objectForKey:@"guild_id"];
    NSString *roleID = [d objectForKey:@"role_id"];
    if (![guildID isKindOfClass:[NSString class]] ||
        ![roleID isKindOfClass:[NSString class]]) return;

    DCGuild *guild = [self guildWithSnowflake:guildID];
    if (!guild) return;

    [guild.roles removeObjectForKey:roleID];
    [guild.userRoles removeObject:roleID];
    [self.loadedRoles removeObjectForKey:roleID];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD MESSAGE DATA" object:nil];
    });
}

- (void)handleGuildEmojisUpdateWithData:(NSDictionary *)d {
    NSString *guildID = [d objectForKey:@"guild_id"];
    NSArray *emojiData = [d objectForKey:@"emojis"];
    if (![guildID isKindOfClass:[NSString class]] ||
        ![emojiData isKindOfClass:[NSArray class]]) return;

    DCGuild *guild = [self guildWithSnowflake:guildID];
    if (!guild) return;

    // Remove only this guild's previous IDs from the global registry. External
    // emojis synthesized by message tokens and emojis from other guilds stay.
    NSArray *oldIDs = [[guild.emojis allKeys] copy];
    for (NSString *emojiID in oldIDs) {
        [self.loadedEmojis removeObjectForKey:emojiID];
    }

    NSMutableDictionary *emojis = [NSMutableDictionary dictionary];
    for (NSDictionary *jsonEmoji in emojiData) {
        if (![jsonEmoji isKindOfClass:[NSDictionary class]]) continue;
        NSString *emojiID = [jsonEmoji objectForKey:@"id"];
        if (![emojiID isKindOfClass:[NSString class]]) continue;
        DCEmoji *emoji = [DCTools convertJsonEmoji:jsonEmoji cache:YES];
        if (emoji) [emojis setObject:emoji forKey:emojiID];
    }
    guild.emojis = emojis;

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD MESSAGE DATA" object:nil];
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
                               guild:(DCGuild *)guild
                         userRoleSet:(NSSet *)userRoleSet
                                perf:(DCReadyGuildReconcilePerf *)perf {
    if (!guild || !guild.snowflake) {
        channel.writeable = YES;
        return;
    }

    NSArray *rawOverwrites = [d objectForKey:@"permission_overwrites"];
    if (![rawOverwrites isKindOfClass:[NSArray class]]) return;

    NSUInteger overwriteCount = rawOverwrites.count;
    if (perf) {
        perf->permissionOverwriteEntries += overwriteCount;
        if (overwriteCount == 0)
            perf->channelsWithoutOverwrites++;
        else
            perf->channelsWithOverwrites++;
    }

    // Guild owners bypass channel overwrites entirely. Keep the payload counts
    // above comparable in perf logs, but avoid resolving the entries.
    if ([guild.ownerID isEqualToString:self.snowflake]) {
        channel.writeable = YES;
        return;
    }

    if (overwriteCount == 0) {
        channel.writeable = YES;
        return;
    }

    /* Discord role overwrites are combined, not role-priority ordered: apply
     * @everyone, aggregate matching-role denies/allows, then the member overwrite. */
    BOOL everyoneDeny = NO;
    BOOL everyoneAllow = NO;
    BOOL roleDeny = NO;
    BOOL roleAllow = NO;
    BOOL memberDeny = NO;
    BOOL memberAllow = NO;

    for (NSDictionary *permission in rawOverwrites) {
        if (![permission isKindOfClass:[NSDictionary class]]) continue;

        NSInteger type = [[permission objectForKey:@"type"] integerValue];
        NSString *identifier = [permission objectForKey:@"id"];
        if (![identifier isKindOfClass:[NSString class]]) continue;

        uint64_t deny = [[permission objectForKey:@"deny"] longLongValue];
        uint64_t allow = [[permission objectForKey:@"allow"] longLongValue];
        BOOL deniesSend = (deny & DCPermissionSendMessages) == DCPermissionSendMessages;
        BOOL allowsSend = (allow & DCPermissionSendMessages) == DCPermissionSendMessages;
        if (!deniesSend && !allowsSend) continue;

        if (type == 0) {
            if ([identifier isEqualToString:guild.snowflake]) {
                everyoneDeny |= deniesSend;
                everyoneAllow |= allowsSend;
                continue;
            }

            BOOL hasRole = userRoleSet
                ? [userRoleSet containsObject:identifier]
                : [guild.userRoles containsObject:identifier];
            if (!hasRole) continue;
            roleDeny |= deniesSend;
            roleAllow |= allowsSend;
        } else if (type == 1 && [identifier isEqualToString:self.snowflake]) {
            memberDeny |= deniesSend;
            memberAllow |= allowsSend;
        }
    }

    BOOL canWrite = YES;
    if (everyoneDeny) canWrite = NO;
    if (everyoneAllow) canWrite = YES;
    if (roleDeny) canWrite = NO;
    if (roleAllow) canWrite = YES;
    if (memberDeny) canWrite = NO;
    if (memberAllow) canWrite = YES;

    channel.writeable = canWrite;
}

- (void)mergeChannel:(DCChannel *)channel
             fromData:(NSDictionary *)d
                guild:(DCGuild *)guild {
    [self mergeChannel:channel
               fromData:d
                  guild:guild
            userRoleSet:nil
         preparedCommit:nil
                   perf:NULL];
}

- (void)mergeChannel:(DCChannel *)channel
             fromData:(NSDictionary *)d
                guild:(DCGuild *)guild
          userRoleSet:(NSSet *)userRoleSet
       preparedCommit:(DCReadyChannelCommit *)preparedCommit
                 perf:(DCReadyGuildReconcilePerf *)perf {
    CFAbsoluteTime propertiesStarted = CFAbsoluteTimeGetCurrent();
    if (preparedCommit) {
        if (preparedCommit.snowflake.length) channel.snowflake = preparedCommit.snowflake;
        DCReadyChannelCommitFields fields = preparedCommit.fields;
        if (fields & DCReadyChannelCommitHasParentID)
            channel.parentID = preparedCommit.parentID;
        if (fields & DCReadyChannelCommitHasName)
            channel.name = preparedCommit.name;
        if (fields & DCReadyChannelCommitHasLastMessageID)
            channel.lastMessageId = preparedCommit.lastMessageID;
        if (fields & DCReadyChannelCommitHasType)
            channel.type = preparedCommit.type;
        if (fields & DCReadyChannelCommitHasPosition)
            channel.position = preparedCommit.position;
        if (fields & DCReadyChannelCommitHasIconID) {
            NSString *newIconID = preparedCommit.iconID;
            BOOL changed = (channel.iconID != newIconID)
                && ![channel.iconID isEqualToString:newIconID];
            if (changed) {
                channel.iconID = newIconID;
                channel.icon = nil;
            }
        }
    } else {
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
    }

    channel.parentGuild = guild;
    if (perf)
        perf->channelProperties += CFAbsoluteTimeGetCurrent() - propertiesStarted;

    // Recipient hydration only applies to DM/group-DM channels. Server READY
    // was doing these dictionary probes for every guild channel even though
    // such payloads cannot carry DM recipients.
    if (!guild || !guild.snowflake)
        [self rebuildPrivateChannelRelationships:channel fromData:d];

    CFAbsoluteTime permissionStarted = CFAbsoluteTimeGetCurrent();
    if (preparedCommit &&
        (preparedCommit.fields & DCReadyChannelCommitHasWriteability)) {
        if (perf) {
            NSUInteger overwriteCount = preparedCommit.overwriteCount;
            perf->permissionOverwriteEntries += overwriteCount;
            if (overwriteCount == 0) perf->channelsWithoutOverwrites++;
            else perf->channelsWithOverwrites++;
        }
        channel.writeable = preparedCommit.writeable;
    } else {
        [self updateWriteabilityForChannel:channel
                                  fromData:d
                                     guild:guild
                               userRoleSet:userRoleSet
                                      perf:perf];
    }
    if (perf)
        perf->channelPermissions += CFAbsoluteTimeGetCurrent() - permissionStarted;

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

    // Insert each category immediately before its first child in one pass.
    // The old code searched the growing ordered array once per category.
    NSMutableDictionary *categoriesByID =
        [NSMutableDictionary dictionaryWithCapacity:categories.count];
    for (DCChannel *category in categories) {
        if ([category.snowflake isKindOfClass:[NSString class]])
            [categoriesByID setObject:category forKey:category.snowflake];
    }

    NSMutableSet *insertedCategoryIDs =
        [NSMutableSet setWithCapacity:categories.count];
    NSMutableArray *ordered =
        [NSMutableArray arrayWithCapacity:channels.count + categories.count];
    for (DCChannel *channel in channels) {
        NSString *parentID = [channel.parentID isKindOfClass:[NSString class]]
            ? channel.parentID : nil;
        DCChannel *category = parentID ? [categoriesByID objectForKey:parentID] : nil;
        if (category && ![insertedCategoryIDs containsObject:parentID]) {
            [ordered addObject:category];
            [insertedCategoryIDs addObject:parentID];
        }
        [ordered addObject:channel];
    }
    for (DCChannel *category in categories) {
        NSString *categoryID = [category.snowflake isKindOfClass:[NSString class]]
            ? category.snowflake : nil;
        if (!categoryID) continue;
        if (![insertedCategoryIDs containsObject:categoryID])
            [ordered addObject:category];
    }
    guild.channels = ordered;
}

- (void)checkpointChannelStructure {
    /* Channel/thread events update memory only; durable checkpointing persists
     * the graph together with its matching Gateway sequence. */
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
        // Treat an update for a missing object as an upsert. This is
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
            guild.members = [[guild.members subarrayWithRange:NSMakeRange(0, 100)] mutableCopy];
        }
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
        // A new session has a new authoritative presence baseline. Cached
        // statuses may be shown while READY is in flight, but only presence
        // dispatches received after this point count as live for merge ordering.
        self.livePresenceUserIDs = [NSMutableSet set];

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
            [self ensureLoadedUsersRegistry];

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
    // get data
    NSDictionary *d = [parsedJsonResponse objectForKey:@"d"];

    // Get event type and sequence number
    NSString *t         = [parsedJsonResponse objectForKey:@"t"];
    self.sequenceNumber = [[parsedJsonResponse objectForKey:@"s"] integerValue];
    // received READY
    if (![[parsedJsonResponse objectForKey:@"t"] isKindOfClass:[NSString class]]) {
        return;
    }

    if ([t isEqualToString:@"READY"]) {
        // dataCallback already runs Gateway state work off-main. Keep READY on
        // that same ordered queue so later dispatches cannot overtake it.
        [self handleReadyWithData:d];
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

            // A cold RESUME has no READY to rebuild the signed-in user's role
            // IDs, so keep this durable guild field current from member updates.
            if ([user.snowflake isEqualToString:self.snowflake]) {
                NSArray *roleIDs = [d objectForKey:@"roles"];
                DCGuild *guild = [self guildWithSnowflake:guildId];
                if (guild && [roleIDs isKindOfClass:[NSArray class]]) {
                    NSMutableArray *currentRoles = [roleIDs mutableCopy];
                    // Discord's @everyone role has the guild snowflake.
                    if (guild.snowflake.length > 0 &&
                        ![currentRoles containsObject:guild.snowflake]) {
                        [currentRoles insertObject:guild.snowflake atIndex:0];
                    }
                    guild.userRoles = currentRoles;
                }
            }

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
    } else if ([t isEqualToString:GUILD_ROLE_CREATE] ||
               [t isEqualToString:GUILD_ROLE_UPDATE]) {
        [self handleGuildRoleUpsertWithData:d];
        return;
    } else if ([t isEqualToString:GUILD_ROLE_DELETE]) {
        [self handleGuildRoleDeleteWithData:d];
        return;
    } else if ([t isEqualToString:GUILD_EMOJIS_UPDATE]) {
        [self handleGuildEmojisUpdateWithData:d];
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
        NSMutableArray *changedChannelIDs = [NSMutableArray array];
        for (NSDictionary *unread in unreads) {
            NSString *channelId = [unread objectForKey:@"id"];
            DCChannel *channel  = [self.channels objectForKey:channelId];
            if (channel) {
                id lastMessageID = [unread objectForKey:@"last_message_id"];
                channel.lastMessageId = [lastMessageID isKindOfClass:[NSString class]]
                    ? lastMessageID : nil;
                [channel checkIfRead];
                if (channelId.length) [changedChannelIDs addObject:channelId];
            }
        }

        // CHANNEL_UNREAD_UPDATE used to mutate the model silently. During a cold
        // RESUME that meant replay could be correct internally while the already-
        // visible menu continued showing stale channel/read formatting. Reuse the
        // lightweight MESSAGE ACK notification path so only affected rows refresh.
        if (changedChannelIDs.count) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSString *channelId in changedChannelIDs) {
                    [NSNotificationCenter.defaultCenter
                        postNotificationName:@"MESSAGE ACK"
                                      object:self
                                    userInfo:@{ @"channelId" : channelId }];
                }
            });
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
        if ([DCTools isOriginalIPad]) {
            // Log the event type without formatting the full ignored payload.
            DBGLOG(@"Unhandled event type: %@ (payload omitted on iPad1,1)", t);
        } else {
            DBGLOG(@"Unhandled event type: %@, content: %@", t, d);
        }
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

#pragma mark - Persistent Gateway checkpoint

- (BOOL)restorePersistedGatewaySessionIfPossible {
    // A RESUME only sends events after the saved sequence. Without the matching
    // local baseline, restoring a session would leave Classic with an incomplete
    // object graph and no READY to rebuild it.
    if (self.guilds.count == 0 || self.currentUserInfo.id.length == 0) {
        DBGLOG(@"[GatewayCheckpoint] No complete local baseline; using IDENTIFY");
        return NO;
    }

    NSDictionary *checkpoint =
        [[DCCacheManager sharedInstance] loadGatewayCheckpoint];
    if (!checkpoint) return NO;

    NSString *userID = [checkpoint objectForKey:@"userID"];
    if (![userID isEqualToString:self.currentUserInfo.id]) {
        DBGLOG(@"[GatewayCheckpoint] Cached session belongs to another user; discarding");
        [[DCCacheManager sharedInstance] invalidateGatewayCheckpoint];
        return NO;
    }

    NSString *sessionID = [checkpoint objectForKey:@"sessionID"];
    NSString *resumeURL = [checkpoint objectForKey:@"resumeURL"];
    NSInteger sequence = [[checkpoint objectForKey:@"sequence"] integerValue];
    if (sessionID.length == 0 || resumeURL.length == 0 || sequence <= 0) {
        [[DCCacheManager sharedInstance] invalidateGatewayCheckpoint];
        return NO;
    }

    self.sessionId = sessionID;
    self.resumeGatewayURL = resumeURL;
    self.sequenceNumber = sequence;
    self.persistedSequenceNumber = sequence;

    NSDate *savedAt = [checkpoint objectForKey:@"savedAt"];
    NSTimeInterval age = [savedAt isKindOfClass:[NSDate class]]
        ? -[savedAt timeIntervalSinceNow] : -1.0;
    DBGLOG(@"[GatewayCheckpoint] Restored sequence %li (age %.1fs); attempting cold RESUME",
           (long)sequence, age);
    return YES;
}

- (void)persistDurableGatewayStateWithCompletion:(void (^)(BOOL success))completion {
    void (^finish)(BOOL) = ^(BOOL success) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
        }
    };

    if (!gatewayEventQueue) {
        finish(NO);
        return;
    }

    /*
     * Enqueue behind every Gateway dispatch already received. New events that
     * arrive after this block are intentionally excluded and will have sequence
     * numbers greater than the checkpoint. That is exactly the boundary RESUME
     * needs after a crash or process kill.
     */
    dispatch_async(gatewayEventQueue, ^{
        if (!self.didAuthenticate || self.guilds.count == 0 ||
            self.currentUserInfo.id.length == 0 ||
            self.sequenceNumber <= 0 || self.sessionId.length == 0 ||
            self.resumeGatewayURL.length == 0) {
            finish(NO);
            return;
        }

        NSInteger sequence = self.sequenceNumber;
        NSString *sessionID = [self.sessionId copy];
        NSString *resumeURL = [self.resumeGatewayURL copy];
        NSString *userID = [self.currentUserInfo.id copy];

        DCCacheManager *cache = [DCCacheManager sharedInstance];

        // Guild/channel and user-info archives are synchronous. saveUsers: is
        // intentionally asynchronous, but it uses cacheQueue; the Gateway
        // checkpoint write below is queued behind it on that same serial queue.
        [cache saveGuilds:[self.guilds copy]];
        [cache saveUserInfo:self.currentUserInfo];
        [cache saveUsers:[self loadedUsersSnapshot]];

        [cache saveGatewayCheckpointWithSessionID:sessionID
                                        resumeURL:resumeURL
                                         sequence:sequence
                                           userID:userID
                                       completion:^(BOOL success) {
            if (success) {
                self.persistedSequenceNumber = sequence;
                DBGLOG(@"[GatewayCheckpoint] Durable through sequence %li",
                       (long)sequence);
            }
            if (completion) completion(success);
        }];
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
    // Devend

    

    DBGLOG(@"Start websocket");

    // To prevent retain cycle
    __weak typeof(self) weakSelf = self;

    
    // Establish the websocket connection. If a resumable session exists,
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
            // Ignore locally initiated closes.
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
        CFAbsoluteTime inflateStarted = CFAbsoluteTimeGetCurrent();
        NSString *responseString = [weakSelf inflateGatewayData:data];
        if (!responseString) return; // incomplete message, waiting for more frames
        CFAbsoluteTime inflateFinished = CFAbsoluteTimeGetCurrent();

        NSDictionary *parsedJsonResponse = [DCTools parseJSON:responseString];
        CFAbsoluteTime parseFinished = CFAbsoluteTimeGetCurrent();
        if (!parsedJsonResponse) return;
        int op          = [[parsedJsonResponse objectForKey:@"op"] integerValue];
        NSDictionary *d = [parsedJsonResponse objectForKey:@"d"];
        id gatewayEventTypeValue = [parsedJsonResponse objectForKey:@"t"];
        NSString *gatewayEventType =
            [gatewayEventTypeValue isKindOfClass:[NSString class]]
                ? (NSString *)gatewayEventTypeValue
                : nil;
        if ([gatewayEventType isEqualToString:@"READY"]) {
            DBGLOG(@"[GatewayPerf] READY inflate %.3fs, JSON %.3fs, text chars %lu",
                   inflateFinished - inflateStarted,
                   parseFinished - inflateFinished,
                   (unsigned long)responseString.length);
        }

        BOOL mutatesGatewayState =
            (op == DCGatewayOpCodeDispatch ||
             op == DCGatewayOpCodeReconnect ||
             op == DCGatewayOpCodeInvalidSession);
        dispatch_queue_t eventQueue =
            (mutatesGatewayState && gatewayEventQueue)
                ? gatewayEventQueue
                : dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_async(eventQueue, ^{
            switch (op) {
                case DCGatewayOpCodeHello: {
                    [weakSelf handleHelloWithData:d];
                    break;
                }
                case DCGatewayOpCodeDispatch: {
                    NSString *eventType = gatewayEventType;

                    /*
                     * Structural Gateway events mutate the same live guild/channel
                     * collections that UIKit reads on the main thread.  Keep their
                     * sequence ordering on Discord::Gateway::State, but commit the
                     * actual model mutation on main so UITableView can never fast-
                     * enumerate a collection while READY/CHANNEL/GUILD reconciliation
                     * changes it.  Message/presence traffic stays on the Gateway queue
                     * so the hot path does not inherit READY's main-thread cost.
                     */
                    BOOL requiresMainModelCommit =
                        [eventType isEqualToString:@"READY"] ||
                        [eventType isEqualToString:@"USER_SETTINGS_PROTO_UPDATE"] ||
                        [eventType isEqualToString:GUILD_MEMBER_UPDATE] ||
                        [eventType isEqualToString:GUILD_CREATE] ||
                        [eventType isEqualToString:GUILD_UPDATE] ||
                        [eventType isEqualToString:GUILD_DELETE] ||
                        [eventType isEqualToString:GUILD_ROLE_CREATE] ||
                        [eventType isEqualToString:GUILD_ROLE_UPDATE] ||
                        [eventType isEqualToString:GUILD_ROLE_DELETE] ||
                        [eventType isEqualToString:GUILD_EMOJIS_UPDATE] ||
                        [eventType isEqualToString:THREAD_CREATE] ||
                        [eventType isEqualToString:THREAD_UPDATE] ||
                        [eventType isEqualToString:THREAD_DELETE] ||
                        [eventType isEqualToString:CHANNEL_CREATE] ||
                        [eventType isEqualToString:CHANNEL_UPDATE] ||
                        [eventType isEqualToString:CHANNEL_DELETE] ||
                        [eventType isEqualToString:GUILD_MEMBER_LIST_UPDATE] ||
                        [eventType isEqualToString:@"GUILD_MEMBERS_CHUNK"];

                    if ([eventType isEqualToString:@"READY"]) {
                        // READY preparation is pure JSON-derived work. Compute
                        // permission results and final channel order here on the
                        // ordered Gateway queue, then keep only live-object mutation
                        // in the main-thread commit.
                        weakSelf.sequenceNumber = [[parsedJsonResponse objectForKey:@"s"] integerValue];
                        CFAbsoluteTime prepareStarted = CFAbsoluteTimeGetCurrent();
                        NSDictionary *preparedHints = [weakSelf prepareReadyCommitHints:d];
                        CFTimeInterval prepareElapsed = CFAbsoluteTimeGetCurrent() - prepareStarted;
                        DBGLOG(@"[GatewayPerf] READY off-main prepare %.3fs", prepareElapsed);
                        dispatch_sync(dispatch_get_main_queue(), ^{
                            [weakSelf handleReadyWithData:d preparedHints:preparedHints];
                        });
                    } else if (requiresMainModelCommit) {
                        // Time structural main-thread commits for performance diagnostics.
                        CFAbsoluteTime mainCommitStarted = CFAbsoluteTimeGetCurrent();
                        dispatch_sync(dispatch_get_main_queue(), ^{
                            [weakSelf handleDispatchWithResponse:parsedJsonResponse];
                        });
                        CFTimeInterval mainCommitElapsed =
                            CFAbsoluteTimeGetCurrent() - mainCommitStarted;
                        if (mainCommitElapsed >= 0.100) {
                            DBGLOG(@"[GatewayPerf] main commit %@ %.3fs",
                                   eventType ?: @"(unknown)", mainCommitElapsed);
                        }
                    } else {
                        [weakSelf handleDispatchWithResponse:parsedJsonResponse];
                    }
                    break;
                }
                case DCGatewayOpCodeHeartbeat: {
                    // Acknowledge with a heartbeat.
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
                    // HEARTBEAT_ACK is a liveness signal; durable graph checkpoints happen elsewhere.
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
                        weakSelf.persistedSequenceNumber = 0;
                        weakSelf.sessionId       = nil;
                        weakSelf.resumeGatewayURL = nil;
                        [[DCCacheManager sharedInstance] invalidateGatewayCheckpoint];
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
    self.persistedSequenceNumber = 0;
    [[DCCacheManager sharedInstance] invalidateGatewayCheckpoint];
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
    pthread_rwlock_wrlock(&DCUserRegistryLock);
    self.loadedUsers         = nil;
    pthread_rwlock_unlock(&DCUserRegistryLock);
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