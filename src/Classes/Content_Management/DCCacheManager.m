//
//  DCCacheManager.m
//  Discord Classic
//
//  Created by Ayeris on 3/20/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCCacheManager.h"
#import "DCMessageLayout.h"
#import "DCUser.h"
#import "DCMessage.h"
#import "DCChannelWindow.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"

@implementation DCMessageCacheEntry
@end

@interface DCCacheManager ()
@property (strong, nonatomic) NSMutableDictionary *messageCache;
@property (strong, nonatomic) NSMutableDictionary *avatarCache;
@property (strong, nonatomic) NSMutableDictionary *decorationCache;
@property (strong, nonatomic) NSMutableDictionary *emojiCache;
@property (strong, nonatomic) NSMutableDictionary *layoutCache;
@property (nonatomic, assign) dispatch_queue_t cacheQueue;
@end

@implementation DCCacheManager

+ (instancetype)sharedInstance {
    static DCCacheManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [DCCacheManager new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _messageCache    = [NSMutableDictionary dictionary];
        _avatarCache     = [NSMutableDictionary dictionary];
        _decorationCache = [NSMutableDictionary dictionary];
        _emojiCache      = [NSMutableDictionary dictionary];
        _layoutCache     = [NSMutableDictionary dictionary];
        self.cacheQueue = dispatch_queue_create("com.discordclassic.cacheQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (self.cacheQueue) {
        dispatch_release(self.cacheQueue);
    }
}

// --- Message cache ---

// DCMessageCahceEntry contains  4 properties: 
// cellHeight, contentHeight, textHeight, attributedContent

// Private helper
- (NSString *)cacheKeyForSnowflake:(NSString *)snowflake width:(CGFloat)width {
    return [NSString stringWithFormat:@"%@_%.0f", snowflake, width];
}

// Private helper — composite key for the layout cache. Shares the
// "<snowflake>_..." prefix convention with cacheKeyForSnowflake:width:
// so -invalidateSnowflake: can sweep both dictionaries the same way.
- (NSString *)layoutCacheKeyForSnowflake:(NSString *)snowflake
                                tableWidth:(CGFloat)tableWidth
                         previousSnowflake:(NSString *)previousSnowflake
                             nextSnowflake:(NSString *)nextSnowflake
                           editedTimestamp:(NSDate *)editedTimestamp {
    if (!snowflake) return nil;
    NSString *prev = previousSnowflake ?: @"-";
    NSString *next = nextSnowflake ?: @"-";
    NSTimeInterval edited = editedTimestamp ? [editedTimestamp timeIntervalSince1970] : 0;
    return [NSString stringWithFormat:@"%@_layout_w%.0f_p%@_n%@_e%.0f",
            snowflake, tableWidth, prev, next, edited];
}

- (DCMessageLayout *)layoutForSnowflake:(NSString *)snowflake
                              tableWidth:(CGFloat)tableWidth
                       previousSnowflake:(NSString *)previousSnowflake
                           nextSnowflake:(NSString *)nextSnowflake
                         editedTimestamp:(NSDate *)editedTimestamp {
    NSString *key = [self layoutCacheKeyForSnowflake:snowflake
                                           tableWidth:tableWidth
                                   previousSnowflake:previousSnowflake
                                       nextSnowflake:nextSnowflake
                                     editedTimestamp:editedTimestamp];
    if (!key) return nil;
    __block DCMessageLayout *result = nil;
    dispatch_sync(self.cacheQueue, ^{
        result = self.layoutCache[key];
    });
    return result;
}

- (void)setLayout:(DCMessageLayout *)layout
       forSnowflake:(NSString *)snowflake
         tableWidth:(CGFloat)tableWidth
  previousSnowflake:(NSString *)previousSnowflake
      nextSnowflake:(NSString *)nextSnowflake
    editedTimestamp:(NSDate *)editedTimestamp {
    NSString *key = [self layoutCacheKeyForSnowflake:snowflake
                                           tableWidth:tableWidth
                                   previousSnowflake:previousSnowflake
                                       nextSnowflake:nextSnowflake
                                     editedTimestamp:editedTimestamp];
    if (!key || !layout) return;
    dispatch_async(self.cacheQueue, ^{
        self.layoutCache[key] = layout;
    });
}

- (id)performCacheOperation:(id (^)(void))block {
    __block id result = nil;
    dispatch_sync(self.cacheQueue, ^{ result = block(); });
    return result;
}

- (void)performAsyncCacheOperation:(void (^)(void))block {
    dispatch_async(self.cacheQueue, ^{ block(); });
}

// Width-aware read
- (DCMessageCacheEntry *)cacheEntryForSnowflake:(NSString *)snowflake width:(CGFloat)width {
    if (!snowflake) return nil;
    return self.messageCache[[self cacheKeyForSnowflake:snowflake width:width]];
}

// Width-aware write
- (void)setCacheEntry:(DCMessageCacheEntry *)entry forSnowflake:(NSString *)snowflake width:(CGFloat)width {
    if (!snowflake || !entry) return;
    self.messageCache[[self cacheKeyForSnowflake:snowflake width:width]] = entry;
}

// Updated invalidateSnowflake — clears all width/layout variants
- (void)invalidateSnowflake:(NSString *)snowflake {
    if (!snowflake) return;
    NSString *prefix = [snowflake stringByAppendingString:@"_"];
    dispatch_sync(self.cacheQueue, ^{
        [self removeKeysWithPrefix:prefix fromDictionary:self.messageCache];
        [self removeKeysWithPrefix:prefix fromDictionary:self.layoutCache];
    });
}

- (void)removeKeysWithPrefix:(NSString *)prefix fromDictionary:(NSMutableDictionary *)dictionary {
    NSArray *keys = [dictionary.allKeys copy];
    for (NSString *key in keys) {
        if ([key hasPrefix:prefix]) {
            [dictionary removeObjectForKey:key];
        }
    }
}

- (void)invalidateAllMessages {
    dispatch_sync(self.cacheQueue, ^{
        [self.messageCache removeAllObjects];
        [self.layoutCache removeAllObjects];
    });
}

// --- Avatar cache ---

- (UIImage *)avatarForUserSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    return self.avatarCache[snowflake];
}

