//
//  DCAppDelegate.m
//  Discord Classic
//
//  Created by bag.xml on 3/2/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCAppDelegate.h"
#include "SDWebImageManager.h"
#include <UIKit/UIKit.h>
#import "UIDeviceAdditions.h"
#import "DCServerCommunicator.h"
#import "DCUser.h"
#import "DCRole.h"
#import "DCCacheManager.h"
#import "DCResourceManager.h"
#import "DCChatMediaManager.h"
#import "DCGuild.h"
#import "DCChannel.h"
#import "DCContentManager.h"
#import "DCMessageStore.h"
#import "DCMenuViewController.h"
#import "DCChatViewController.h"
#import "DCTools.h"

@interface DCAppDelegate ()
@property (assign, nonatomic) BOOL shouldReload;
@end

static UIImage *DCDefaultPrivateChannelIcon(DCChannel *channel) {
    if (!channel.snowflake.length) return nil;
    NSNumber *longId = @([channel.snowflake longLongValue]);
    int selector = (int)(([longId longLongValue] >> 22) % 6);
    return [DCContentManager processedIcon:[[DCUser defaultAvatars] objectAtIndex:selector]
                                   context:DCAssetContextList];
}

static void DCHydrateCachedPrivateChannelIcon(DCChannel *channel) {
    if (!channel || !channel.snowflake.length) return;

    channel.icon = DCDefaultPrivateChannelIcon(channel);

    NSString *assetURLString = nil;
    if (channel.iconID.length > 0) {
        assetURLString = [NSString stringWithFormat:
            @"https://cdn.discordapp.com/channel-icons/%@/%@.png?size=64",
            channel.snowflake, channel.iconID];
    } else if (channel.recipients.count > 0) {
        DCUser *recipient = [channel.recipients objectAtIndex:0];
        if (recipient.avatarID.length > 0) {
            assetURLString = [NSString stringWithFormat:
                @"https://cdn.discordapp.com/avatars/%@/%@.png?size=64",
                recipient.snowflake, recipient.avatarID];
        } else {
            int selector = 0;
            if (recipient.discriminator == 0) {
                NSNumber *longId = @([recipient.snowflake longLongValue]);
                selector = (int)(([longId longLongValue] >> 22) % 6);
            } else {
                selector = (int)(recipient.discriminator % 5);
            }
            channel.icon = [DCContentManager processedIcon:
                [[DCUser defaultAvatars] objectAtIndex:selector]
                                                  context:DCAssetContextList];
        }
    }

    if (!assetURLString.length) return;
    NSURL *assetURL = [NSURL URLWithString:assetURLString];
    if (!assetURL) return;

    [[SDWebImageManager sharedManager]
        downloadImageWithURL:assetURL
                     options:0
                    progress:nil
                   completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType,
                               BOOL finished, NSURL *imageURL) {
                       if (!image || !finished) return;
                       dispatch_async(dispatch_get_main_queue(), ^{
                           channel.icon = [DCContentManager processedIcon:image
                                                                  context:DCAssetContextList];
                           [NSNotificationCenter.defaultCenter
                               postNotificationName:@"RELOAD CHANNEL LIST"
                                             object:nil];
                       });
                   }];
}

@implementation DCAppDelegate

// Restore the last server/DM list from the already-decoded cached guild graph
// before the menu is ever presented. A missing saved snowflake means DMs.
- (void)restoreCachedMenuGuildSelectionIfPossible {
    UIViewController *root = self.window.rootViewController;
    if (![root isKindOfClass:[UINavigationController class]]) return;

    UINavigationController *navigationController = (UINavigationController *)root;
    if (navigationController.viewControllers.count == 0) return;

    UIViewController *rootContent = [navigationController.viewControllers objectAtIndex:0];
    if (![rootContent isKindOfClass:[DCMenuViewController class]]) return;

    NSString *savedGuildID = [[DCCacheManager sharedInstance] loadLastSelectedGuildID];
    DCGuild *selectedGuild = nil;
    DCGuild *privateGuild = nil;

    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        BOOL isPrivateGuild = (guild.snowflake == nil &&
            [guild.name isEqualToString:@"Direct Messages"]);
        if (isPrivateGuild) privateGuild = guild;

        if (savedGuildID.length > 0 &&
            [guild.snowflake isEqualToString:savedGuildID]) {
            selectedGuild = guild;
            break;
        }
    }

    if (!selectedGuild) {
        selectedGuild = privateGuild;
        if (savedGuildID.length > 0) {
            DBGLOG(@"[ColdStart] Saved guild %@ is not in cache; using Direct Messages",
                   savedGuildID);
            [[DCCacheManager sharedInstance] clearLastSelectedGuild];
        }
    }

    if (!selectedGuild) return;

    DCMenuViewController *menu = (DCMenuViewController *)rootContent;
    menu.selectedGuild = selectedGuild;
    DCServerCommunicator.sharedInstance.selectedGuild = selectedGuild;

    if (selectedGuild.snowflake.length > 0)
        DBGLOG(@"[ColdStart] Restored last selected guild %@", selectedGuild.snowflake);
}

