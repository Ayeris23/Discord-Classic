//
//  DCCacheManager.h
//  Discord Classic
//
//  Created by Ayeris on 3/20/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@class DCMessage;
@class DCChannelWindow;
@class DCMessageLayout;
@class DCUser;
@class DCUserInfo;
@class DCEmoji;

@interface DCMessageCacheEntry : NSObject
@property (nonatomic) CGFloat cellHeight;
@property (nonatomic) CGFloat contentHeight;
@property (nonatomic) CGFloat textHeight;
@property (strong, nonatomic) NSAttributedString *attributedContent;
@end

@interface DCCacheManager : NSObject

+ (instancetype)sharedInstance;

// --- Message cache ---
// Store and retrieve full cache entry for a message
- (DCMessageCacheEntry *)cacheEntryForSnowflake:(NSString *)snowflake width:(CGFloat)width;
- (void)setCacheEntry:(DCMessageCacheEntry *)entry forSnowflake:(NSString *)snowflake width:(CGFloat)width;

// Targeted invalidation
- (void)invalidateSnowflake:(NSString *)snowflake;

// --- Layout cache ---
// Composite-key cache for DCMessageLayout, keyed by snowflake, table
// width, immediate neighbor snowflakes, and the message's edited
// timestamp. A change to either neighbor snowflake (insertion or
// eviction at either edge) or to editedTimestamp produces a natural
// cache miss on the next lookup. Other state changes — attachment load
// completing, reference snapshot refresh — don't have version fields in
// the key yet (those land with the DCMessage.h changes in a later
// slice), so callers still need -invalidateSnowflake: for those cases.
- (DCMessageLayout *)layoutForSnowflake:(NSString *)snowflake
                              tableWidth:(CGFloat)tableWidth
                       previousSnowflake:(NSString *)previousSnowflake
                           nextSnowflake:(NSString *)nextSnowflake
                         editedTimestamp:(NSDate *)editedTimestamp;

- (void)setLayout:(DCMessageLayout *)layout
       forSnowflake:(NSString *)snowflake
         tableWidth:(CGFloat)tableWidth
  previousSnowflake:(NSString *)previousSnowflake
      nextSnowflake:(NSString *)nextSnowflake
    editedTimestamp:(NSDate *)editedTimestamp;

// All cache access must go through the cache queue.
// Use -performCacheOperation: for synchronous reads,
// -performAsyncCacheOperation: for background writes.
- (id)performCacheOperation:(id (^)(void))block;
- (void)performAsyncCacheOperation:(void (^)(void))block;

// Full flush — use on memory warning or channel change
- (void)invalidateAllMessages;

// --- Avatar cache ---
- (UIImage *)avatarForUserSnowflake:(NSString *)snowflake;
- (void)setAvatar:(UIImage *)image forUserSnowflake:(NSString *)snowflake;

// --- Avatar decoration cache ---
- (UIImage *)decorationForUserSnowflake:(NSString *)snowflake;
- (void)setDecoration:(UIImage *)image forUserSnowflake:(NSString *)snowflake;

// --- Emoji cache ---
- (UIImage *)imageForEmojiSnowflake:(NSString *)snowflake;
- (void)setImage:(UIImage *)image forEmojiSnowflake:(NSString *)snowflake;

// --- Memory management ---
- (void)handleMemoryWarning;


// --- Message window cache (disk-backed) ---
// Bounded per-channel snapshots used for immediate cold-start rendering.
- (void)saveMessageWindow:(DCChannelWindow *)window;
- (DCChannelWindow *)loadMessageWindowForChannel:(NSString *)channelSnowflake;
- (void)invalidateMessageWindowForChannel:(NSString *)channelSnowflake;
- (void)invalidateAllMessageWindows;

// --- Last active screen ---
// nil last-active chat means the app should cold-launch to the main menu.
- (void)saveLastActiveChatChannelID:(NSString *)channelSnowflake;
- (NSString *)loadLastActiveChatChannelID;
- (void)clearLastActiveChatChannel;

// Main-menu guild selection. A missing saved guild intentionally means the
// synthetic Direct Messages guild, which has no Discord snowflake.
- (void)saveLastSelectedGuildID:(NSString *)guildSnowflake;
- (NSString *)loadLastSelectedGuildID;
- (void)clearLastSelectedGuild;

// --- Gateway resume checkpoint (disk-backed) ---
// This record is deliberately written only after the state represented by
// sequence has been queued/durably flushed. It is tiny and is not a second
// copy of application state; it is only the cursor Discord needs for RESUME.
- (void)saveGatewayCheckpointWithSessionID:(NSString *)sessionID
                                 resumeURL:(NSString *)resumeURL
                                  sequence:(NSInteger)sequence
                                    userID:(NSString *)userID
                                completion:(void (^)(BOOL success))completion;
- (NSDictionary *)loadGatewayCheckpoint;
- (void)invalidateGatewayCheckpoint;

// --- Guild/structure cache (disk-backed) ---
- (void)saveGuilds:(NSArray *)guilds;
- (NSArray *)loadCachedGuilds;
- (void)invalidateGuildCache;

// --- Diaply Layout cache (disk-backed) ---
- (void)saveDisplayLayout:(NSArray *)displayGuilds;
- (NSArray *)loadDisplayLayout;
- (void)invalidateDisplayLayout;

// --- Folder composite cache (disk-backed derived UI asset) ---
// Folder composites are tiny, slow-changing PNGs keyed by folder membership
// and the first four guild icon hashes. They are safe to discard/rebuild.
- (UIImage *)cachedFolderCompositeForFolderID:(NSInteger)folderID
                                      cacheKey:(NSString *)cacheKey;
- (void)saveFolderComposite:(UIImage *)image
                forFolderID:(NSInteger)folderID
                   cacheKey:(NSString *)cacheKey;
- (void)invalidateFolderCompositeCache;

// --- User cache (disk-backed) ---
// Users are persisted as small durable records rather than archiving runtime
// UIImages/processed assets. Last-known presence is retained as part of the
// resumable state baseline and is overwritten by live Gateway presence data.
- (void)saveUsers:(NSDictionary *)users;
- (NSDictionary *)loadCachedUsers;
- (void)invalidateUserCache;

// --- User Info cache (disk-backed) ---
- (void)saveUserInfo:(DCUserInfo *)userInfo;
- (DCUserInfo *)loadCachedUserInfo;

@end