- (void)setAvatar:(UIImage *)image forUserSnowflake:(NSString *)snowflake {
    if (!snowflake || !image) return;
    self.avatarCache[snowflake] = image;
}

// --- Avatar decoration cache ---

- (UIImage *)decorationForUserSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    return self.decorationCache[snowflake];
}

- (void)setDecoration:(UIImage *)image forUserSnowflake:(NSString *)snowflake {
    if (!snowflake || !image) return;
    self.decorationCache[snowflake] = image;
}

// --- Emoji cache ---

- (UIImage *)imageForEmojiSnowflake:(NSString *)snowflake {
    if (!snowflake) return nil;
    return self.emojiCache[snowflake];
}

- (void)setImage:(UIImage *)image forEmojiSnowflake:(NSString *)snowflake {
    if (!snowflake || !image) return;
    self.emojiCache[snowflake] = image;
}

// --- Memory management ---

- (void)handleMemoryWarning {
    // Flush attributed content from message entries but keep heights
    // Heights are cheap to store and expensive to recalculate
    for (DCMessageCacheEntry *entry in self.messageCache.allValues) {
        entry.attributedContent = nil;
    }
    // Flush emoji images — these re-download automatically when needed
    [self.emojiCache removeAllObjects];
    [self.layoutCache removeAllObjects];
    // SDWebImage memory cache is handled separately by the app delegate
}


// --- Message window cache (disk-backed) ---

static const NSInteger DCMessageWindowCacheVersion = 5;
static const NSUInteger DCMessageWindowDiskLimit = 10;
static const NSUInteger DCMessageWindowMessageLimit = 80;

- (NSString *)messageWindowCacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0]
        stringByAppendingPathComponent:@"dc_message_windows"];
}