// Build the initial navigation stack before UIKit presents the storyboard.
// This is the normal cold-restore path once a cached guild/channel graph exists:
// menu stays underneath for Back, while chat is the first visible controller.
- (BOOL)restoreCachedChatNavigationStackIfPossible {
    if (self.experimental || self.hackyMode) {
        return NO;
    }

    NSString *channelID =
        [[DCCacheManager sharedInstance] loadLastActiveChatChannelID];
    if (channelID.length == 0) {
        return NO;
    }

    UIViewController *root = self.window.rootViewController;
    if (![root isKindOfClass:[UINavigationController class]]) {
        return NO;
    }

    UINavigationController *navigationController =
        (UINavigationController *)root;
    if (navigationController.viewControllers.count == 0) {
        return NO;
    }

    UIViewController *rootContent =
        [navigationController.viewControllers objectAtIndex:0];
    if (![rootContent isKindOfClass:[DCMenuViewController class]]) {
        return NO;
    }

    DCGuild *restoredGuild = nil;
    DCChannel *restoredChannel = nil;
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in guild.channels) {
            if ([channel.snowflake isEqualToString:channelID]) {
                restoredGuild = guild;
                restoredChannel = channel;
                break;
            }
        }
        if (restoredChannel) break;
    }

    if (!restoredChannel) {
        // Keep the saved ID. DCMenuViewController will retry after live READY.
        return NO;
    }

    DCMenuViewController *menu = (DCMenuViewController *)rootContent;
    UIStoryboard *storyboard = menu.storyboard;
    if (!storyboard) {
        return NO;
    }

    DCChatViewController *chat = nil;
    @try {
        UIViewController *candidate =
            [storyboard instantiateViewControllerWithIdentifier:
                @"DiscordChatViewController"];
        if ([candidate isKindOfClass:[DCChatViewController class]]) {
            chat = (DCChatViewController *)candidate;
        }
    }
    @catch (NSException *exception) {
        DBGLOG(@"[ColdStart] Could not instantiate chat storyboard identifier: %@",
               exception);
        return NO;
    }

    if (!chat) {
        return NO;
    }

    menu.selectedGuild = restoredGuild;
    menu.selectedChannel = restoredChannel;
    DCServerCommunicator.sharedInstance.selectedGuild = restoredGuild;
    DCServerCommunicator.sharedInstance.selectedChannel = restoredChannel;

    // Do not force-load the menu view hierarchy. It stays underneath the chat
    // and will initialize normally if/when the user taps Back.
    [menu markColdChatRestoreHandled];

    chat.navigationItem.title = restoredChannel.name;

    [navigationController setViewControllers:
        [NSArray arrayWithObjects:menu, chat, nil]
                                     animated:NO];

    DBGLOG(@"[ColdStart] Preloaded navigation stack for chat %@", channelID);
    return YES;
}

- (void)relinkCachedPrivateChannelsAfterUserHydration {
    DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
    NSUInteger relinked = 0;
    NSUInteger hydratedIcons = 0;
    const NSUInteger DCColdStartDMIconHydrationLimit = 12;

    for (DCGuild *guild in communicator.guilds) {
        BOOL isPrivateGuild =
            (guild.snowflake == nil && [guild.name isEqualToString:@"Direct Messages"]);
        if (!isPrivateGuild) continue;

        for (DCChannel *channel in guild.channels) {
            if (channel.recipientIDs.count == 0) continue;

            NSMutableArray *recipients = [NSMutableArray array];
            for (NSString *recipientID in channel.recipientIDs) {
                DCUser *recipient = [communicator userForSnowflake:recipientID];
                if (recipient) [recipients addObject:recipient];
            }
            channel.recipients = recipients;

            NSMutableArray *users = [recipients mutableCopy];
            DCUser *currentUser = [communicator userForSnowflake:communicator.snowflake];
            if (currentUser) [users addObject:currentUser];
            channel.users = users;

            if (channel.type == DCChannelTypeDM && recipients.count == 1) {
                DCUser *recipient = [recipients objectAtIndex:0];
                NSString *displayName = [recipient displayName];
                if (displayName.length) channel.name = displayName;
            }

            if (recipients.count > 0 && hydratedIcons < DCColdStartDMIconHydrationLimit) {
                DCHydrateCachedPrivateChannelIcon(channel);
                hydratedIcons++;
            } else if (!channel.icon) {
                channel.icon = DCDefaultPrivateChannelIcon(channel);
            }
            relinked++;
        }
    }

    if (relinked > 0) {
        DBGLOG(@"[ColdStart] Late-relinked %lu private channels after user hydration",
               (unsigned long)relinked);
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"RELOAD CHANNEL LIST" object:nil];
    }

    // Restored message snapshots already carry their authors' basic display
    // metadata, so avoid an expensive whole-chat reload here. Live Gateway user
    // events will continue to update visible cells through the existing path.
}