- (NSString *)messageWindowCachePathForChannel:(NSString *)channelSnowflake {
    if (![channelSnowflake isKindOfClass:[NSString class]] ||
        channelSnowflake.length == 0) return nil;
    return [[self messageWindowCacheDirectory]
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.archive", channelSnowflake]];
}

- (NSDictionary *)persistentRecordForMessage:(DCMessage *)message {
    if (!message.snowflake.length ||
        ![message.sourceJSON isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    /*
     * Persist the original Discord message dictionary, not a second rendering
     * model. Cold restore replays it through DCTools convertJsonMessage:, exactly
     * like REST/Gateway data. That means Markdown, custom emoji, embeds, media
     * XIBs, stickers, replies, and future renderer changes stay in one code path.
     *
     * Preserve pingingUser as a tiny derived override because cached guilds do
     * not yet persist userRoles; role-mention detection may otherwise differ
     * briefly before READY repopulates that list.
     */
    return [NSDictionary dictionaryWithObjectsAndKeys:
        message.sourceJSON, @"json",
        [NSNumber numberWithBool:message.pingingUser], @"pingingUser",
        nil];
}

- (DCMessage *)messageFromPersistentRecord:(NSDictionary *)record {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *json = [record objectForKey:@"json"];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    __block DCMessage *message = nil;
    void (^convert)(void) = ^{
        message = [DCTools convertJsonMessage:json];
    };

    // convertJsonMessage builds UIKit/DTCoreText state and attachment XIBs. Use
    // the same main-thread environment as the normal downloaded-message path.
    if ([NSThread isMainThread]) {
        convert();
    } else {
        dispatch_sync(dispatch_get_main_queue(), convert);
    }

    if (!message) return nil;

    id ping = [record objectForKey:@"pingingUser"];
    if ([ping respondsToSelector:@selector(boolValue)]) {
        message.pingingUser = [ping boolValue];
    }

    return message;
}

- (NSDictionary *)persistentRecordForMessageWindow:(DCChannelWindow *)window {
    if (!window.channelSnowflake.length) return nil;

    NSArray *messages = window.messages;
    if (messages.count > DCMessageWindowMessageLimit) {
        messages = [messages subarrayWithRange:
            NSMakeRange(messages.count - DCMessageWindowMessageLimit,
                        DCMessageWindowMessageLimit)];
    }

    NSMutableArray *records = [NSMutableArray arrayWithCapacity:messages.count];
    for (DCMessage *message in messages) {
        NSDictionary *record = [self persistentRecordForMessage:message];
        if (record) [records addObject:record];
    }

    return @{
        @"version" : [NSNumber numberWithInteger:DCMessageWindowCacheVersion],
        @"channelID" : window.channelSnowflake,
        @"messages" : records,
        @"atPresentTime" : [NSNumber numberWithBool:window.atPresentTime],
        @"hasMoreBefore" : [NSNumber numberWithBool:window.hasMoreBefore],
        @"hasMoreAfter" : [NSNumber numberWithBool:window.hasMoreAfter],
        @"savedContentOffsetY" : [NSNumber numberWithDouble:window.savedContentOffsetY],
        @"hasSavedContentOffset" : [NSNumber numberWithBool:window.hasSavedContentOffset]
    };
}

- (void)pruneMessageWindowCacheDirectory {
    NSString *directory = [self messageWindowCacheDirectory];
    NSArray *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:directory error:nil];
    if (files.count <= DCMessageWindowDiskLimit) return;

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:files.count];
    for (NSString *filename in files) {
        NSString *path = [directory stringByAppendingPathComponent:filename];
        NSDictionary *attributes = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path error:nil];
        NSDate *date = [attributes objectForKey:NSFileModificationDate] ?: [NSDate distantPast];
        [entries addObject:@{ @"path": path, @"date": date }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a objectForKey:@"date"] compare:[b objectForKey:@"date"]];
    }];

    NSUInteger removeCount = entries.count - DCMessageWindowDiskLimit;
    for (NSUInteger i = 0; i < removeCount; i++) {
        [[NSFileManager defaultManager]
            removeItemAtPath:[[entries objectAtIndex:i] objectForKey:@"path"]
                       error:nil];
    }
}