- (void)hydrateCachedUsersAfterFirstPaint {
    DCCacheManager *cache = [DCCacheManager sharedInstance];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSDictionary *cachedUsers = [cache loadCachedUsers];
        if (cachedUsers.count == 0) return;

        // Give UIKit a small head start even when the archive is tiny enough to
        // decode before didFinishLaunching returns.  On old hardware the actual
        // decode usually dominates this delay anyway.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
            [communicator mergeCachedUsers:cachedUsers];
            DBGLOG(@"[ColdStart] Hydrated %lu cached users after first paint",
                   (unsigned long)cachedUsers.count);
            [self relinkCachedPrivateChannelsAfterUserHydration];

            // Ensure a READY that raced the late hydration cannot accidentally
            // shrink the durable user cache. saveUsers: performs the archive on
            // DCCacheManager's serial queue.
            [cache saveUsers:[communicator loadedUsersSnapshot]];
        });
    });
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // App version reporting
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    [[NSUserDefaults standardUserDefaults] setObject:[NSString stringWithFormat:@"%@", version]
                                              forKey:@"version"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLogOut)
                                                 name:@"DCUserDidLogOut"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppBadge)
                                                 name:@"READY"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppBadge)
                                                 name:@"MESSAGE ACK"
                                               object:nil];

    self.window.backgroundColor = [UIColor clearColor];
    self.window.opaque          = NO;
    self.shouldReload           = false;
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (VERSION_MIN(@"7.0")) {
        [[NSUserDefaults standardUserDefaults] setBool:YES
                                                forKey:@"UIUseLegacyUI"];
    }

    self.experimental = [[NSUserDefaults standardUserDefaults] boolForKey:@"experimentalMode"];
    self.hackyMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"];

    if (self.experimental && self.hackyMode) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"hackyMode"];
    }

    if (self.experimental) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Experimental" bundle:nil];
        UIViewController *initialViewController = [storyboard instantiateInitialViewController];
        self.window.rootViewController = initialViewController;
        [self.window makeKeyAndVisible];
    } else if (self.hackyMode) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Throwback" bundle:nil];
        UIViewController *initialViewController = [storyboard instantiateInitialViewController];
        self.window.rootViewController = initialViewController;
        [self.window makeKeyAndVisible];
        [UINavigationBar.appearance
            setBackgroundImage:[UIImage imageNamed:@"OldTitlebarTexture"]
                 forBarMetrics:UIBarMetricsDefault];
    }

    // Resource budgets scale with physical memory.
    DCResourceManager *resourceManager = [DCResourceManager sharedManager];
    NSURLCache *urlCache = [[NSURLCache alloc]
        initWithMemoryCapacity:resourceManager.URLMemoryCacheBudget
                  diskCapacity:1024 * 1024 * 60
                      diskPath:nil];
    [NSURLCache setSharedURLCache:urlCache];

    SDImageCache *imageCache = [SDWebImageManager sharedManager].imageCache;
    imageCache.shouldCacheImagesInMemory = YES;
    imageCache.maxMemoryCost = resourceManager.imageMemoryCacheBudget;
    imageCache.maxMemoryCountLimit = resourceManager.imageMemoryCacheCountLimit;
    [resourceManager logResourceProfileWithReason:@"launch"];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("dis.cord.Discord.badgeReset"), NULL, NULL, true
    );

    if (launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey]) {
        NSDictionary *notification = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
        NSDictionary *aps          = notification[@"aps"];
        NSString *channelId        = aps[@"channelId"];
        if (channelId) {
            // A notification tap is an explicit navigation request and should
            // override whichever chat happened to be active before termination.
            [[DCCacheManager sharedInstance]
                saveLastActiveChatChannelID:channelId];

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:@"NavigateToChannel"
                                      object:nil
                                    userInfo:@{@"channelId" : channelId}];
                }
            );
        }
    }

    if (DCServerCommunicator.sharedInstance.token.length) {
        DCCacheManager *cache = [DCCacheManager sharedInstance];

        // Keep first paint independent of the potentially large user archive.
        // Guild/channel records and message snapshots contain enough identity to
        // render immediately; the canonical user database hydrates just after
        // presentation and merges in place.
        [DCServerCommunicator.sharedInstance ensureLoadedUsersRegistry];

        CFAbsoluteTime guildCacheStart = CFAbsoluteTimeGetCurrent();
        NSArray *cachedGuilds = [cache loadCachedGuilds];
        DBGLOG(@"[ColdStartPerf] Guild/channel cache restore: %.3fs",
               CFAbsoluteTimeGetCurrent() - guildCacheStart);
        if (cachedGuilds.count) {
            DCServerCommunicator.sharedInstance.guilds = [cachedGuilds mutableCopy];
            // Persist guild ordering/folder settings with user info.
            // Rebuild displayGuilds from those IDs instead of unarchiving a second
            // complete guild/channel object graph from dc_layout_cache.archive.
            DCServerCommunicator.sharedInstance.cachedDisplayLayout = nil;
            DCServerCommunicator.sharedInstance.guildsIsSorted = NO;

            DCUserInfo *cachedUserInfo = [[DCCacheManager sharedInstance] loadCachedUserInfo];
            if (cachedUserInfo) {
                DCServerCommunicator.sharedInstance.currentUserInfo = cachedUserInfo;
                // READY normally establishes this value. Restore it early so
                // cached DM channel.users can be reconstructed before networking.
                if (cachedUserInfo.id.length > 0) {
                    DCServerCommunicator.sharedInstance.snowflake = cachedUserInfo.id;

                    /*
                     * Keep the signed-in user on the synchronous startup path.
                     * The rest of dc_users_cache.archive can hydrate later, but
                     * the current user's identity/avatar hash is tiny and is
                     * required immediately by restored chats and profile UI.
                     */
                    DCUser *cachedSelf = [DCUser new];
                    cachedSelf.snowflake = cachedUserInfo.id;
                    cachedSelf.username = cachedUserInfo.username;
                    cachedSelf.globalName = cachedUserInfo.globalName;
                    cachedSelf.avatarID = cachedUserInfo.avatar;
                    cachedSelf.guildNicknames = [NSMutableDictionary dictionary];
                    cachedSelf.status = DCUserStatusOffline;
                    [DCServerCommunicator.sharedInstance
                        mergeCachedUsers:@{ cachedSelf.snowflake : cachedSelf }];
                }
            } else {
                DCUserInfo *stub = [DCUserInfo new];
                stub.guildPositions = [NSMutableArray array];
                stub.guildFolders   = [NSMutableArray array];
                DCServerCommunicator.sharedInstance.currentUserInfo = stub;
            }

            NSMutableDictionary *channels = [NSMutableDictionary dictionary];
            NSMutableDictionary *roles = [NSMutableDictionary dictionary];
            NSMutableDictionary *emojis = [NSMutableDictionary dictionary];
            for (DCGuild *guild in cachedGuilds) {
                for (NSString *roleID in guild.roles) {
                    id role = [guild.roles objectForKey:roleID];
                    if (roleID && role) [roles setObject:role forKey:roleID];
                }
                for (NSString *emojiID in guild.emojis) {
                    id emoji = [guild.emojis objectForKey:emojiID];
                    if (emojiID && emoji) [emojis setObject:emoji forKey:emojiID];
                }
                BOOL isPrivateGuild = (guild.snowflake == nil &&
                    [guild.name isEqualToString:@"Direct Messages"]);

                // UIImage objects are intentionally absent from the durable guild
                // archive. Rebuild a cheap local source immediately so the first
                // menu paint already has a finished 48pt composite. Hash-backed
                // guilds show this default only until SDWebImage hydrates the real
                // icon below.
                if (isPrivateGuild) {
                    guild.icon = [UIImage imageNamed:@"privateGuildLogo"];
                } else if (guild.snowflake.length > 0) {
                    unsigned long long value = [guild.snowflake longLongValue];
                    NSUInteger selector = (NSUInteger)((value >> 22) % 6);
                    NSArray *defaults = [DCUser defaultAvatars];
                    if (selector < defaults.count)
                        guild.icon = [defaults objectAtIndex:selector];
                }

                for (DCChannel *channel in guild.channels) {
                    channel.parentGuild = guild;

                    // lastMessageId, lastReadMessageId and mentionCount are already
                    // persisted by DCChannel. channel.unread is derived UI state and
                    // READY normally recomputes it; a successful cold RESUME has no
                    // READY, so rebuild it now from the durable values. Do this only
                    // after parentGuild is restored because checkIfRead propagates to
                    // the guild.
                    BOOL hasLastMessage =
                        [channel.lastMessageId isKindOfClass:[NSString class]] &&
                        channel.lastMessageId.length > 0;
                    BOOL hasReadMessage =
                        [channel.lastReadMessageId isKindOfClass:[NSString class]] &&
                        channel.lastReadMessageId.length > 0;
                    channel.unread = (channel.mentionCount > 0) ||
                        (hasLastMessage &&
                         (!hasReadMessage ||
                          ![channel.lastMessageId isEqualToString:channel.lastReadMessageId]));

                    if (isPrivateGuild && channel.recipientIDs.count > 0) {
                        // User records are intentionally hydrated after first paint.
                        // Keep the persisted channel name immediately available and
                        // defer recipient-object relinking/avatar work until then.
                        if (channel.type == DCChannelTypeDM && channel.recipientIDs.count > 1)
                            channel.type = DCChannelTypeGroupDM;
                        channel.recipients = [NSMutableArray array];
                        channel.users = [NSMutableArray array];
                        channel.icon = DCDefaultPrivateChannelIcon(channel);
                    }

                    if (channel.snowflake) {
                        [channels setObject:channel forKey:channel.snowflake];
                    }
                }

                // Guild unread is also derived from its child channels and is not
                // itself part of the durable archive. Recompute once after every
                // child channel has been relinked/rebuilt.
                [guild checkIfRead];
            }
            DCServerCommunicator.sharedInstance.channels = channels;
            DCServerCommunicator.sharedInstance.loadedRoles = roles;
            DCServerCommunicator.sharedInstance.loadedEmojis = emojis;

            // Restore main-menu server selection first. If a saved chat exists,
            // restoreCachedChatNavigationStackIfPossible intentionally overrides
            // this with that chat's parent guild immediately afterward.
            [self restoreCachedMenuGuildSelectionIfPossible];

            // Resolve and preload the saved chat before the storyboard's first
            // visible presentation. The chat's viewWillAppear then restores its
            // DCChannelWindow normally, so there is no menu frame or push animation.
            [self restoreCachedChatNavigationStackIfPossible];

            // If cold launch restored directly into a server chat, start rehydrating
            // that server's persisted banner hash immediately. SDWebImage will use
            // its disk cache when available, so this does not require READY and does
            // not serialize UIImage objects into the guild archive.
            DCGuild *selectedGuild = DCServerCommunicator.sharedInstance.selectedGuild;
            if (selectedGuild && !selectedGuild.banner &&
                [selectedGuild.bannerID isKindOfClass:[NSString class]] &&
                selectedGuild.bannerID.length > 0 &&
                [selectedGuild.snowflake isKindOfClass:[NSString class]] &&
                selectedGuild.snowflake.length > 0) {
                [DCServerCommunicator.sharedInstance
                    loadGuildBannerHash:selectedGuild.bannerID forGuild:selectedGuild];
            }

            [NSNotificationCenter.defaultCenter
                postNotificationName:@"READY"
                              object:DCServerCommunicator.sharedInstance];

            // DM icon is synchronous — safe to set immediately
            DCGuild *dmGuild = DCServerCommunicator.sharedInstance.guilds.firstObject;
            if ([dmGuild.name isEqualToString:@"Direct Messages"]) {
                dmGuild.icon = [UIImage imageNamed:@"privateGuildLogo"];
            }

            // Defer icon fetches until after handleReady's reloadData has run.
            // Both this block and the reloadData from handleReady are queued on the
            // main queue — this goes in second, so reloadData (and displayGuilds
            // being built) is guaranteed to happen first.
            dispatch_async(dispatch_get_main_queue(), ^{
                for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
                    if (!guild.iconURL) continue;
                    NSURL *url = [NSURL URLWithString:guild.iconURL];
                    if (!url) continue;
                    DCGuild *capturedGuild = guild;
                    [[SDWebImageManager sharedManager]
                        downloadImageWithURL:url
                                     options:0
                                    progress:nil
                                   completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                       if (!image || !finished) return;
                                       dispatch_async(dispatch_get_global_queue(
                                           DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                           CGSize itemSize = CGSizeMake(40.0f, 40.0f);
                                           UIGraphicsBeginImageContextWithOptions(
                                               itemSize, NO, UIScreen.mainScreen.scale
                                           );
                                           [image drawInRect:CGRectMake(
                                               0.0f, 0.0f, itemSize.width, itemSize.height
                                           )];
                                           UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
                                           UIGraphicsEndImageContext();
                                           UIImage *source = resized ?: image;

                                           // Prewarm the source-associated composite here. The
                                           // DCGuild setter on main will then hit this cache.
                                           [DCContentManager processedGuildIcon:source];

                                           dispatch_async(dispatch_get_main_queue(), ^{
                                               capturedGuild.icon = source;
                                               [NSNotificationCenter.defaultCenter
                                                   postNotificationName:@"RELOAD GUILD"
                                                                 object:capturedGuild];
                                           });
                                       });
                                   }];
                }
            });
        }

        [self hydrateCachedUsersAfterFirstPaint];

        // If the previous process durably checkpointed the matching local state,
        // preload its Gateway cursor before opening the socket. handleHello will
        // then send RESUME instead of IDENTIFY.
        [DCServerCommunicator.sharedInstance restorePersistedGatewaySessionIfPossible];
        [DCServerCommunicator.sharedInstance startCommunicator];
    }
    
    UIImage *backNormal = [[UIImage imageNamed:@"NavigationButton"]
     resizableImageWithCapInsets:UIEdgeInsetsMake(0, 14, 0, 6)];
    
    UIImage *backPressed = [[UIImage imageNamed:@"NavigationButtonPressed"]
     resizableImageWithCapInsets:UIEdgeInsetsMake(0, 14, 0, 6)];
    
    [[UIBarButtonItem appearance] setBackButtonBackgroundImage:backNormal
                                                      forState:UIControlStateNormal
                                                    barMetrics:UIBarMetricsDefault];
    
    [[UIBarButtonItem appearance] setBackButtonBackgroundImage:backPressed
                                                      forState:UIControlStateHighlighted
                                                    barMetrics:UIBarMetricsDefault];
    
    [[UIApplication sharedApplication] registerForRemoteNotificationTypes:
     UIRemoteNotificationTypeBadge |
     UIRemoteNotificationTypeSound |
     UIRemoteNotificationTypeAlert];

    return YES;
}


- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo {

    NSDictionary *aps   = userInfo[@"aps"];
    NSString *channelId = aps[@"channelId"];

    if (channelId) {
        UIApplicationState state = [application applicationState];
        if (state == UIApplicationStateInactive
            || state == UIApplicationStateBackground) {
            // App was in the background or not running, meaning the user tapped
            // the notification
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"NavigateToChannel"
                                  object:nil
                                userInfo:@{@"channelId" : channelId}];
            });
        } else {
            // ok requis
        }
    }
}

- (void)application:(UIApplication *)application
didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    
    NSMutableString *token = [NSMutableString stringWithCapacity:deviceToken.length * 2];
    const unsigned char *bytes = deviceToken.bytes;
    for (NSInteger i = 0; i < deviceToken.length; i++) {
        [token appendFormat:@"%02x", bytes[i]];
    }
    
    NSLog(@"APNs device token: %@", token);
    [DCServerCommunicator.sharedInstance registerPushToken:token];
}

- (void)application:(UIApplication *)application
didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"Failed to register for push: %@", error);
}

- (void)updateAppBadge {
    NSInteger total = 0;
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        total += guild.mentionCount;
    }
    [UIApplication sharedApplication].applicationIconBadgeNumber = total;
}

- (void)handleLogOut {
    [[DCMessageStore sharedInstance] removeAllWindows];
    [[DCCacheManager sharedInstance] invalidateFolderCompositeCache];
    [[DCCacheManager sharedInstance] clearLastActiveChatChannel];
    [[DCCacheManager sharedInstance] clearLastSelectedGuild];
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:self.experimental ? @"Experimental" : @"Storyboard" bundle:nil];
    UIViewController *freshRoot = [storyboard instantiateInitialViewController];

    self.loggingOut = YES;
    [freshRoot view];
    [freshRoot.view layoutIfNeeded];
    
    [UIView transitionWithView:self.window
                      duration:0.8
                       options:UIViewAnimationOptionTransitionFlipFromLeft
                    animations:^{
                        self.window.rootViewController = freshRoot;
                    }
                    completion:nil];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.shouldReload = DCServerCommunicator.sharedInstance.didAuthenticate;

    // Drop decoded image residency on background while keeping compressed disk caches.
    SDImageCache *imageCache = [SDWebImageManager sharedManager].imageCache;
    imageCache.shouldCacheImagesInMemory = NO;
    [imageCache clearMemory];
    [[DCChatMediaManager sharedManager] enterBackground];
    [[DCResourceManager sharedManager] logResourceProfileWithReason:@"entered background"];
    // Flush cold-start state and publish the Gateway sequence only after those
    // writes are durable. A short background task prevents iOS from suspending
    // the process halfway through the checkpoint. Message windows remain an
    // opportunistic UI cache; their queued writes naturally run before the
    // Gateway checkpoint because DCCacheManager uses one serial disk queue.
    if (DCServerCommunicator.sharedInstance.didAuthenticate
        && DCServerCommunicator.sharedInstance.guilds.count > 0) {
        [[DCMessageStore sharedInstance] checkpointAllWindows];

        __block UIBackgroundTaskIdentifier checkpointTask = UIBackgroundTaskInvalid;
        checkpointTask = [application beginBackgroundTaskWithExpirationHandler:^{
            if (checkpointTask != UIBackgroundTaskInvalid) {
                [application endBackgroundTask:checkpointTask];
                checkpointTask = UIBackgroundTaskInvalid;
            }
        }];

        [DCServerCommunicator.sharedInstance
            persistDurableGatewayStateWithCompletion:^(BOOL success) {
                if (!success) {
                    DBGLOG(@"[GatewayCheckpoint] Background checkpoint was not saved");
                }
                if (checkpointTask != UIBackgroundTaskInvalid) {
                    [application endBackgroundTask:checkpointTask];
                    checkpointTask = UIBackgroundTaskInvalid;
                }
            }];
    }
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    [[NSUserDefaults standardUserDefaults] synchronize];

    DCResourceManager *resourceManager = [DCResourceManager sharedManager];
    SDImageCache *imageCache = [SDWebImageManager sharedManager].imageCache;
    imageCache.maxMemoryCost = resourceManager.imageMemoryCacheBudget;
    imageCache.maxMemoryCountLimit = resourceManager.imageMemoryCacheCountLimit;
    imageCache.shouldCacheImagesInMemory = YES;
    [[DCChatMediaManager sharedManager] enterForeground];
    [resourceManager logResourceProfileWithReason:@"entering foreground"];
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (void)applicationWillTerminate:(UIApplication *)application {
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    NSLog(@"Memory warning received, clearing image cache!");
    [[DCResourceManager sharedManager] noteMemoryWarning];
    [SDWebImageManager.sharedManager.imageCache clearMemory];
    [[DCChatMediaManager sharedManager] handleMemoryWarning];
}

@end