- (void)saveMessageWindow:(DCChannelWindow *)window {
    if (!window.channelSnowflake.length) return;
    if (window.messages.count == 0) {
        [self invalidateMessageWindowForChannel:window.channelSnowflake];
        return;
    }

    // Materialize immutable primitive records before hopping queues; live
    // DCMessage objects continue mutating on the UI thread.
    NSDictionary *root = [self persistentRecordForMessageWindow:window];
    NSString *path = [self messageWindowCachePathForChannel:window.channelSnowflake];
    if (!root || !path) return;

    dispatch_async(self.cacheQueue, ^{
        @autoreleasepool {
            @try {
                NSString *directory = [self messageWindowCacheDirectory];
                [[NSFileManager defaultManager]
                    createDirectoryAtPath:directory
                    withIntermediateDirectories:YES
                    attributes:nil
                    error:nil];
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:root];
                if (![data writeToFile:path atomically:YES]) {
                    NSLog(@"[DCCacheManager] Message window save failed for %@", path);
                    return;
                }
                [self pruneMessageWindowCacheDirectory];
            }
            @catch (NSException *e) {
                NSLog(@"[DCCacheManager] Message window save failed: %@", e);
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }
        }
    });
}

- (DCChannelWindow *)loadMessageWindowForChannel:(NSString *)channelSnowflake {
    NSString *path = [self messageWindowCachePathForChannel:channelSnowflake];
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;

    @try {
        NSDictionary *root = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        if (![root isKindOfClass:[NSDictionary class]]) {
            [self invalidateMessageWindowForChannel:channelSnowflake];
            return nil;
        }
        NSNumber *version = [root objectForKey:@"version"];
        if (![version respondsToSelector:@selector(integerValue)] ||
            [version integerValue] != DCMessageWindowCacheVersion) {
            [self invalidateMessageWindowForChannel:channelSnowflake];
            return nil;
        }

        DCChannelWindow *window = [[DCChannelWindow alloc]
            initWithChannelSnowflake:channelSnowflake];
        NSArray *records = [root objectForKey:@"messages"];
        if ([records isKindOfClass:[NSArray class]]) {
            for (NSDictionary *record in records) {
                DCMessage *message = [self messageFromPersistentRecord:record];
                if (message) [window.messages addObject:message];
            }
        }
        if (window.messages.count == 0) return nil;

        id value = [root objectForKey:@"atPresentTime"];
        if ([value respondsToSelector:@selector(boolValue)])
            window.atPresentTime = [value boolValue];
        value = [root objectForKey:@"hasMoreBefore"];
        if ([value respondsToSelector:@selector(boolValue)])
            window.hasMoreBefore = [value boolValue];
        value = [root objectForKey:@"hasMoreAfter"];
        if ([value respondsToSelector:@selector(boolValue)])
            window.hasMoreAfter = [value boolValue];
        value = [root objectForKey:@"savedContentOffsetY"];
        if ([value respondsToSelector:@selector(doubleValue)])
            window.savedContentOffsetY = [value doubleValue];
        value = [root objectForKey:@"hasSavedContentOffset"];
        if ([value respondsToSelector:@selector(boolValue)])
            window.hasSavedContentOffset = [value boolValue];

        return window;
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] Message window %@ corrupt, discarding: %@",
              channelSnowflake, e);
        [self invalidateMessageWindowForChannel:channelSnowflake];
        return nil;
    }
}

- (void)invalidateMessageWindowForChannel:(NSString *)channelSnowflake {
    NSString *path = [self messageWindowCachePathForChannel:channelSnowflake];
    if (!path) return;
    dispatch_async(self.cacheQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    });
}

- (void)invalidateAllMessageWindows {
    NSString *directory = [self messageWindowCacheDirectory];
    dispatch_async(self.cacheQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    });
}

// --- Last active screen ---

static NSString * const DCLastActiveChatChannelIDKey =
    @"DCLastActiveChatChannelID";

- (void)saveLastActiveChatChannelID:(NSString *)channelSnowflake {
    if (![channelSnowflake isKindOfClass:[NSString class]] ||
        channelSnowflake.length == 0) {
        [self clearLastActiveChatChannel];
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:channelSnowflake forKey:DCLastActiveChatChannelIDKey];

    // Navigation changes are infrequent, so make this crash-safe rather than
    // waiting for the next background transition to flush NSUserDefaults.
    [defaults synchronize];
}

- (NSString *)loadLastActiveChatChannelID {
    id value = [[NSUserDefaults standardUserDefaults]
        objectForKey:DCLastActiveChatChannelIDKey];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (void)clearLastActiveChatChannel {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:DCLastActiveChatChannelIDKey];
    [defaults synchronize];
}

// --- Guild/structure cache (disk-backed) ---

- (NSString *)guildCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = [paths objectAtIndex:0];
    return [documents stringByAppendingPathComponent:@"dc_guild_cache.archive"];
}

- (void)saveGuilds:(NSArray *)guilds {
    if (!guilds.count) return;
    NSString *path = [self guildCachePath];
    @try {
        [NSKeyedArchiver archiveRootObject:guilds toFile:path];
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] Guild cache save failed: %@", e);
        // Remove any partial file that may have been written
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

- (NSArray *)loadCachedGuilds {
    NSString *path = [self guildCachePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    @try {
        return [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] Guild cache corrupt, discarding: %@", e);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
}

- (void)invalidateGuildCache {
    NSString *path = [self guildCachePath];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

// --- Display Layout cache (disk-backed) ---

- (NSString *)displayLayoutCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"dc_layout_cache.archive"];
}

- (void)saveDisplayLayout:(NSArray *)displayGuilds {
    if (!displayGuilds.count) return;
    NSString *path = [self displayLayoutCachePath];
    @try {
        [NSKeyedArchiver archiveRootObject:displayGuilds toFile:path];
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] Layout cache save failed: %@", e);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

- (NSArray *)loadDisplayLayout {
    NSString *path = [self displayLayoutCachePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    @try {
        return [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] Layout cache corrupt, discarding: %@", e);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
}

- (void)invalidateDisplayLayout {
    NSString *path = [self displayLayoutCachePath];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}


// --- User cache (disk-backed) ---

static const NSInteger DCUserCacheVersion = 1;

- (NSString *)userCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0]
        stringByAppendingPathComponent:@"dc_users_cache.archive"];
}

- (NSDictionary *)persistentRecordForUser:(DCUser *)user {
    if (!user || !user.snowflake) return nil;

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    [record setObject:user.snowflake forKey:@"id"];

    if (user.username)           [record setObject:user.username forKey:@"username"];
    if (user.globalName)         [record setObject:user.globalName forKey:@"globalName"];
    if (user.avatarID && (id)user.avatarID != [NSNull null])
        [record setObject:user.avatarID forKey:@"avatar"];
    if (user.avatarDecorationID && (id)user.avatarDecorationID != [NSNull null])
        [record setObject:user.avatarDecorationID forKey:@"avatarDecoration"];
    if (user.biography)          [record setObject:user.biography forKey:@"biography"];
    if (user.guildNicknames.count)
        [record setObject:[NSDictionary dictionaryWithDictionary:user.guildNicknames]
                   forKey:@"guildNicknames"];

    [record setObject:[NSNumber numberWithInteger:user.discriminator]
               forKey:@"discriminator"];
    return record;
}

- (DCUser *)userFromPersistentRecord:(NSDictionary *)record {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;

    NSString *snowflake = [record objectForKey:@"id"];
    if (![snowflake isKindOfClass:[NSString class]] || snowflake.length == 0)
        return nil;

    DCUser *user = [DCUser new];
    user.snowflake = snowflake;

    id value = [record objectForKey:@"username"];
    if ([value isKindOfClass:[NSString class]]) user.username = value;

    value = [record objectForKey:@"globalName"];
    if ([value isKindOfClass:[NSString class]]) user.globalName = value;

    value = [record objectForKey:@"avatar"];
    if ([value isKindOfClass:[NSString class]]) user.avatarID = value;

    value = [record objectForKey:@"avatarDecoration"];
    if ([value isKindOfClass:[NSString class]]) user.avatarDecorationID = value;

    value = [record objectForKey:@"biography"];
    if ([value isKindOfClass:[NSString class]]) user.biography = value;

    value = [record objectForKey:@"guildNicknames"];
    if ([value isKindOfClass:[NSDictionary class]])
        user.guildNicknames = [value mutableCopy];
    else
        user.guildNicknames = [NSMutableDictionary dictionary];

    value = [record objectForKey:@"discriminator"];
    if ([value respondsToSelector:@selector(integerValue)])
        user.discriminator = [value integerValue];

    // Presence is intentionally ephemeral. A restored user starts offline until
    // the Gateway tells us otherwise. Images are also restored lazily from the
    // normal image cache using the persisted hashes.
    user.status = DCUserStatusOffline;
    return user;
}

- (void)saveUsers:(NSDictionary *)users {
    if (!users.count) return;

    // Capture the dictionary membership now, then build the archive on the
    // serial cache queue so callers never block on thousands of user records.
    NSDictionary *snapshot = [NSDictionary dictionaryWithDictionary:users];
    NSString *path = [self userCachePath];

    dispatch_async(self.cacheQueue, ^{
        @autoreleasepool {
            @try {
                NSMutableDictionary *records = [NSMutableDictionary dictionaryWithCapacity:snapshot.count];
                for (NSString *snowflake in snapshot) {
                    DCUser *user = [snapshot objectForKey:snowflake];
                    NSDictionary *record = [self persistentRecordForUser:user];
                    if (record) [records setObject:record forKey:snowflake];
                }

                NSDictionary *root = @{
                    @"version" : [NSNumber numberWithInteger:DCUserCacheVersion],
                    @"users" : records
                };

                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:root];
                if (![data writeToFile:path atomically:YES]) {
                    NSLog(@"[DCCacheManager] User cache save failed writing %@", path);
                }
            }
            @catch (NSException *e) {
                NSLog(@"[DCCacheManager] User cache save failed: %@", e);
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }
        }
    });
}

- (NSDictionary *)loadCachedUsers {
    NSString *path = [self userCachePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;

    @try {
        NSDictionary *root = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        if (![root isKindOfClass:[NSDictionary class]]) {
            [self invalidateUserCache];
            return nil;
        }

        NSNumber *version = [root objectForKey:@"version"];
        if (![version respondsToSelector:@selector(integerValue)] ||
            [version integerValue] != DCUserCacheVersion) {
            NSLog(@"[DCCacheManager] Unsupported user cache version %@, discarding", version);
            [self invalidateUserCache];
            return nil;
        }

        NSDictionary *records = [root objectForKey:@"users"];
        if (![records isKindOfClass:[NSDictionary class]]) return nil;

        NSMutableDictionary *users = [NSMutableDictionary dictionaryWithCapacity:records.count];
        for (NSString *snowflake in records) {
            DCUser *user = [self userFromPersistentRecord:[records objectForKey:snowflake]];
            if (user) [users setObject:user forKey:user.snowflake];
        }
        return users;
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] User cache corrupt, discarding: %@", e);
        [self invalidateUserCache];
        return nil;
    }
}

- (void)invalidateUserCache {
    NSString *path = [self userCachePath];
    // Serialize invalidation behind any queued save so logout cannot leave a
    // just-written cache file behind.
    dispatch_sync(self.cacheQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    });
}

// --- User Info cache (disk-backed) ---

- (NSString *)userInfoCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0]
        stringByAppendingPathComponent:@"dc_userinfo_cache.archive"];
}

- (void)saveUserInfo:(DCUserInfo *)userInfo {
    if (!userInfo) return;
    NSString *path = [self userInfoCachePath];
    @try {
        [NSKeyedArchiver archiveRootObject:userInfo toFile:path];
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] UserInfo cache save failed: %@", e);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

- (DCUserInfo *)loadCachedUserInfo {
    NSString *path = [self userInfoCachePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    @try {
        return [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    }
    @catch (NSException *e) {
        NSLog(@"[DCCacheManager] UserInfo cache corrupt, discarding: %@", e);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
}
@end