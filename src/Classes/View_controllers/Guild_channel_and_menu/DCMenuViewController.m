//
//  DCMenuViewController.m
//  Discord Classic
//
//  Created by bag.xml on 27/01/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCInterfaceStyle.h"
#import "DCActionSheetPresenter.h"
#import "DCMenuViewController.h"
#import "DCConnectionPopup.h"
#include "DCTools.h"
#include <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
#include <UIKit/UIKit.h>
#include <dispatch/dispatch.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/NSObjCRuntime.h>
#include "DCGuild.h"
#include "DCGuildFolder.h"
#include "DCServerCommunicator.h"
#include "DCUser.h"
#import "MentionBadge.h"
#import "DCContentManager.h"
#import "DCCacheManager.h"
#import "DCIPadSplitViewController.h"
#import "DCChannelCategoryHeaderView.h"
#import "DCUnreadEdgeIndicatorView.h"
#import <math.h>

@interface DCMenuViewController ()
@property NSMutableArray *displayGuilds;
@property (strong, nonatomic) NSArray *displayChannels;
@property (strong, nonatomic) NSArray *displayChannelSections;
@property (strong, nonatomic) NSMutableSet *collapsedChannelCategoryKeys;
@property (assign, nonatomic) BOOL channelCategoryAnimationInProgress;
@property (assign, nonatomic) BOOL channelTableReloadPending;
@property (assign, nonatomic) BOOL channelTableRestorePending;
@property (strong, nonatomic) DCGuild *displayChannelsGuild;
@property DCChannel *optionChannel;
@property (strong, nonatomic) DCGuild *optionGuild;
@property (assign, nonatomic) BOOL shouldAttemptColdChatRestore;
@property (assign, nonatomic) BOOL coldChatRestoreAlreadyHandled;
@property (strong, nonatomic) NSMutableSet *folderIconHydrationRequests;
@property (assign, nonatomic) BOOL guildFolderAnimationInProgress;
@property (assign, nonatomic) BOOL guildTableReloadPending;
@property (strong, nonatomic) NSMutableDictionary *channelListStatesByGuildKey;
@property (strong, nonatomic) NSMutableSet *pendingMessageAckChannelIDs;
@property (assign, nonatomic) BOOL pendingMessageAckFullReload;
@property (assign, nonatomic) BOOL messageAckRefreshScheduled;
@property (strong, nonatomic) NSMutableIndexSet *mentionedGuildRows;
@property (strong, nonatomic) DCUnreadEdgeIndicatorView *topUnreadIndicator;
@property (strong, nonatomic) DCUnreadEdgeIndicatorView *bottomUnreadIndicator;
@property (strong, nonatomic) DCUnreadEdgeIndicatorView *topChannelUnreadIndicator;
@property (strong, nonatomic) DCUnreadEdgeIndicatorView *bottomChannelUnreadIndicator;
@property (strong, nonatomic) DCUnreadEdgeOverlayView *channelUnreadOverlay;
@property (assign, nonatomic) CGFloat topChannelUnreadIndicatorClearance;
@property (assign, nonatomic) BOOL topChannelUnreadIndicatorTracksHeader;
@property (strong, nonatomic) NSArray *mentionedChannelIndexPaths;
@property (strong, nonatomic) DCChannel *pendingChannelMentionReveal;
@property (assign, nonatomic) CGFloat pendingChannelMentionRevealOffset;
@property (assign, nonatomic) BOOL channelMentionRevealScrollInProgress;
@property (strong, nonatomic) id pendingMentionRevealItem;
@property (assign, nonatomic) BOOL mentionRevealScrollInProgress;
@property (assign, nonatomic) CGFloat pendingMentionRevealOffset;
@end

static const NSInteger DCGuildMentionRevealHighlightTag = 9480;
static const NSInteger DCChannelMentionRevealHighlightTag = 9481;
static const CGFloat DCGuildUnreadEdgeClearance = 35.0f;
static const CGFloat DCGuildMentionBadgeCenterFromBottom = 11.0f;

@implementation DCMenuViewController

- (BOOL)isDirectMessagesGuild:(DCGuild *)guild {
    return guild && guild.snowflake == nil &&
           [guild.name isEqualToString:@"Direct Messages"];
}

- (DCUser *)directMessageBuddyForChannel:(DCChannel *)channel {
    if (!channel || channel.type != DCChannelTypeDM) return nil;

    DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
    NSString *currentUserID = communicator.snowflake;
    DCUser *buddy = nil;

    // recipientIDs survive cold caches even when the object relationship has
    // not been relinked yet. Prefer them so a visible DM can repair itself as
    // soon as the canonical user registry is hydrated.
    for (NSString *recipientID in channel.recipientIDs) {
        if (![recipientID isKindOfClass:[NSString class]] || recipientID.length == 0)
            continue;
        if (currentUserID.length && [recipientID isEqualToString:currentUserID])
            continue;
        buddy = [communicator userForSnowflake:recipientID];
        if (buddy) break;
    }

    if (!buddy) {
        for (DCUser *recipient in channel.recipients) {
            if (![recipient isKindOfClass:[DCUser class]]) continue;
            if (currentUserID.length &&
                [recipient.snowflake isEqualToString:currentUserID]) {
                continue;
            }
            DCUser *canonical = [communicator userForSnowflake:recipient.snowflake];
            buddy = canonical ? canonical : recipient;
            break;
        }
    }

    if (!buddy) {
        for (DCUser *candidate in channel.users) {
            if (![candidate isKindOfClass:[DCUser class]]) continue;
            if (currentUserID.length &&
                [candidate.snowflake isEqualToString:currentUserID]) {
                continue;
            }
            DCUser *canonical = [communicator userForSnowflake:candidate.snowflake];
            buddy = canonical ? canonical : candidate;
            break;
        }
    }

    if (!buddy) return nil;

    // Keep the channel relationship pointed at the canonical DCUser. This is
    // especially useful after cached channels are painted before user-cache
    // hydration has completed.
    if (channel.recipients.count != 1 ||
        [channel.recipients objectAtIndex:0] != buddy) {
        channel.recipients = [NSMutableArray arrayWithObject:buddy];

        NSMutableArray *users = [NSMutableArray arrayWithObject:buddy];
        DCUser *currentUser = currentUserID.length
            ? [communicator userForSnowflake:currentUserID] : nil;
        if (currentUser) [users addObject:currentUser];
        channel.users = users;
    }

    return buddy;
}

- (UIImage *)fallbackAvatarForDMUser:(DCUser *)user channel:(DCChannel *)channel {
    if (user && user.snowflake.length) {
        NSUInteger selector = 0;
        if (user.discriminator == 0) {
            selector = (NSUInteger)(([user.snowflake longLongValue] >> 22) % 6);
        } else {
            selector = (NSUInteger)(user.discriminator % 5);
        }
        NSArray *defaults = [DCUser defaultAvatars];
        if (selector < defaults.count) {
            UIImage *fallback = [DCContentManager
                processedIcon:[defaults objectAtIndex:selector]
                    context:DCAssetContextList];
            if (fallback) return fallback;
        }
    }

    if ([channel.icon isKindOfClass:[UIImage class]]) return channel.icon;
    return nil;
}

- (NSString *)channelListStateKeyForGuild:(DCGuild *)guild {
    if (!guild) return nil;
    if ([self isDirectMessagesGuild:guild]) return @"__direct_messages__";
    return guild.snowflake;
}

- (NSArray *)orderedChannelsForGuild:(DCGuild *)guild {
    NSArray *channels = guild ? [guild channelsSnapshot] : [NSArray array];
    if (![self isDirectMessagesGuild:guild] || channels.count < 2) return channels;

    return [channels sortedArrayUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
        NSString *idA = [a.lastMessageId isKindOfClass:[NSString class]] ? a.lastMessageId : @"0";
        NSString *idB = [b.lastMessageId isKindOfClass:[NSString class]] ? b.lastMessageId : @"0";
        return [idB localizedStandardCompare:idA];
    }];
}

- (BOOL)displayedChannelsMatch:(NSArray *)channels {
    if (self.displayChannels.count != channels.count) return NO;
    for (NSUInteger i = 0; i < channels.count; i++) {
        if ([self.displayChannels objectAtIndex:i] != [channels objectAtIndex:i]) return NO;
    }
    return YES;
}

- (NSString *)categoryKeyForChannel:(DCChannel *)category {
    if (!category.snowflake.length || !self.selectedGuild.snowflake.length) return nil;
    return [NSString stringWithFormat:@"%@:%@", self.selectedGuild.snowflake,
                                      category.snowflake];
}

- (BOOL)isChannelCategoryCollapsed:(DCChannel *)category {
    NSString *key = [self categoryKeyForChannel:category];
    return key.length && [self.collapsedChannelCategoryKeys containsObject:key];
}

- (BOOL)channelRemainsVisibleWhenCollapsed:(DCChannel *)channel {
    return channel.mentionCount > 0 || (channel.unread && !channel.muted);
}

- (NSArray *)sectionsForChannels:(NSArray *)channels {
    if ([self isDirectMessagesGuild:self.selectedGuild]) {
        return [NSArray arrayWithObject:
            [NSDictionary dictionaryWithObjectsAndKeys:channels, @"rows",
             [NSNull null], @"category", nil]];
    }

    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *uncategorized = [NSMutableArray array];
    NSMutableDictionary *rowsByCategory = [NSMutableDictionary dictionary];
    NSMutableArray *categories = [NSMutableArray array];

    for (DCChannel *channel in channels) {
        if (channel.type != DCChannelTypeGuildCategory) continue;
        if (!channel.snowflake.length) continue;
        [categories addObject:channel];
        [rowsByCategory setObject:[NSMutableArray array] forKey:channel.snowflake];
    }

    for (DCChannel *channel in channels) {
        if (channel.type == DCChannelTypeGuildCategory) continue;
        NSMutableArray *parentRows = [channel.parentID isKindOfClass:[NSString class]]
            ? [rowsByCategory objectForKey:channel.parentID] : nil;
        if (parentRows) [parentRows addObject:channel];
        else [uncategorized addObject:channel];
    }

    [sections addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                         [NSArray arrayWithArray:uncategorized], @"rows",
                         [NSNull null], @"category", nil]];
    for (DCChannel *category in categories) {
        NSArray *allRows = [rowsByCategory objectForKey:category.snowflake];
        NSMutableArray *visibleRows = [NSMutableArray arrayWithCapacity:allRows.count];
        BOOL collapsed = [self isChannelCategoryCollapsed:category];
        for (DCChannel *channel in allRows) {
            if (!collapsed || [self channelRemainsVisibleWhenCollapsed:channel])
                [visibleRows addObject:channel];
        }
        [sections addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                             [NSArray arrayWithArray:visibleRows], @"rows",
                             category, @"category", nil]];
    }
    return sections;
}

- (NSArray *)channelsInDisplayedSection:(NSInteger)section {
    if (section < 0 || (NSUInteger)section >= self.displayChannelSections.count)
        return [NSArray array];
    return [[self.displayChannelSections objectAtIndex:section] objectForKey:@"rows"];
}

- (DCChannel *)categoryInDisplayedSection:(NSInteger)section {
    if (section < 0 || (NSUInteger)section >= self.displayChannelSections.count)
        return nil;
    id category = [[self.displayChannelSections objectAtIndex:section] objectForKey:@"category"];
    return [category isKindOfClass:[DCChannel class]] ? category : nil;
}

- (BOOL)displayedChannelSectionsMatch:(NSArray *)sections {
    if (self.displayChannelSections.count != sections.count) return NO;
    for (NSUInteger section = 0; section < sections.count; section++) {
        NSDictionary *oldSection = [self.displayChannelSections objectAtIndex:section];
        NSDictionary *newSection = [sections objectAtIndex:section];
        if ([oldSection objectForKey:@"category"] != [newSection objectForKey:@"category"])
            return NO;
        NSArray *oldRows = [oldSection objectForKey:@"rows"];
        NSArray *newRows = [newSection objectForKey:@"rows"];
        if (oldRows.count != newRows.count) return NO;
        for (NSUInteger i = 0; i < oldRows.count; i++) {
            if ([oldRows objectAtIndex:i] != [newRows objectAtIndex:i]) return NO;
        }
    }
    return YES;
}

- (void)reloadChannelTable {
    assertMainThread();
    if (self.channelCategoryAnimationInProgress) {
        self.channelTableReloadPending = YES;
        return;
    }
    self.displayChannelsGuild = self.selectedGuild;
    self.displayChannels = [self orderedChannelsForGuild:self.selectedGuild];
    self.displayChannelSections = [self sectionsForChannels:self.displayChannels];
    self.pendingChannelMentionReveal = nil;
    self.channelMentionRevealScrollInProgress = NO;
    [self.channelTableView reloadData];
    [self rebuildMentionedChannelIndexPaths];
}

- (DCChannel *)displayedChannelAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.row < 0) return nil;
    NSArray *rows = [self channelsInDisplayedSection:indexPath.section];
    return (NSUInteger)indexPath.row < rows.count ? [rows objectAtIndex:indexPath.row] : nil;
}

- (NSIndexPath *)indexPathForDisplayedChannelID:(NSString *)channelID {
    if (!channelID.length) return nil;
    for (NSUInteger section = 0; section < self.displayChannelSections.count; section++) {
        NSArray *rows = [self channelsInDisplayedSection:section];
        for (NSUInteger row = 0; row < rows.count; row++) {
            DCChannel *channel = [rows objectAtIndex:row];
            if ([channel.snowflake isEqualToString:channelID])
                return [NSIndexPath indexPathForRow:row inSection:section];
        }
    }
    return nil;
}

- (void)finishChannelCategoryAnimation {
    assertMainThread();
    self.channelCategoryAnimationInProgress = NO;

    if (self.channelTableReloadPending) {
        BOOL restoreScroll = self.channelTableRestorePending;
        self.channelTableReloadPending = NO;
        self.channelTableRestorePending = NO;
        if (restoreScroll) [self reloadChannelTableForSelectedGuildRestoringScroll];
        else [self reloadChannelTable];
    } else {
        [self rebuildMentionedChannelIndexPaths];
    }

    if (self.messageAckRefreshScheduled) [self flushMessageAckUpdates];
}

- (void)didTapChannelCategoryHeader:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded ||
        self.channelCategoryAnimationInProgress) return;
    DCChannelCategoryHeaderView *header = (DCChannelCategoryHeaderView *)recognizer.view;
    if (![header isKindOfClass:[DCChannelCategoryHeaderView class]]) return;
    DCChannel *category = [self categoryInDisplayedSection:header.section];
    if (!category || ![category.snowflake isEqualToString:header.categoryID]) return;

    NSString *key = [self categoryKeyForChannel:category];
    if (!key.length) return;
    NSArray *oldRows = [self channelsInDisplayedSection:header.section];
    if ([self.channelTableView numberOfSections] != (NSInteger)self.displayChannelSections.count ||
        [self.channelTableView numberOfRowsInSection:header.section] != (NSInteger)oldRows.count) {
        [self reloadChannelTable];
        return;
    }
    if (!self.collapsedChannelCategoryKeys)
        self.collapsedChannelCategoryKeys = [NSMutableSet set];
    BOOL collapsing = ![self.collapsedChannelCategoryKeys containsObject:key];
    if (collapsing) [self.collapsedChannelCategoryKeys addObject:key];
    else [self.collapsedChannelCategoryKeys removeObject:key];

    NSArray *updatedSections = [self sectionsForChannels:self.displayChannels];
    if (updatedSections.count != self.displayChannelSections.count) {
        [self reloadChannelTable];
        return;
    }
    NSArray *newRows = [[updatedSections objectAtIndex:header.section] objectForKey:@"rows"];
    NSMutableArray *deletedPaths = [NSMutableArray array];
    NSMutableArray *insertedPaths = [NSMutableArray array];
    for (NSUInteger row = 0; row < oldRows.count; row++) {
        if ([newRows containsObject:[oldRows objectAtIndex:row]]) continue;
        [deletedPaths addObject:[NSIndexPath indexPathForRow:row inSection:header.section]];
    }
    for (NSUInteger row = 0; row < newRows.count; row++) {
        if ([oldRows containsObject:[newRows objectAtIndex:row]]) continue;
        [insertedPaths addObject:[NSIndexPath indexPathForRow:row inSection:header.section]];
    }

    self.pendingChannelMentionReveal = nil;
    self.channelMentionRevealScrollInProgress = NO;
    header.collapsed = collapsing;
    if (!deletedPaths.count && !insertedPaths.count) {
        self.displayChannelSections = updatedSections;
        [self rebuildMentionedChannelIndexPaths];
        return;
    }

    self.channelCategoryAnimationInProgress = YES;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [self finishChannelCategoryAnimation];
    }];
    [self.channelTableView beginUpdates];
    self.displayChannelSections = updatedSections;
    if (deletedPaths.count) {
        [self.channelTableView deleteRowsAtIndexPaths:deletedPaths
                                    withRowAnimation:UITableViewRowAnimationTop];
    }
    if (insertedPaths.count) {
        [self.channelTableView insertRowsAtIndexPaths:insertedPaths
                                    withRowAnimation:UITableViewRowAnimationTop];
    }
    [self.channelTableView endUpdates];
    [CATransaction commit];
}

- (BOOL)channelIDsIncludeDisplayedCategory:(NSSet *)channelIDs {
    for (NSDictionary *section in self.displayChannelSections) {
        id category = [section objectForKey:@"category"];
        if ([category isKindOfClass:[DCChannel class]] &&
            [channelIDs containsObject:((DCChannel *)category).snowflake]) return YES;
    }
    return NO;
}

- (void)saveChannelListStateForGuild:(DCGuild *)guild {
    if (!guild || !self.channelTableView) return;

    NSString *key = [self channelListStateKeyForGuild:guild];
    if (key.length == 0) return;

    if (!self.channelListStatesByGuildKey) {
        self.channelListStatesByGuildKey = [NSMutableDictionary dictionary];
    }

    CGFloat minOffsetY = -self.channelTableView.contentInset.top;
    CGFloat currentOffsetY = self.channelTableView.contentOffset.y;
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    [state setObject:[NSNumber numberWithFloat:currentOffsetY] forKey:@"offsetY"];

    if (currentOffsetY <= minOffsetY + 0.5f) {
        [state setObject:[NSNumber numberWithBool:YES] forKey:@"atTop"];
        [self.channelListStatesByGuildKey setObject:state forKey:key];
        return;
    }

    NSArray *visibleRows = [self.channelTableView indexPathsForVisibleRows];
    NSIndexPath *topIndexPath = nil;
    for (NSIndexPath *indexPath in visibleRows) {
        if (!topIndexPath || [indexPath compare:topIndexPath] == NSOrderedAscending)
            topIndexPath = indexPath;
    }

    if (topIndexPath) {
        DCChannel *channel = [self displayedChannelAtIndexPath:topIndexPath];
        if (channel.snowflake.length > 0) {
            CGRect rowRect = [self.channelTableView rectForRowAtIndexPath:topIndexPath];
            CGFloat relativeOffset = currentOffsetY - rowRect.origin.y;
            [state setObject:channel.snowflake forKey:@"channelID"];
            [state setObject:[NSNumber numberWithFloat:relativeOffset]
                      forKey:@"relativeOffset"];
        }
    }

    [self.channelListStatesByGuildKey setObject:state forKey:key];
}

- (CGFloat)clampedChannelListOffsetY:(CGFloat)offsetY {
    CGFloat minOffsetY = -self.channelTableView.contentInset.top;
    CGFloat maxOffsetY = self.channelTableView.contentSize.height -
                         self.channelTableView.bounds.size.height +
                         self.channelTableView.contentInset.bottom;
    if (maxOffsetY < minOffsetY) maxOffsetY = minOffsetY;
    return MIN(MAX(offsetY, minOffsetY), maxOffsetY);
}

- (void)restoreChannelListStateForGuild:(DCGuild *)guild {
    if (!guild || !self.channelTableView) return;

    NSString *key = [self channelListStateKeyForGuild:guild];
    NSDictionary *state = key.length ? [self.channelListStatesByGuildKey objectForKey:key] : nil;

    [self.channelTableView layoutIfNeeded];

    CGFloat targetOffsetY = -self.channelTableView.contentInset.top;
    if (state) {
        if ([[state objectForKey:@"atTop"] boolValue]) {
            targetOffsetY = -self.channelTableView.contentInset.top;
        } else {
            NSString *channelID = [state objectForKey:@"channelID"];
            NSNumber *relativeOffset = [state objectForKey:@"relativeOffset"];
            NSIndexPath *indexPath = [self indexPathForDisplayedChannelID:channelID];
            if (indexPath) {
                CGRect rowRect = [self.channelTableView rectForRowAtIndexPath:indexPath];
                targetOffsetY = rowRect.origin.y + [relativeOffset floatValue];
            } else {
                targetOffsetY = [[state objectForKey:@"offsetY"] floatValue];
            }
        }
    }

    targetOffsetY = [self clampedChannelListOffsetY:targetOffsetY];
    [self.channelTableView setContentOffset:CGPointMake(0.0f, targetOffsetY) animated:NO];
}

- (BOOL)selectGuildForChannelList:(DCGuild *)guild {
    NSString *oldKey = [self channelListStateKeyForGuild:self.selectedGuild];
    NSString *newKey = [self channelListStateKeyForGuild:guild];
    BOOL changed = (oldKey || newKey) && ![oldKey isEqualToString:newKey];

    if (changed) {
        [self saveChannelListStateForGuild:self.selectedGuild];
    }
    self.selectedGuild = guild;
    return changed;
}

- (void)reloadChannelTableForSelectedGuildRestoringScroll {
    if (self.channelCategoryAnimationInProgress) {
        self.channelTableReloadPending = YES;
        self.channelTableRestorePending = YES;
        return;
    }
    [self reloadChannelTable];
    [self restoreChannelListStateForGuild:self.selectedGuild];
}

- (void)activateSelectedChannelInExperimentalMode {
    if (!self.experimentalMode) return;

    UIViewController *contentController =
        self.slideMenuController.contentViewController;
    DCChatViewController *chatViewController = nil;

    if ([contentController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController =
            (UINavigationController *)contentController;
        UIViewController *rootController =
            navigationController.viewControllers.count > 0
                ? [navigationController.viewControllers objectAtIndex:0]
                : nil;
        if ([rootController isKindOfClass:[DCChatViewController class]]) {
            chatViewController = (DCChatViewController *)rootController;
        }
    } else if ([contentController isKindOfClass:[DCChatViewController class]]) {
        chatViewController = (DCChatViewController *)contentController;
    }

    if (!chatViewController) {
        DBGLOG(@"[Experimental] Chat content controller is not available yet");
        return;
    }

    [chatViewController activateSelectedChannel];
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"GuildMemberListUpdated"
                      object:nil];
    [self.slideMenuController hideMenu:YES];
}

- (BOOL)activateSelectedChannelInIPadSplitView {
    if ([[UIDevice currentDevice] userInterfaceIdiom] != UIUserInterfaceIdiomPad ||
        self.experimentalMode) {
        return NO;
    }

    UISplitViewController *splitViewController = self.splitViewController;
    if (splitViewController.viewControllers.count < 2) {
        return NO;
    }

    UIViewController *detailController =
        [splitViewController.viewControllers objectAtIndex:1];
    UINavigationController *detailNavigationController = nil;
    DCChatViewController *chatViewController = nil;

    if ([detailController isKindOfClass:[UINavigationController class]]) {
        detailNavigationController = (UINavigationController *)detailController;
        UIViewController *rootController =
            detailNavigationController.viewControllers.count > 0
                ? [detailNavigationController.viewControllers objectAtIndex:0]
                : nil;
        if ([rootController isKindOfClass:[DCChatViewController class]]) {
            chatViewController = (DCChatViewController *)rootController;
        }
    } else if ([detailController isKindOfClass:[DCChatViewController class]]) {
        chatViewController = (DCChatViewController *)detailController;
    }

    if (!chatViewController) {
        return NO;
    }

    if (detailNavigationController &&
        detailNavigationController.topViewController != chatViewController) {
        [detailNavigationController popToRootViewControllerAnimated:NO];
    }

    chatViewController.navigationItem.title =
        self.selectedChannel.name ?: @"Chat";
    [chatViewController activateSelectedChannel];
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"GuildMemberListUpdated"
                      object:nil];

    if ([splitViewController isKindOfClass:[DCIPadSplitViewController class]]) {
        DCIPadSplitViewController *iPadSplitViewController =
            (DCIPadSplitViewController *)splitViewController;
        if ([iPadSplitViewController isPortraitSidebarVisible]) {
            [iPadSplitViewController hidePortraitSidebarAnimated:YES];
        }
    }
    return YES;
}

- (void)rebuildDisplayGuildsIfNeeded {
    assertMainThread();

    DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
    if (!communicator.guilds) {
        self.displayGuilds = [NSMutableArray array];
        return;
    }
    if (communicator.guildsIsSorted && self.displayGuilds) {
        return;
    }

    NSMutableArray *cached = communicator.cachedDisplayLayout;
    if (cached.count) {
        self.displayGuilds = cached;
        communicator.cachedDisplayLayout = nil;
        communicator.guildsIsSorted = YES;
        return;
    }

    NSArray *guildPositions = communicator.currentUserInfo.guildPositions ?: @[];
    NSArray *guildFolders = communicator.currentUserInfo.guildFolders ?: @[];
    NSUInteger guildCount = guildPositions.count + 1;
    NSMutableArray *sortedGuilds = [NSMutableArray arrayWithCapacity:guildCount];
    NSNull *nullObject = [NSNull null];
    for (NSUInteger i = 0; i < guildCount; i++) {
        [sortedGuilds addObject:nullObject];
    }

    for (DCGuild *guild in communicator.guilds) {
        NSUInteger index = [guildPositions indexOfObject:guild.snowflake];
        if (index != NSNotFound) {
            [sortedGuilds insertObject:guild atIndex:index + 1];
        } else if ([[sortedGuilds objectAtIndex:0] isEqual:nullObject]) {
            [sortedGuilds insertObject:guild atIndex:0];
        } else {
            [sortedGuilds addObject:guild];
        }
    }
    [sortedGuilds removeObjectIdenticalTo:nullObject];
    if (sortedGuilds.count == 0) {
        self.displayGuilds = [NSMutableArray array];
        communicator.guildsIsSorted = YES;
        return;
    }

    communicator.guilds = sortedGuilds;
    sortedGuilds = [NSMutableArray arrayWithObject:[communicator.guilds objectAtIndex:0]];
    NSMutableSet *handledGuildIds = [NSMutableSet set];

    for (DCGuildFolder *folder in guildFolders) {
        if (folder.id) {
            [sortedGuilds addObject:folder];
        }
        if (folder.opened) {
            NSArray *folderGuilds = [[communicator.guilds
                filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCGuild *guild, NSDictionary *bindings) {
                    return [folder.guildIds containsObject:guild.snowflake];
                }]]
                sortedArrayUsingComparator:^NSComparisonResult(DCGuild *a, DCGuild *b) {
                    NSUInteger index1 = [folder.guildIds indexOfObject:a.snowflake];
                    NSUInteger index2 = [folder.guildIds indexOfObject:b.snowflake];
                    if (index1 < index2) return NSOrderedAscending;
                    if (index1 > index2) return NSOrderedDescending;
                    return NSOrderedSame;
                }];
            [sortedGuilds addObjectsFromArray:folderGuilds];
        }
        [handledGuildIds addObjectsFromArray:folder.guildIds];
    }

    NSMutableArray *origCopy = [[[communicator.guilds reverseObjectEnumerator] allObjects] mutableCopy];
    [origCopy filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        if (![evaluatedObject isKindOfClass:[DCGuild class]]) return NO;
        DCGuild *guild = (DCGuild *)evaluatedObject;
        return guild.snowflake && ![handledGuildIds containsObject:guild.snowflake];
    }]];
    if (origCopy.count > 0) {
        NSRange range = NSMakeRange(1, origCopy.count);
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:range];
        [sortedGuilds insertObjects:origCopy atIndexes:indexSet];
    }

    self.displayGuilds = sortedGuilds;
    communicator.guildsIsSorted = YES;
}

- (BOOL)displayedGuildItemHasMentions:(id)item {
    if ([item isKindOfClass:[DCGuild class]])
        return ((DCGuild *)item).mentionCount > 0;
    if (![item isKindOfClass:[DCGuildFolder class]]) return NO;

    DCGuildFolder *folder = (DCGuildFolder *)item;
    if (folder.opened) return NO;
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        if (guild.snowflake.length &&
            [folder.guildIds containsObject:guild.snowflake] &&
            guild.mentionCount > 0) return YES;
    }
    return NO;
}

- (NSInteger)mentionCountForFolder:(DCGuildFolder *)folder {
    NSInteger total = 0;
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        if (guild.snowflake.length && [folder.guildIds containsObject:guild.snowflake])
            total += guild.mentionCount;
    }
    return total;
}

- (void)refreshMentionedGuildRow:(NSUInteger)row {
    if (row >= self.displayGuilds.count) return;
    if (!self.mentionedGuildRows) self.mentionedGuildRows = [NSMutableIndexSet indexSet];
    if ([self displayedGuildItemHasMentions:[self.displayGuilds objectAtIndex:row]])
        [self.mentionedGuildRows addIndex:row];
    else
        [self.mentionedGuildRows removeIndex:row];
}

- (void)rebuildMentionedGuildRows {
    if (!self.mentionedGuildRows) self.mentionedGuildRows = [NSMutableIndexSet indexSet];
    [self.mentionedGuildRows removeAllIndexes];
    for (NSUInteger row = 0; row < self.displayGuilds.count; row++)
        [self refreshMentionedGuildRow:row];
    [self updateUnreadEdgeIndicators];
}

- (void)rebuildMentionedChannelIndexPaths {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSUInteger section = 0; section < self.displayChannelSections.count; section++) {
        NSArray *rows = [self channelsInDisplayedSection:section];
        for (NSUInteger row = 0; row < rows.count; row++) {
            DCChannel *channel = [rows objectAtIndex:row];
            if (channel.mentionCount > 0)
                [paths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
        }
    }
    self.mentionedChannelIndexPaths = paths;
    [self updateChannelUnreadEdgeIndicators];
}

- (void)refreshMentionedChannelIndexPathsForIDs:(NSSet *)channelIDs {
    if (!channelIDs.count) return;
    NSMutableSet *paths = [NSMutableSet setWithArray:self.mentionedChannelIndexPaths ?: @[]];
    for (NSString *channelID in channelIDs) {
        NSIndexPath *path = [self indexPathForDisplayedChannelID:channelID];
        if (!path) continue;
        DCChannel *channel = [self displayedChannelAtIndexPath:path];
        if (channel.mentionCount > 0) [paths addObject:path];
        else [paths removeObject:path];
    }
    self.mentionedChannelIndexPaths = [[paths allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [self updateChannelUnreadEdgeIndicators];
}

- (CGFloat)channelPinnedHeaderClearanceAtOffset:(CGFloat)offsetY
                                  protectedHeight:(CGFloat)protectedHeight {
    UITableView *table = self.channelTableView;
    if (!table || [self isDirectMessagesGuild:self.selectedGuild]) return 0.0f;
    NSInteger sectionCount = (NSInteger)self.displayChannelSections.count;
    if ([table numberOfSections] != sectionCount) return 0.0f;

    CGFloat visibleTop = offsetY + table.contentInset.top;
    CGFloat stripBottom = visibleTop + protectedHeight;
    NSInteger first = 0;
    NSInteger end = sectionCount;
    while (first < end) {
        NSInteger mid = first + (end - first) / 2;
        if (CGRectGetMaxY([table rectForSection:mid]) <= visibleTop)
            first = mid + 1;
        else
            end = mid;
    }

    CGFloat clearance = 0.0f;
    for (NSInteger section = first; section < sectionCount; section++) {
        CGRect sectionRect = [table rectForSection:section];
        if (CGRectGetMinY(sectionRect) >= stripBottom) break;
        if (![self categoryInDisplayedSection:section]) continue;

        CGRect headerRect = [table rectForHeaderInSection:section];
        CGFloat height = CGRectGetHeight(headerRect);
        if (height <= 0.0f) continue;

        CGFloat headerY = MIN(MAX(CGRectGetMinY(headerRect), visibleTop),
                              CGRectGetMaxY(sectionRect) - height);
        if (headerY < stripBottom && headerY + height > visibleTop)
            clearance = MAX(clearance, headerY + height - visibleTop);
    }
    return MAX(0.0f, ceilf(clearance));
}

- (CGFloat)channelPinnedHeaderClearanceAtOffset:(CGFloat)offsetY {
    return [self channelPinnedHeaderClearanceAtOffset:offsetY
                                      protectedHeight:DCGuildUnreadEdgeClearance];
}

- (void)layoutChannelUnreadEdgeIndicators {
    UITableView *table = self.channelTableView;
    UIView *container = table.superview;
    if (!container) return;

    if (!self.channelUnreadOverlay) {
        DCUnreadEdgeOverlayView *overlay = [[DCUnreadEdgeOverlayView alloc] initWithFrame:CGRectZero];
        overlay.backgroundColor = [UIColor clearColor];
        overlay.clipsToBounds = YES;
        self.channelUnreadOverlay = overlay;
    }
    if (self.channelUnreadOverlay.superview != container) {
        [container insertSubview:self.channelUnreadOverlay aboveSubview:table];
        if (self.guildTotalView.superview == container)
            [container bringSubviewToFront:self.guildTotalView];
        if (self.totalView.superview == container)
            [container bringSubviewToFront:self.totalView];
    }

    BOOL topDismissing = !self.topChannelUnreadIndicatorTracksHeader &&
        self.topChannelUnreadIndicator && !self.topChannelUnreadIndicator.hidden;
    CGFloat protectedHeight = DCGuildUnreadEdgeClearance;
    if (topDismissing) {
        protectedHeight += self.topChannelUnreadIndicatorClearance +
                           [DCUnreadEdgeIndicatorView animationOverflow];
    }
    CGFloat topClearance = [self channelPinnedHeaderClearanceAtOffset:table.contentOffset.y
                                                      protectedHeight:protectedHeight];
    if (self.topChannelUnreadIndicatorTracksHeader) {
        self.topChannelUnreadIndicatorClearance = topClearance;
    } else if (topDismissing) {
        topClearance = MAX(topClearance, self.topChannelUnreadIndicatorClearance);
    }
    CGRect frame = table.frame;
    CGRect overlayFrame = CGRectMake(frame.origin.x, frame.origin.y + topClearance,
        frame.size.width, MAX(0.0f, frame.size.height - topClearance));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!CGRectEqualToRect(self.channelUnreadOverlay.frame, overlayFrame))
        self.channelUnreadOverlay.frame = overlayFrame;

    if (!self.topChannelUnreadIndicator) {
        self.topChannelUnreadIndicator = [[DCUnreadEdgeIndicatorView alloc]
            initWithEdge:DCUnreadEdgeTop title:@"New Mentions" horizontalTextInset:15.0f];
        self.topChannelUnreadIndicator.gradientPeakOpacity = 0.45f;
        [self.topChannelUnreadIndicator addTarget:self action:@selector(tapTopChannelUnreadIndicator:)];
    }
    if (!self.bottomChannelUnreadIndicator) {
        self.bottomChannelUnreadIndicator = [[DCUnreadEdgeIndicatorView alloc]
            initWithEdge:DCUnreadEdgeBottom title:@"New Mentions" horizontalTextInset:15.0f];
        self.bottomChannelUnreadIndicator.gradientPeakOpacity = 0.45f;
        [self.bottomChannelUnreadIndicator addTarget:self action:@selector(tapBottomChannelUnreadIndicator:)];
    }
    if (self.topChannelUnreadIndicator.superview != self.channelUnreadOverlay)
        [self.channelUnreadOverlay addSubview:self.topChannelUnreadIndicator];
    if (self.bottomChannelUnreadIndicator.superview != self.channelUnreadOverlay)
        [self.channelUnreadOverlay addSubview:self.bottomChannelUnreadIndicator];

    CGFloat overflow = [DCUnreadEdgeIndicatorView animationOverflow];
    CGFloat height = DCGuildUnreadEdgeClearance + 2.0f * overflow;
    CGFloat width = self.channelUnreadOverlay.bounds.size.width;
    CGFloat listHeight = self.channelUnreadOverlay.bounds.size.height;
    CGRect topFrame = CGRectMake(0.0f,
        self.topChannelUnreadIndicatorClearance - topClearance - overflow, width, height);
    CGRect bottomFrame = CGRectMake(0.0f,
        listHeight - DCGuildUnreadEdgeClearance - overflow, width, height);
    if (!CGRectEqualToRect(self.topChannelUnreadIndicator.frame, topFrame))
        self.topChannelUnreadIndicator.frame = topFrame;
    if (!CGRectEqualToRect(self.bottomChannelUnreadIndicator.frame, bottomFrame))
        self.bottomChannelUnreadIndicator.frame = bottomFrame;
    [CATransaction commit];

    if (!self.mentionedChannelIndexPaths.count ||
        [table numberOfSections] != (NSInteger)self.displayChannelSections.count) {
        [self.topChannelUnreadIndicator setGradientOcclusionRanges:nil];
        [self.bottomChannelUnreadIndicator setGradientOcclusionRanges:nil];
        return;
    }

    NSMutableArray *topOcclusions = [NSMutableArray array];
    NSMutableArray *bottomOcclusions = [NSMutableArray array];
    CGFloat visibleTop = table.contentOffset.y + table.contentInset.top;
    CGFloat visibleBottom = table.contentOffset.y + table.bounds.size.height -
                            table.contentInset.bottom;
    CGFloat stripBottom = MAX(0.0f, listHeight - DCGuildUnreadEdgeClearance);
    NSInteger first = 0;
    NSInteger end = (NSInteger)self.displayChannelSections.count;
    while (first < end) {
        NSInteger mid = first + (end - first) / 2;
        if (CGRectGetMaxY([table rectForSection:mid]) <= visibleTop)
            first = mid + 1;
        else
            end = mid;
    }
    for (NSInteger section = first;
         section < (NSInteger)self.displayChannelSections.count; section++) {
        CGRect sectionRect = [table rectForSection:section];
        if (CGRectGetMinY(sectionRect) >= visibleBottom) break;
        if (![self categoryInDisplayedSection:section]) continue;

        CGRect headerRect = [table rectForHeaderInSection:section];
        CGFloat headerHeight = CGRectGetHeight(headerRect);
        if (headerHeight <= 0.0f) continue;
        CGFloat headerY = MIN(MAX(CGRectGetMinY(headerRect), visibleTop),
                              CGRectGetMaxY(sectionRect) - headerHeight);
        CGFloat overlayY = headerY - table.contentOffset.y - topClearance;
        CGFloat topIndicatorY = overlayY + topClearance -
                                self.topChannelUnreadIndicatorClearance;
        CGFloat topStart = MAX(0.0f, topIndicatorY);
        CGFloat topEnd = MIN(DCGuildUnreadEdgeClearance, topIndicatorY + headerHeight);
        if (topEnd > topStart)
            [topOcclusions addObject:[NSValue valueWithCGRect:
                CGRectMake(0.0f, topStart, 1.0f, topEnd - topStart)]];

        CGFloat bottomStart = MAX(stripBottom, overlayY);
        CGFloat bottomEnd = MIN(listHeight, overlayY + headerHeight);
        if (bottomEnd > bottomStart)
            [bottomOcclusions addObject:[NSValue valueWithCGRect:
                CGRectMake(0.0f, bottomStart - stripBottom,
                           1.0f, bottomEnd - bottomStart)]];
    }
    [self.topChannelUnreadIndicator setGradientOcclusionRanges:topOcclusions];
    [self.bottomChannelUnreadIndicator setGradientOcclusionRanges:bottomOcclusions];
}

- (NSIndexPath *)nearestChannelMentionAtEdge:(DCUnreadEdge)edge {
    UITableView *table = self.channelTableView;
    if (!table || !self.mentionedChannelIndexPaths.count || !self.displayChannelSections.count ||
        [table numberOfSections] != (NSInteger)self.displayChannelSections.count) return nil;

    CGFloat minimum = -table.contentInset.top;
    CGFloat maximum = MAX(minimum, table.contentSize.height +
                          table.contentInset.bottom - table.bounds.size.height);
    if ((edge == DCUnreadEdgeTop && table.contentOffset.y <= minimum + 0.5f) ||
        (edge == DCUnreadEdgeBottom && table.contentOffset.y >= maximum - 0.5f)) return nil;

    CGFloat top = table.contentOffset.y + table.contentInset.top;
    CGFloat bottom = table.contentOffset.y + table.bounds.size.height - table.contentInset.bottom;
    CGFloat topClearance = DCGuildUnreadEdgeClearance +
        [self channelPinnedHeaderClearanceAtOffset:table.contentOffset.y];
    NSIndexPath *nearest = nil;
    for (NSIndexPath *path in self.mentionedChannelIndexPaths) {
        if (path.section >= self.displayChannelSections.count ||
            path.row >= (NSInteger)[self channelsInDisplayedSection:path.section].count) continue;
        CGRect rect = [table rectForRowAtIndexPath:path];
        CGFloat badgeY = CGRectGetMidY(rect);
        if (edge == DCUnreadEdgeTop) {
            if (badgeY < top + topClearance - 0.5f) nearest = path;
            else break;
        } else if (badgeY > bottom - DCGuildUnreadEdgeClearance + 0.5f) {
            nearest = path;
            break;
        }
    }
    return nearest;
}

- (void)updateChannelUnreadEdgeIndicators {
    if (self.channelCategoryAnimationInProgress ||
        !self.isViewLoaded || !self.view.window || !self.channelTableView) return;
    BOOL showTop = [self nearestChannelMentionAtEdge:DCUnreadEdgeTop] != nil;
    BOOL showBottom = [self nearestChannelMentionAtEdge:DCUnreadEdgeBottom] != nil;
    self.topChannelUnreadIndicatorTracksHeader = showTop;
    [self layoutChannelUnreadEdgeIndicators];
    [self.topChannelUnreadIndicator setActive:showTop animated:YES];
    [self.bottomChannelUnreadIndicator setActive:showBottom animated:YES];
}

- (void)finishPendingChannelMentionReveal {
    DCChannel *channel = self.pendingChannelMentionReveal;
    if (!channel || self.channelMentionRevealScrollInProgress) return;
    NSIndexPath *path = [self indexPathForDisplayedChannelID:channel.snowflake];
    if (!path || [self displayedChannelAtIndexPath:path] != channel) {
        self.pendingChannelMentionReveal = nil;
        return;
    }
    UITableView *table = self.channelTableView;
    CGRect rect = [table rectForRowAtIndexPath:path];
    CGFloat top = table.contentOffset.y + table.contentInset.top;
    CGFloat bottom = table.contentOffset.y + table.bounds.size.height - table.contentInset.bottom;
    if (CGRectGetMaxY(rect) <= top || CGRectGetMinY(rect) >= bottom) return;

    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (!cell) return;
    self.pendingChannelMentionReveal = nil;
    [[cell viewWithTag:DCChannelMentionRevealHighlightTag] removeFromSuperview];
    UIView *highlight = [[UIView alloc] initWithFrame:cell.bounds];
    highlight.tag = DCChannelMentionRevealHighlightTag;
    highlight.userInteractionEnabled = NO;
    highlight.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    highlight.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.13f];
    [cell addSubview:highlight];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!highlight.superview) return;
        [UIView animateWithDuration:0.45f animations:^{ highlight.alpha = 0.0f; }
                         completion:^(BOOL finished) { [highlight removeFromSuperview]; }];
    });
}

- (void)revealChannelMentionAtEdge:(DCUnreadEdge)edge {
    if (self.channelMentionRevealScrollInProgress) return;
    UITableView *table = self.channelTableView;
    [table layoutIfNeeded];
    NSIndexPath *path = [self nearestChannelMentionAtEdge:edge];
    if (!path) return;
    DCChannel *channel = [self displayedChannelAtIndexPath:path];
    if (!channel) return;

    CGRect rect = [table rectForRowAtIndexPath:path];
    UIEdgeInsets insets = table.contentInset;
    if (table.bounds.size.height - insets.top - insets.bottom <=
        DCGuildUnreadEdgeClearance * 2.0f) return;
    CGFloat destination;
    if (edge == DCUnreadEdgeTop) {
        destination = CGRectGetMinY(rect) - insets.top - DCGuildUnreadEdgeClearance;
        CGFloat headerClearance = [self channelPinnedHeaderClearanceAtOffset:destination];
        destination -= headerClearance;
    } else {
        destination = CGRectGetMaxY(rect) - table.bounds.size.height + insets.bottom +
            DCGuildUnreadEdgeClearance;
    }
    destination = [self clampedChannelListOffsetY:destination];
    self.pendingChannelMentionReveal = channel;
    if (fabsf(destination - table.contentOffset.y) <= 0.5f) {
        [self finishPendingChannelMentionReveal];
        return;
    }

    self.pendingChannelMentionRevealOffset = destination;
    self.channelMentionRevealScrollInProgress = YES;
    [table setContentOffset:CGPointMake(table.contentOffset.x, destination) animated:YES];
    __weak DCMenuViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!weakSelf.channelMentionRevealScrollInProgress ||
            weakSelf.pendingChannelMentionReveal != channel) return;
        weakSelf.channelMentionRevealScrollInProgress = NO;
        [weakSelf updateChannelUnreadEdgeIndicators];
        if (fabsf(table.contentOffset.y - weakSelf.pendingChannelMentionRevealOffset) <= 1.0f)
            [weakSelf finishPendingChannelMentionReveal];
        else
            weakSelf.pendingChannelMentionReveal = nil;
    });
}

- (void)tapTopChannelUnreadIndicator:(id)sender {
    [self revealChannelMentionAtEdge:DCUnreadEdgeTop];
}

- (void)tapBottomChannelUnreadIndicator:(id)sender {
    [self revealChannelMentionAtEdge:DCUnreadEdgeBottom];
}

- (void)layoutUnreadEdgeIndicators {
    UITableView *table = self.guildTableView;
    UIView *container = table.superview;
    if (!container) return;

    if (!self.topUnreadIndicator) {
        self.topUnreadIndicator = [[DCUnreadEdgeIndicatorView alloc]
            initWithEdge:DCUnreadEdgeTop];
        [self.topUnreadIndicator addTarget:self action:@selector(tapTopUnreadIndicator:)];
    }
    if (!self.bottomUnreadIndicator) {
        self.bottomUnreadIndicator = [[DCUnreadEdgeIndicatorView alloc]
            initWithEdge:DCUnreadEdgeBottom];
        [self.bottomUnreadIndicator addTarget:self action:@selector(tapBottomUnreadIndicator:)];
    }
    if (self.topUnreadIndicator.superview != container) {
        [container addSubview:self.topUnreadIndicator];
        [container bringSubviewToFront:self.topUnreadIndicator];
    }
    if (self.bottomUnreadIndicator.superview != container) {
        [container addSubview:self.bottomUnreadIndicator];
        [container bringSubviewToFront:self.bottomUnreadIndicator];
    }

    CGRect frame = table.frame;
    CGFloat overflow = [DCUnreadEdgeIndicatorView animationOverflow];
    CGFloat indicatorHeight = 35.0f + overflow * 2.0f;
    CGRect topFrame = CGRectMake(frame.origin.x, frame.origin.y - overflow,
                                 frame.size.width, indicatorHeight);
    CGRect bottomFrame = CGRectMake(frame.origin.x,
        CGRectGetMaxY(frame) - 35.0f - overflow, frame.size.width, indicatorHeight);
    if (!CGRectEqualToRect(self.topUnreadIndicator.frame, topFrame))
        self.topUnreadIndicator.frame = topFrame;
    if (!CGRectEqualToRect(self.bottomUnreadIndicator.frame, bottomFrame))
        self.bottomUnreadIndicator.frame = bottomFrame;
}

- (CGFloat)unreadListVisibleTop {
    UITableView *table = self.guildTableView;
    return table.contentOffset.y + table.contentInset.top;
}

- (CGFloat)unreadListVisibleBottom {
    UITableView *table = self.guildTableView;
    return table.contentOffset.y + table.bounds.size.height - table.contentInset.bottom;
}

- (NSUInteger)nearestOffscreenMentionRowAtEdge:(DCUnreadEdge)edge {
    UITableView *table = self.guildTableView;
    if (!table || self.mentionedGuildRows.count == 0 ||
        self.displayGuilds.count != (NSUInteger)[table numberOfRowsInSection:0])
        return NSNotFound;

    CGFloat minOffset = -table.contentInset.top;
    CGFloat maxOffset = MAX(minOffset, table.contentSize.height +
                                      table.contentInset.bottom - table.bounds.size.height);
    if ((edge == DCUnreadEdgeTop && table.contentOffset.y <= minOffset + 0.5f) ||
        (edge == DCUnreadEdgeBottom && table.contentOffset.y >= maxOffset - 0.5f))
        return NSNotFound;

    NSUInteger firstVisible = NSNotFound;
    NSUInteger lastVisible = NSNotFound;
    for (NSIndexPath *path in [table indexPathsForVisibleRows]) {
        if (path.section != 0) continue;
        NSUInteger row = (NSUInteger)path.row;
        if (firstVisible == NSNotFound || row < firstVisible) firstVisible = row;
        if (lastVisible == NSNotFound || row > lastVisible) lastVisible = row;
    }
    if (firstVisible == NSNotFound) return NSNotFound;

    if (edge == DCUnreadEdgeTop) {
        if ([self.mentionedGuildRows containsIndex:firstVisible]) {
            CGRect rect = [table rectForRowAtIndexPath:
                [NSIndexPath indexPathForRow:firstVisible inSection:0]];
            CGFloat badgeY = CGRectGetMaxY(rect) - DCGuildMentionBadgeCenterFromBottom;
            if (badgeY < [self unreadListVisibleTop] + DCGuildUnreadEdgeClearance - 0.5f)
                return firstVisible;
        }
        return [self.mentionedGuildRows indexLessThanIndex:firstVisible];
    }

    if ([self.mentionedGuildRows containsIndex:lastVisible]) {
        CGRect rect = [table rectForRowAtIndexPath:
            [NSIndexPath indexPathForRow:lastVisible inSection:0]];
        CGFloat badgeY = CGRectGetMaxY(rect) - DCGuildMentionBadgeCenterFromBottom;
        if (badgeY > [self unreadListVisibleBottom] - DCGuildUnreadEdgeClearance + 0.5f)
            return lastVisible;
    }
    return [self.mentionedGuildRows indexGreaterThanIndex:lastVisible];
}

- (void)updateUnreadEdgeIndicators {
    if (!self.isViewLoaded || !self.view.window || !self.guildTableView ||
        self.guildFolderAnimationInProgress) return;
    [self layoutUnreadEdgeIndicators];

    [self.topUnreadIndicator setActive:
        [self nearestOffscreenMentionRowAtEdge:DCUnreadEdgeTop] != NSNotFound
                                     animated:YES];
    [self.bottomUnreadIndicator setActive:
        [self nearestOffscreenMentionRowAtEdge:DCUnreadEdgeBottom] != NSNotFound
                                        animated:YES];
}

- (void)finishPendingMentionRevealIfVisible {
    id item = self.pendingMentionRevealItem;
    if (!item) return;
    NSUInteger row = [self.displayGuilds indexOfObjectIdenticalTo:item];
    if (row == NSNotFound || row >= (NSUInteger)[self.guildTableView numberOfRowsInSection:0]) {
        self.pendingMentionRevealItem = nil;
        return;
    }

    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    CGRect cellRect = [self.guildTableView rectForRowAtIndexPath:path];
    if (CGRectGetMaxY(cellRect) <= [self unreadListVisibleTop] ||
        CGRectGetMinY(cellRect) >= [self unreadListVisibleBottom]) return;

    UITableViewCell *cell = [self.guildTableView cellForRowAtIndexPath:path];
    if (!cell) return;
    self.pendingMentionRevealItem = nil;

    [[cell viewWithTag:DCGuildMentionRevealHighlightTag] removeFromSuperview];
    UIView *highlight = [[UIView alloc] initWithFrame:cell.bounds];
    highlight.tag = DCGuildMentionRevealHighlightTag;
    highlight.userInteractionEnabled = NO;
    highlight.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    highlight.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.13f];
    [cell addSubview:highlight];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!highlight.superview) return;
        [UIView animateWithDuration:0.45f animations:^{
            highlight.alpha = 0.0f;
        } completion:^(BOOL finished) {
            [highlight removeFromSuperview];
        }];
    });
}

- (void)revealUnreadMentionAtEdge:(DCUnreadEdge)edge {
    if (self.guildFolderAnimationInProgress || self.mentionRevealScrollInProgress) return;
    UITableView *table = self.guildTableView;
    [table layoutIfNeeded];
    NSUInteger row = [self nearestOffscreenMentionRowAtEdge:edge];
    if (row == NSNotFound) return;

    CGRect cellRect = [table rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:row inSection:0]];
    UIEdgeInsets insets = table.contentInset;
    CGFloat visibleHeight = table.bounds.size.height - insets.top - insets.bottom;
    if (visibleHeight <= DCGuildUnreadEdgeClearance * 2.0f) return;

    CGFloat destination;
    if (edge == DCUnreadEdgeTop) {
        destination = CGRectGetMinY(cellRect) - insets.top - DCGuildUnreadEdgeClearance;
    } else {
        destination = CGRectGetMaxY(cellRect) - table.bounds.size.height +
                      insets.bottom + DCGuildUnreadEdgeClearance;
    }
    CGFloat minimum = -insets.top;
    CGFloat maximum = MAX(minimum, table.contentSize.height + insets.bottom -
                                   table.bounds.size.height);
    destination = MIN(MAX(destination, minimum), maximum);

    id target = [self.displayGuilds objectAtIndex:row];
    self.pendingMentionRevealItem = target;
    if (fabsf(destination - table.contentOffset.y) <= 0.5f) {
        [self finishPendingMentionRevealIfVisible];
        return;
    }

    self.pendingMentionRevealOffset = destination;
    self.mentionRevealScrollInProgress = YES;
    [table setContentOffset:CGPointMake(table.contentOffset.x, destination)
                   animated:YES];
    // iOS 5 may omit the completion callback at a clamped destination.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.mentionRevealScrollInProgress ||
            self.pendingMentionRevealItem != target) return;
        self.mentionRevealScrollInProgress = NO;
        [self updateUnreadEdgeIndicators];
        if (fabsf(table.contentOffset.y - self.pendingMentionRevealOffset) <= 1.0f)
            [self finishPendingMentionRevealIfVisible];
        else
            self.pendingMentionRevealItem = nil;
    });
}

- (void)tapTopUnreadIndicator:(id)sender {
    [self revealUnreadMentionAtEdge:DCUnreadEdgeTop];
}

- (void)tapBottomUnreadIndicator:(id)sender {
    [self revealUnreadMentionAtEdge:DCUnreadEdgeBottom];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.guildTableView) [self updateUnreadEdgeIndicators];
    else if (scrollView == self.channelTableView) [self updateChannelUnreadEdgeIndicators];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView == self.guildTableView) {
        self.pendingMentionRevealItem = nil;
        self.mentionRevealScrollInProgress = NO;
    } else if (scrollView == self.channelTableView) {
        self.pendingChannelMentionReveal = nil;
        self.channelMentionRevealScrollInProgress = NO;
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (scrollView == self.channelTableView) {
        self.channelMentionRevealScrollInProgress = NO;
        [self updateChannelUnreadEdgeIndicators];
        [self finishPendingChannelMentionReveal];
    } else if (scrollView == self.guildTableView) {
        self.mentionRevealScrollInProgress = NO;
        [self updateUnreadEdgeIndicators];
        [self finishPendingMentionRevealIfVisible];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutUnreadEdgeIndicators];
    [self updateUnreadEdgeIndicators];
    [self updateChannelUnreadEdgeIndicators];
}

- (void)reloadGuildTableFromCanonicalState {
    assertMainThread();
    if (self.guildFolderAnimationInProgress) {
        self.guildTableReloadPending = YES;
        return;
    }

    self.pendingMentionRevealItem = nil;
    self.mentionRevealScrollInProgress = NO;
    [self rebuildDisplayGuildsIfNeeded];
    [self.guildTableView reloadData];
    [self rebuildMentionedGuildRows];
    [self performSelector:@selector(updateUnreadEdgeIndicators)
               withObject:nil afterDelay:0.0f];
}

- (void)finishGuildFolderAnimation {
    assertMainThread();
    self.guildFolderAnimationInProgress = NO;

    if (self.guildTableReloadPending ||
        !DCServerCommunicator.sharedInstance.guildsIsSorted) {
        self.guildTableReloadPending = NO;
        [self reloadGuildTableFromCanonicalState];
    } else {
        [self rebuildMentionedGuildRows];
    }
}

- (void)synchronizeSelectedGuildUI {
    DCGuild *guild = self.selectedGuild;
    if (!guild) {
        [self.navigationItem setTitle:@"Discord"];
        self.guildLabel.text = @"Discord";
        self.totalView.hidden = YES;
        self.guildTotalView.hidden = NO;
        return;
    }

    DCServerCommunicator.sharedInstance.selectedGuild = guild;

    // Keep only the server snowflake. Direct Messages is represented by no
    // saved value because its synthetic guild deliberately has no snowflake.
    if ([self isDirectMessagesGuild:guild]) {
        [[DCCacheManager sharedInstance] clearLastSelectedGuild];
    } else if (guild.snowflake.length > 0) {
        [[DCCacheManager sharedInstance] saveLastSelectedGuildID:guild.snowflake];
    }

    NSString *guildName = guild.name ?: @"Discord";
    [self.navigationItem setTitle:guildName];
    self.guildLabel.text = guildName;

    if ([self isDirectMessagesGuild:guild]) {
        self.totalView.hidden = NO;
        self.userName.text = DCServerCommunicator.sharedInstance.currentUserInfo.globalName;
        self.globalName.text = [NSString stringWithFormat:@"@%@",
                                DCServerCommunicator.sharedInstance.currentUserInfo.username ?: @""];
        self.guildTotalView.hidden = YES;
        self.guildBanner.image = [DCInterfaceStyle guildBannerPlaceholderImage];
    } else {
        self.totalView.hidden = YES;
        self.guildTotalView.hidden = NO;
        // image bytes on disk. A cold RESUME never runs READY, so explicitly ask
        // the normal banner loader to materialize that cached asset when the guild
        // becomes visible. This is lazy: offscreen guild banners do no work.
        if (!guild.banner &&
            [guild.bannerID isKindOfClass:[NSString class]] &&
            guild.bannerID.length > 0 &&
            [guild.snowflake isKindOfClass:[NSString class]] &&
            guild.snowflake.length > 0) {
            [DCServerCommunicator.sharedInstance
                loadGuildBannerHash:guild.bannerID forGuild:guild];
        }
        self.guildBanner.image = guild.banner ?: [DCInterfaceStyle guildBannerPlaceholderImage];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
    }
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return UIInterfaceOrientationMaskPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.channelListStatesByGuildKey) {
        self.channelListStatesByGuildKey = [NSMutableDictionary dictionary];
    }
    self.shouldAttemptColdChatRestore = !self.coldChatRestoreAlreadyHandled;
    // Guard against duplicate registration on viewDidLoad re-fire (iOS 5 memory warning)
    [NSNotificationCenter.defaultCenter removeObserver:self];

    // Go to settings if no token is set
    if (!DCServerCommunicator.sharedInstance.token.length) {
        [self performSegueWithIdentifier:@"to Tokenpage" sender:self];
    }

    // NOTIF OBSERVERS
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleMessageAck:)
                                               name:@"MESSAGE ACK"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(reloadGuild:)
                                               name:@"RELOAD GUILD"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateStatusForUser:)
                                               name:@"USER_PRESENCE_UPDATED"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updateStatusForUser:)
                                               name:@"RELOAD USER DATA"
                                             object:nil];
    // these are resource intensive, do not use whenever possible
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleMessageAck:)
                                               name:@"RELOAD CHANNEL LIST"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReady)
                                               name:@"READY"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReady)
                                               name:@"RELOAD GUILD LIST"
                                             object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleNotificationTap:)
               name:@"NavigateToChannel"
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(exitedChatController)
               name:@"ChannelSelectionCleared"
             object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleChannelContextChanged:)
                                                 name:@"CHANNEL_CONTEXT_CHANGED"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleNavigateToGuild:)
                                                 name:@"NAVIGATE_TO_GUILD"
                                               object:nil];
    // NOTIF OBSERVERS END
    [self.navigationController.navigationBar
        setBackgroundImage:[DCInterfaceStyle navigationBarBackgroundImage]
             forBarMetrics:UIBarMetricsDefault];
    [DCInterfaceStyle applyNavigationTitleStyleToBar:self.navigationController.navigationBar];
    [self installMenuRefreshControls];

    self.experimentalMode =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"experimentalMode"];
    self.totalView.hidden = YES;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleLongPress:)];
    longPress.minimumPressDuration          = 0.5; // seconds
    [self.channelTableView addGestureRecognizer:longPress];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        UILongPressGestureRecognizer *guildPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleGuildLongPress:)];
        guildPress.minimumPressDuration = 0.5;
        [self.guildTableView addGestureRecognizer:guildPress];
    }
}

- (void)viewDidUnload {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    // nil IBOutlets
    [self.topUnreadIndicator removeFromSuperview];
    [self.bottomUnreadIndicator removeFromSuperview];
    [self.channelUnreadOverlay removeFromSuperview];
    self.channelUnreadOverlay = nil;
    self.topChannelUnreadIndicatorClearance = 0.0f;
    self.topChannelUnreadIndicatorTracksHeader = NO;
    [self.topChannelUnreadIndicator removeFromSuperview];
    [self.bottomChannelUnreadIndicator removeFromSuperview];
    self.topChannelUnreadIndicator = nil;
    self.bottomChannelUnreadIndicator = nil;
    self.mentionedChannelIndexPaths = nil;
    self.pendingChannelMentionReveal = nil;
    self.topUnreadIndicator = nil;
    self.bottomUnreadIndicator = nil;
    self.pendingMentionRevealItem = nil;
    self.guildTableView = nil;
    self.channelTableView = nil;
    self.displayChannels = nil;
    self.displayChannelSections = nil;
    self.displayChannelsGuild = nil;
    self.refreshControl = nil;
    // ... nil any other IBOutlets
    [super viewDidUnload];
}

- (BOOL)channelNeedsMarkAsRead:(DCChannel *)channel {
    if (!channel) return NO;
    if (channel.unread || channel.mentionCount > 0) return YES;

    if (channel.lastMessageId.length == 0) return NO;
    if (channel.lastReadMessageId.length == 0) return YES;

    return ![channel.lastMessageId isEqualToString:channel.lastReadMessageId];
}

- (UIButton *)actionSheetButtonWithTitle:(NSString *)title inView:(UIView *)view {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        if ([[button titleForState:UIControlStateNormal] isEqualToString:title]) {
            return button;
        }
    }

    for (UIView *subview in view.subviews) {
        UIButton *button = [self actionSheetButtonWithTitle:title inView:subview];
        if (button) return button;
    }

    return nil;
}

- (void)didPresentActionSheet:(UIActionSheet *)actionSheet {
    if (actionSheet.tag != 2 || !self.optionChannel) return;
    if ([self channelNeedsMarkAsRead:self.optionChannel]) return;

    UIButton *markReadButton = [self actionSheetButtonWithTitle:@"Mark As Read"
                                                         inView:actionSheet];
    markReadButton.enabled = NO;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint point          = [gestureRecognizer locationInView:self.channelTableView];
        NSIndexPath *indexPath = [self.channelTableView indexPathForRowAtPoint:point];
        if (!indexPath) {
            return;
        }
        DCChannel *channelAtRowIndex = [self displayedChannelAtIndexPath:indexPath];
        if (!channelAtRowIndex) return;
        self.optionChannel = channelAtRowIndex;

        NSString *muteTitle = channelAtRowIndex.muted ? @"Unmute Channel" : @"Mute Channel";
        UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:channelAtRowIndex.name
                                                                 delegate:self
                                                        cancelButtonTitle:@"Cancel"
                                                   destructiveButtonTitle:nil
                                                        otherButtonTitles:@"Mark As Read",
                                                                          @"Copy Link",
                                                                          muteTitle,
                                                                          @"Copy ID",
                                                                          nil];

        actionSheet.tag = 2;
        UIView *pressedCell = [self.channelTableView cellForRowAtIndexPath:indexPath];
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            [DCActionSheetPresenter showActionSheet:actionSheet
                                          fromView:pressedCell
                                            inView:self.view
                                          animated:YES];
        } else {
            [actionSheet showInView:self.view.superview ? self.view.superview : self.view];
        }
    }
}

// Fallback when the saved chat is not available until live state arrives.
- (void)attemptColdChatRestoreIfNeeded {
    if (!self.shouldAttemptColdChatRestore) return;

    NSString *channelID =
        [[DCCacheManager sharedInstance] loadLastActiveChatChannelID];

    if (channelID.length == 0) {
        self.shouldAttemptColdChatRestore = NO;
        return;
    }

    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in [guild channelsSnapshot]) {
            if (![channel.snowflake isEqualToString:channelID]) continue;

            self.shouldAttemptColdChatRestore = NO;
            DBGLOG(@"[ColdStart] Late-restoring chat %@ after cache miss",
                   channelID);
            [self navigateToChannelWithId:channelID];
            return;
        }
    }

    if (!DCServerCommunicator.sharedInstance.didAuthenticate) {
        return;
    }

    DBGLOG(@"[ColdStart] Saved chat %@ no longer exists; returning to menu",
           channelID);
    [[DCCacheManager sharedInstance] clearLastActiveChatChannel];
    self.shouldAttemptColdChatRestore = NO;
}

- (void)markColdChatRestoreHandled {
    self.coldChatRestoreAlreadyHandled = YES;
    self.shouldAttemptColdChatRestore = NO;
}

// Handle channel navigation from push notifications.

- (void)handleNotificationTap:(NSNotification *)notification {
    NSString *channelId = notification.userInfo[@"channelId"];
    if (channelId) {
        [self navigateToChannelWithId:channelId];
    }
}

- (void)exitedChatController {
    self.selectedChannel = nil;
}

- (void)navigateToChannelWithId:(NSString *)channelId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self navigateToChannelWithId:channelId];
        });
        return;
    }

    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in [guild channelsSnapshot]) {
            if (![channel.snowflake isEqualToString:channelId]) {
                continue;
            }
            if (!self.experimentalMode && self.navigationController &&
                self.navigationController.topViewController != self &&
                !self.splitViewController) {
                [self.navigationController popToViewController:self animated:NO];
            }
            [self markColdChatRestoreHandled];
            if (self.selectedChannel &&
                [self.selectedChannel.snowflake
                    isEqualToString:channelId]) {
                BOOL guildChanged = [self selectGuildForChannelList:guild];
                self.selectedChannel = channel;
                DCServerCommunicator.sharedInstance.selectedGuild = guild;
                DCServerCommunicator.sharedInstance.selectedChannel = channel;

                if ([self activateSelectedChannelInIPadSplitView]) {
                    [self synchronizeSelectedGuildUI];
                    if (guildChanged) {
                        [self reloadChannelTableForSelectedGuildRestoringScroll];
                    } else {
                        [self reloadChannelTable];
                    }
                } else if (self.experimentalMode) {
                    [self synchronizeSelectedGuildUI];
                    if (guildChanged) {
                        [self reloadChannelTableForSelectedGuildRestoringScroll];
                    } else {
                        [self reloadChannelTable];
                    }
                    [self activateSelectedChannelInExperimentalMode];
                }
                return;
            }
            BOOL guildChanged                                  = [self selectGuildForChannelList:guild];
            self.selectedChannel                                = channel;
            DCServerCommunicator.sharedInstance.selectedGuild   = guild;
            DCServerCommunicator.sharedInstance.selectedChannel = channel;

            if ([self isDirectMessagesGuild:guild]) {
                [[DCCacheManager sharedInstance] clearLastSelectedGuild];
            } else if (guild.snowflake.length > 0) {
                [[DCCacheManager sharedInstance] saveLastSelectedGuildID:guild.snowflake];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad &&
                    !self.experimentalMode) {
                    [self synchronizeSelectedGuildUI];
                    if (guildChanged) {
                        [self reloadChannelTableForSelectedGuildRestoringScroll];
                    } else {
                        [self reloadChannelTable];
                    }
                    [self activateSelectedChannelInIPadSplitView];
                } else if (self.experimentalMode) {
                    [DCServerCommunicator.sharedInstance
                        sendGuildSubscriptionWithGuildId:guild.snowflake
                                               channelId:channel.snowflake];
                    [self activateSelectedChannelInExperimentalMode];
                } else {
                    [self performSegueWithIdentifier:@"guilds to chat"
                                              sender:self];
                }
            });
            return;
        }
    }
}
// end of block

// reload
- (void)installMenuRefreshControls {
    self.guildTableView.alwaysBounceVertical = YES;
    if (self.guildTableView && !self.refreshControl) {
        UIRefreshControl *control = [[UIRefreshControl alloc] init];
        control.attributedTitle = [[NSAttributedString alloc]
            initWithString:@"Reload"
            attributes:[NSDictionary dictionaryWithObject:[UIFont systemFontOfSize:11.0f]
                                               forKey:@"NSFont"]];
        [control addTarget:self action:@selector(reconnect)
          forControlEvents:UIControlEventValueChanged];
        [self.guildTableView addSubview:control];
        self.refreshControl = control;
    }
}

- (void)refreshTrayFromCanonicalState {
    if (!self.isViewLoaded) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshTrayFromCanonicalState];
        });
        return;
    }

    DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
    if (self.selectedGuild) {
        DCGuild *canonicalGuild = nil;
        for (DCGuild *guild in communicator.guilds) {
            if (guild == self.selectedGuild ||
                (guild.snowflake.length &&
                 [guild.snowflake isEqualToString:self.selectedGuild.snowflake]) ||
                ([self isDirectMessagesGuild:guild] &&
                 [self isDirectMessagesGuild:self.selectedGuild])) {
                canonicalGuild = guild;
                break;
            }
        }
        if (canonicalGuild) self.selectedGuild = canonicalGuild;
        else if (communicator.guilds.count)
            self.selectedGuild = [communicator.guilds objectAtIndex:0];
    } else if (communicator.guilds.count) {
        self.selectedGuild = [communicator.guilds objectAtIndex:0];
    }

    [self synchronizeSelectedGuildUI];
    [self reloadGuildTableFromCanonicalState];
    [self reloadChannelTableForSelectedGuildRestoringScroll];
}

- (void)handleReady {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Capture the visible channel anchor before READY replaces guild/channel
        // objects so the restored position follows the same channel, not a row.
        [self saveChannelListStateForGuild:self.selectedGuild];

        // Refresh selectedGuild pointer if it's the DM guild, or recover if a
        // live GUILD_DELETE removed the guild currently shown in the channel pane.
        BOOL selectedGuildStillExists = NO;
        if (self.selectedGuild) {
            for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
                if (guild == self.selectedGuild ||
                    (guild.snowflake && [guild.snowflake isEqualToString:self.selectedGuild.snowflake])) {
                    [self selectGuildForChannelList:guild];
                    selectedGuildStillExists = YES;
                    break;
                }
            }
        }
        if (!selectedGuildStillExists && DCServerCommunicator.sharedInstance.guilds.count) {
            NSString *savedGuildID = [[DCCacheManager sharedInstance] loadLastSelectedGuildID];
            DCGuild *restoredGuild = nil;
            if (savedGuildID.length > 0) {
                for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
                    if ([guild.snowflake isEqualToString:savedGuildID]) {
                        restoredGuild = guild;
                        break;
                    }
                }
            }

            [self selectGuildForChannelList:(restoredGuild ?: [DCServerCommunicator.sharedInstance.guilds objectAtIndex:0])];
            self.selectedChannel = nil;
        }

        DCChannel *canonicalSelectedChannel =
            DCServerCommunicator.sharedInstance.selectedChannel;
        // READY may refresh the active chat without changing which server the
        // user is browsing. Keep the menu selection independent of that chat.
        self.selectedChannel = canonicalSelectedChannel;

        [self synchronizeSelectedGuildUI];

        [self reloadGuildTableFromCanonicalState];
        [self reloadChannelTableForSelectedGuildRestoringScroll];

        [self installMenuRefreshControls];
        [self.refreshControl endRefreshing];

        [self attemptColdChatRestoreIfNeeded];
    });
}

- (void)handleChannelContextChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleChannelContextChanged:notification];
        });
        return;
    }

    NSString *channelId = notification.userInfo[@"channelId"];
    if (!channelId) return;

    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in [guild channelsSnapshot]) {
            if (![channel.snowflake isEqualToString:channelId]) continue;

            [self markColdChatRestoreHandled];
            BOOL guildChanged = [self selectGuildForChannelList:guild];
            self.selectedChannel = channel;
            DCServerCommunicator.sharedInstance.selectedGuild = guild;
            [self synchronizeSelectedGuildUI];
            if (guildChanged) {
                [self reloadChannelTableForSelectedGuildRestoringScroll];
            } else {
                [self reloadChannelTable];
            }
            return;
        }
    }
}

- (void)handleNavigateToGuild:(NSNotification *)notification {
    NSString *guildId = notification.userInfo[@"guildId"];
    if (!guildId) return;
    
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        if (![guild.snowflake isEqualToString:guildId]) continue;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self markColdChatRestoreHandled];
            [self selectGuildForChannelList:guild];
            DCServerCommunicator.sharedInstance.selectedGuild = guild;
            [self synchronizeSelectedGuildUI];
            [self reloadChannelTableForSelectedGuildRestoringScroll];
        });
        return;
    }
}

- (void)reloadGuild:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadGuild:notification];
        });
        return;
    }
    DCGuild *guild = notification.object;
    if (!guild) {
        if (self.isViewLoaded && self.view.window)
            [self reloadGuildTableFromCanonicalState];
        return;
    }

    // A folder-cache miss may have lazily requested this guild icon. A normal
    // RELOAD GUILD means the runtime asset/state changed, so allow future
    // recovery attempts and let the folder row reevaluate its composite key.
    if (guild.snowflake.length)
        [self.folderIconHydrationRequests removeObject:guild.snowflake];

    // Hidden menu tables refresh from canonical state when they become visible again.
    if (!self.isViewLoaded || self.view.window == nil) {
        return;
    }

    // Keep the selected-guild chrome synchronized with surgical GUILD_UPDATE
    // events without needing a full READY-style table rebuild.
    if (self.selectedGuild == guild ||
        (self.selectedGuild.snowflake &&
         [self.selectedGuild.snowflake isEqualToString:guild.snowflake])) {
        self.selectedGuild = guild;
        if (self.displayChannelsGuild != guild) [self reloadChannelTable];
        [self.navigationItem setTitle:guild.name];
        self.guildLabel.text = guild.name;
        self.guildBanner.image = guild.banner ?: [DCInterfaceStyle guildBannerPlaceholderImage];
    }

    if (self.displayGuilds == nil) {
        return;
    }

    if (self.selectedGuild == guild ||
        (self.selectedGuild.snowflake.length &&
         [self.selectedGuild.snowflake isEqualToString:guild.snowflake])) {
        if (![self isDirectMessagesGuild:guild]) {
            self.guildBanner.image = guild.banner ?: [DCInterfaceStyle guildBannerPlaceholderImage];
        }
    }

    if (self.guildFolderAnimationInProgress) {
        self.guildTableReloadPending = YES;
        return;
    }

    if (!DCServerCommunicator.sharedInstance.guildsIsSorted) {
        [self reloadGuildTableFromCanonicalState];
        return;
    }

    // Guard against count mismatch — fall back to canonical state.
    if (self.displayGuilds.count != [self.guildTableView numberOfRowsInSection:0]) {
        [self reloadGuildTableFromCanonicalState];
        return;
    }

    // Collect index paths to reload before touching the table
    NSMutableArray *indexPaths = [NSMutableArray array];

    NSUInteger folderIdx = [self.displayGuilds
        indexOfObjectPassingTest:^BOOL(DCGuildFolder *folder, NSUInteger idx, BOOL *stop) {
            return [folder isKindOfClass:[DCGuildFolder class]]
                && guild.snowflake.length
                && [folder.guildIds containsObject:guild.snowflake];
        }];
    if (folderIdx != NSNotFound) {
        [indexPaths addObject:[NSIndexPath indexPathForRow:folderIdx inSection:0]];
    }

    NSUInteger index = [self.displayGuilds indexOfObject:guild];
    if (index != NSNotFound) {
        [indexPaths addObject:[NSIndexPath indexPathForRow:index inSection:0]];
    }

    // Reload only when at least one affected row is present.
    for (NSIndexPath *indexPath in indexPaths)
        [self refreshMentionedGuildRow:(NSUInteger)indexPath.row];
    [self updateUnreadEdgeIndicators];
    if (indexPaths.count == 0) return;

    [self.guildTableView reloadRowsAtIndexPaths:indexPaths
                               withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateStatusForUser:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusForUser:notification];
        });
        return;
    }
    DCUser *updatedUser = [notification.object isKindOfClass:[DCUser class]]
        ? (DCUser *)notification.object : nil;
    if (!updatedUser ||
        !updatedUser.snowflake.length) {
        return;
    }

    DCGuild *privateGuild = nil;
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        if ([self isDirectMessagesGuild:guild]) {
            privateGuild = guild;
            break;
        }
    }
    if (!privateGuild) return;

    // Identity/avatar notifications can arrive after the DM channels were
    // first painted. Update every 1:1 DM that references this user, including
    // cached channels whose recipient object has not been relinked yet.
    NSMutableArray *matchingRows = [NSMutableArray array];
    NSUInteger row = 0;
    NSArray *channelsForRows = [self isDirectMessagesGuild:self.selectedGuild]
        ? self.displayChannels : [privateGuild channelsSnapshot];
    for (DCChannel *channel in channelsForRows) {
        if (channel.type == DCChannelTypeDM) {
            BOOL referencesUser = [channel.recipientIDs containsObject:updatedUser.snowflake];
            DCUser *buddy = [self directMessageBuddyForChannel:channel];
            if (!referencesUser && buddy) {
                referencesUser = [buddy.snowflake isEqualToString:updatedUser.snowflake];
            }

            if (referencesUser) {
                if (buddy) {
                    NSString *displayName = [buddy displayName];
                    if (displayName.length) channel.name = displayName;
                }
                [matchingRows addObject:[NSIndexPath indexPathForRow:row inSection:0]];
            }
        }
        row++;
    }

    if (matchingRows.count == 0 ||
        ![self isDirectMessagesGuild:self.selectedGuild]) {
        return;
    }

    NSUInteger modelRowCount = self.displayChannels.count;
    NSUInteger tableRowCount =
        (NSUInteger)[self.channelTableView numberOfRowsInSection:0];
    if (modelRowCount != tableRowCount) {
        [self reloadChannelTable];
        return;
    }

    NSMutableArray *validRows = [NSMutableArray arrayWithCapacity:matchingRows.count];
    for (NSIndexPath *indexPath in matchingRows) {
        if ((NSUInteger)indexPath.row < modelRowCount) [validRows addObject:indexPath];
    }
    if (validRows.count == 0) return;

    [self.channelTableView reloadRowsAtIndexPaths:validRows
                                 withRowAnimation:UITableViewRowAnimationNone];
}

- (void)reloadTable {
    [self reconnect];
}

- (void)reconnect {
    [DCServerCommunicator.sharedInstance refreshWithFreshReady];
    // End on READY. Also release the gesture if the network is unavailable.
    __weak DCMenuViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf.refreshControl endRefreshing];
    });
}

// reload end
// misc
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (void)handleMessageAck:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleMessageAck:notification];
        });
        return;
    }

    if (!self.isViewLoaded || !self.view.window) return;

    NSString *channelID = notification.userInfo[@"channelId"];
    if (![channelID isKindOfClass:[NSString class]] || channelID.length == 0) {
        self.pendingMessageAckFullReload = YES;
    } else {
        if (!self.pendingMessageAckChannelIDs)
            self.pendingMessageAckChannelIDs = [NSMutableSet set];
        [self.pendingMessageAckChannelIDs addObject:channelID];
    }

    if (self.messageAckRefreshScheduled) return;
    self.messageAckRefreshScheduled = YES;
    __weak DCMenuViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.075 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf flushMessageAckUpdates];
    });
}

- (void)flushMessageAckUpdates {
    if (self.channelCategoryAnimationInProgress) return;
    self.messageAckRefreshScheduled = NO;
    BOOL reloadAllChannels = self.pendingMessageAckFullReload;
    self.pendingMessageAckFullReload = NO;
    NSSet *channelIDs = [self.pendingMessageAckChannelIDs copy];
    [self.pendingMessageAckChannelIDs removeAllObjects];
    if (!self.isViewLoaded || !self.view.window) return;
    if (reloadAllChannels) [self rebuildMentionedGuildRows];

    DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
    NSMutableSet *affectedGuilds = [NSMutableSet set];
    NSMutableSet *affectedGuildIDs = [NSMutableSet set];
    NSMutableArray *channelRows = [NSMutableArray array];

    for (NSUInteger section = 0; section < self.displayChannelSections.count; section++) {
        NSArray *rows = [self channelsInDisplayedSection:section];
        for (NSUInteger row = 0; row < rows.count; row++) {
            DCChannel *channel = [rows objectAtIndex:row];
            if (channel.snowflake.length && [channelIDs containsObject:channel.snowflake])
                [channelRows addObject:[NSIndexPath indexPathForRow:row inSection:section]];
        }
    }

    for (NSString *channelID in channelIDs) {
        DCChannel *channel = [communicator.channels objectForKey:channelID];
        if (!channel.parentGuild) continue;
        [affectedGuilds addObject:channel.parentGuild];
        if (channel.parentGuild.snowflake.length)
            [affectedGuildIDs addObject:channel.parentGuild.snowflake];
    }

    if (affectedGuilds.count) {
        if (self.guildFolderAnimationInProgress) {
            self.guildTableReloadPending = YES;
        } else if (self.displayGuilds && communicator.guildsIsSorted) {
            NSInteger tableCount = [self.guildTableView numberOfRowsInSection:0];
            if (tableCount != (NSInteger)self.displayGuilds.count) {
                [self reloadGuildTableFromCanonicalState];
            } else {
                NSSet *visibleGuildRows = [NSSet setWithArray:
                    [self.guildTableView indexPathsForVisibleRows] ?: @[]];
                NSMutableArray *guildRows = [NSMutableArray array];
                NSUInteger guildRow = 0;
                for (id item in self.displayGuilds) {
                    BOOL affected = NO;
                    if ([item isKindOfClass:[DCGuild class]]) {
                        DCGuild *guild = (DCGuild *)item;
                        affected = [affectedGuilds containsObject:guild] ||
                            (guild.snowflake.length &&
                             [affectedGuildIDs containsObject:guild.snowflake]);
                    } else if ([item isKindOfClass:[DCGuildFolder class]]) {
                        DCGuildFolder *folder = (DCGuildFolder *)item;
                        for (NSString *guildID in folder.guildIds) {
                            if ([affectedGuildIDs containsObject:guildID]) {
                                affected = YES;
                                break;
                            }
                        }
                    }
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:guildRow inSection:0];
                    if (affected) {
                        [self refreshMentionedGuildRow:guildRow];
                        if ([visibleGuildRows containsObject:indexPath])
                            [guildRows addObject:indexPath];
                    }
                    guildRow++;
                }
                if (guildRows.count)
                    [self.guildTableView reloadRowsAtIndexPaths:guildRows
                                               withRowAnimation:UITableViewRowAnimationNone];
                [self updateUnreadEdgeIndicators];
            }
        }
    }

    if (!self.selectedGuild) return;
    BOOL affectsSelectedGuild = reloadAllChannels || channelRows.count > 0 ||
        self.displayChannelsGuild != self.selectedGuild;
    if (!affectsSelectedGuild) {
        for (DCGuild *guild in affectedGuilds) {
            if (guild == self.selectedGuild ||
                (guild.snowflake.length &&
                 [guild.snowflake isEqualToString:self.selectedGuild.snowflake]) ||
                ([self isDirectMessagesGuild:guild] &&
                 [self isDirectMessagesGuild:self.selectedGuild])) {
                affectsSelectedGuild = YES;
                break;
            }
        }
    }
    if (!affectsSelectedGuild) return;

    if (reloadAllChannels || self.displayChannelsGuild != self.selectedGuild ||
        ![self displayedChannelsMatch:[self orderedChannelsForGuild:self.selectedGuild]]) {
        [self reloadChannelTable];
        return;
    }

    BOOL changedCategoryRows = NO;
    if (self.collapsedChannelCategoryKeys.count > 0 &&
        ![self isDirectMessagesGuild:self.selectedGuild]) {
        for (NSUInteger section = 0; section < self.displayChannelSections.count; section++) {
            if ([self isChannelCategoryCollapsed:[self categoryInDisplayedSection:section]]) {
                changedCategoryRows = ![self displayedChannelSectionsMatch:
                    [self sectionsForChannels:self.displayChannels]];
                break;
            }
        }
    }
    if (changedCategoryRows || [self channelIDsIncludeDisplayedCategory:channelIDs]) {
        [self reloadChannelTable];
        return;
    }

    [self refreshMentionedChannelIndexPathsForIDs:channelIDs];
    if (channelRows.count) {
        NSSet *visibleChannelRows = [NSSet setWithArray:
            [self.channelTableView indexPathsForVisibleRows] ?: @[]];
        NSMutableArray *visibleUpdates = [NSMutableArray array];
        for (NSIndexPath *indexPath in channelRows) {
            if ([visibleChannelRows containsObject:indexPath])
                [visibleUpdates addObject:indexPath];
        }
        if (visibleUpdates.count)
            [self.channelTableView reloadRowsAtIndexPaths:visibleUpdates
                                         withRowAnimation:UITableViewRowAnimationNone];
    }
}

// Keep the menu's visible chrome derived from the selected guild model.
// This matters on direct cold-chat restoration because the menu view is not
// loaded until the user taps Back; its storyboard labels may still contain
// their default Direct Messages text at that point.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self installMenuRefreshControls];
    [self refreshTrayFromCanonicalState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateUnreadEdgeIndicators];
    [self updateChannelUnreadEdgeIndicators];
    if (!self.experimentalMode) {
        [[DCConnectionPopup sharedPopup] setHostView:self.view];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [self saveChannelListStateForGuild:self.selectedGuild];
    [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [[DCConnectionPopup sharedPopup] clearHostView:self.view];
}

// misc end
- (void)showGuildOptionsForGuild:(DCGuild *)guild source:(id)source {
    self.optionGuild = guild;
    UIActionSheet *sheet = [[UIActionSheet alloc]
        initWithTitle:guild.name
             delegate:self
    cancelButtonTitle:@"Okay"
   destructiveButtonTitle:nil
        otherButtonTitles:guild ? @"Copy Guild ID" : nil, nil];
    sheet.tag = 1;
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad) {
        [sheet showInView:self.view.superview ? self.view.superview : self.view];
    } else if ([source isKindOfClass:[UIBarButtonItem class]]) {
        [sheet showFromBarButtonItem:(UIBarButtonItem *)source animated:YES];
    } else {
        UIView *anchor = [source isKindOfClass:[UIView class]] ? source : nil;
        [DCActionSheetPresenter showActionSheet:sheet
                                      fromView:anchor
                                        inView:self.view
                                      animated:YES];
    }
}

- (void)handleGuildLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan ||
        self.guildFolderAnimationInProgress) return;

    CGPoint point = [recognizer locationInView:self.guildTableView];
    NSIndexPath *indexPath = [self.guildTableView indexPathForRowAtPoint:point];
    if (!indexPath || indexPath.row >= (NSInteger)self.displayGuilds.count) return;

    id item = [self.displayGuilds objectAtIndex:indexPath.row];
    if (![item isKindOfClass:[DCGuild class]] || [self isDirectMessagesGuild:item]) return;
    UIView *cell = [self.guildTableView cellForRowAtIndexPath:indexPath];
    [self showGuildOptionsForGuild:(DCGuild *)item source:cell];
}

- (IBAction)moreInfo:(id)sender {
    id anchor = sender;
    if (![sender isKindOfClass:[UIView class]] &&
        ![sender isKindOfClass:[UIBarButtonItem class]]) {
        NSUInteger row = [self.displayGuilds indexOfObjectIdenticalTo:self.selectedGuild];
        if (row != NSNotFound) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
            anchor = [self.guildTableView cellForRowAtIndexPath:indexPath];
        }
    }
    [self showGuildOptionsForGuild:self.selectedGuild source:anchor];
}

- (void)actionSheet:(UIActionSheet *)popup
    clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (popup.tag == 1) {
        switch (buttonIndex) {
            case 0: {
                if (!self.optionGuild) break;
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string = self.optionGuild.snowflake;
                break;
            }
            default: {
                break;
            }
        }
        self.optionGuild = nil;
    } else if (popup.tag == 2) {
        DCChannel *channel = self.optionChannel;
        if (!channel) return;

        switch (buttonIndex) {
            case 0: {
                if (![self channelNeedsMarkAsRead:channel]) {
                    break;
                }
                if (channel.lastMessageId.length > 0) {
                    [channel ackMessage:channel.lastMessageId];
                } else {
                    channel.lastReadMessageId = channel.lastMessageId;
                    channel.mentionCount = 0;
                    channel.unread = NO;
                    [NSNotificationCenter.defaultCenter
                        postNotificationName:@"RELOAD CHANNEL LIST"
                                      object:channel
                                    userInfo:@{ @"channelId" : channel.snowflake }];
                }
                break;
            }
            case 1: {
                NSString *guildID = channel.parentGuild.snowflake.length > 0
                    ? channel.parentGuild.snowflake : @"@me";
                NSString *link = [NSString stringWithFormat:
                    @"https://discord.com/channels/%@/%@", guildID, channel.snowflake];
                [UIPasteboard generalPasteboard].string = link;
                break;
            }
            case 2: {
                if (channel.muted) {
                    [channel updateMuteState:NO duration:0];
                    break;
                }

                UIActionSheet *muteSheet = [[UIActionSheet alloc]
                    initWithTitle:[NSString stringWithFormat:@"Mute %@", channel.name]
                         delegate:self
                cancelButtonTitle:@"Cancel"
           destructiveButtonTitle:nil
                otherButtonTitles:@"For 15 Minutes",
                                  @"For 1 Hour",
                                  @"For 3 Hours",
                                  @"For 8 Hours",
                                  @"For 24 Hours",
                                  @"Until I turn it back on",
                                  nil];
                muteSheet.tag = 3;
                NSIndexPath *indexPath = [self indexPathForDisplayedChannelID:channel.snowflake];
                UIView *anchor = indexPath
                    ? [self.channelTableView cellForRowAtIndexPath:indexPath] : nil;
                if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                    [DCActionSheetPresenter showActionSheet:muteSheet
                                                  fromView:anchor
                                                    inView:self.view
                                                  animated:YES];
                } else {
                    [muteSheet showInView:self.view.superview ? self.view.superview : self.view];
                }
                return;
            }
            case 3: {
                [UIPasteboard generalPasteboard].string = channel.snowflake;
                break;
            }
            default:
                break;
        }
        self.optionChannel = nil;
    } else if (popup.tag == 3) {
        DCChannel *channel = self.optionChannel;
        if (!channel) return;

        NSInteger duration = 0;
        switch (buttonIndex) {
            case 0: duration = 15 * 60; break;
            case 1: duration = 60 * 60; break;
            case 2: duration = 3 * 60 * 60; break;
            case 3: duration = 8 * 60 * 60; break;
            case 4: duration = 24 * 60 * 60; break;
            case 5: duration = -1; break;
            default:
                self.optionChannel = nil;
                return;
        }

        [channel updateMuteState:YES duration:duration];
        self.optionChannel = nil;
    }
}

- (IBAction)userInfo:(id)sender {
    [self performSegueWithIdentifier:@"guilds to own info" sender:self];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    @autoreleasepool {
        if (tableView == self.guildTableView) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];

            if (self.guildFolderAnimationInProgress) {
                return;
            }
            if (!DCServerCommunicator.sharedInstance.guildsIsSorted) {
                [self reloadGuildTableFromCanonicalState];
                return;
            }
            if (indexPath.row >= self.displayGuilds.count) {
                [self reloadGuildTableFromCanonicalState];
                return;
            }

            id selectedGuild = [self.displayGuilds objectAtIndex:indexPath.row];
            if ([selectedGuild isKindOfClass:[DCGuildFolder class]]) {
                DCGuildFolder *folder           = selectedGuild;
                folder.opened                   = !folder.opened;
                [self refreshMentionedGuildRow:(NSUInteger)indexPath.row];
                NSDictionary *constFolderDict   = [[NSUserDefaults standardUserDefaults]
                    dictionaryForKey:[@(folder.id) stringValue]];
                NSMutableDictionary *folderDict = constFolderDict ? [constFolderDict mutableCopy] : [NSMutableDictionary dictionary];
                [folderDict setValue:[NSNumber numberWithBool:folder.opened] forKey:@"opened"];
                [[NSUserDefaults standardUserDefaults] setObject:folderDict
                                                          forKey:[@(folder.id) stringValue]];
                [[NSUserDefaults standardUserDefaults] synchronize];

                self.guildFolderAnimationInProgress = YES;
                [CATransaction begin];
                [CATransaction setCompletionBlock:^{
                    [self finishGuildFolderAnimation];
                }];
                [self.guildTableView beginUpdates];
                if (folder.opened) {
                    NSMutableArray *newIndexPaths = [NSMutableArray array];
                    NSUInteger curIdx             = [self.displayGuilds indexOfObject:folder] + 1;
                    for (NSString *guildId in folder.guildIds) { @autoreleasepool {
                        NSUInteger idx = [DCServerCommunicator.sharedInstance.guilds indexOfObjectPassingTest:^BOOL(DCGuild *g, NSUInteger idx, BOOL *stop) {
                            return [g.snowflake isEqualToString:guildId];
                        }];
                        NSAssert(idx != NSNotFound, @"Guild ID %@ not found", guildId);
                        DCGuild *guild = [DCServerCommunicator.sharedInstance.guilds objectAtIndex:idx];
                        NSAssert(guild != nil, @"Guild not found for ID %@", guildId);
                        [self.displayGuilds insertObject:guild atIndex:curIdx];
                        [newIndexPaths addObject:[NSIndexPath indexPathForRow:curIdx++ inSection:0]];
                    }}
                    NSAssert(newIndexPaths.count == folder.guildIds.count, @"New index paths count does not match folder guild IDs count (%@ != %@)", @(newIndexPaths.count), @(folder.guildIds.count));
                    [self.guildTableView insertRowsAtIndexPaths:newIndexPaths withRowAnimation:UITableViewRowAnimationAutomatic];
                } else {
                    NSMutableArray *indexPathsToDelete = [NSMutableArray array];
                    NSUInteger idx                     = [self.displayGuilds indexOfObject:folder] + 1;
                    for (NSUInteger i = 0; i < folder.guildIds.count; i++) { @autoreleasepool {
                        if (idx >= self.displayGuilds.count) {
                            break; // Prevent out of bounds
                        }
                        [self.displayGuilds removeObjectAtIndex:idx];
                        [indexPathsToDelete addObject:[NSIndexPath indexPathForRow:idx + i inSection:0]];
                    }}
                    NSAssert(indexPathsToDelete.count == folder.guildIds.count, @"Index paths to delete count does not match folder guild IDs count (%@ != %@)", @(indexPathsToDelete.count), @(folder.guildIds.count));
                    [self.guildTableView deleteRowsAtIndexPaths:indexPathsToDelete withRowAnimation:UITableViewRowAnimationAutomatic];
                }
                [self.guildTableView endUpdates];
                DCGuildTableViewCell *folderCell =
                    (DCGuildTableViewCell *)[tableView cellForRowAtIndexPath:indexPath];
                if ([folderCell isKindOfClass:[DCGuildTableViewCell class]]) {
                    [folderCell animateFolderBadgeWithCount:[self mentionCountForFolder:folder]
                                                    opened:folder.opened];
                }
                [CATransaction commit];
                return;
            }
            [self markColdChatRestoreHandled];
            [self selectGuildForChannelList:selectedGuild];

            // Always route a guild-table selection through the same model-driven
            // synchronization path used by cold restore/viewWillAppear. Besides
            // updating the chrome and communicator selection, this is the
            // tap-time banner failsafe: if the guild has a persisted banner hash
            // but no runtime UIImage yet, synchronizeSelectedGuildUI asks the
            // normal SDWebImage-backed banner loader to materialize it.
            [self synchronizeSelectedGuildUI];

            @autoreleasepool {
                [self reloadChannelTableForSelectedGuildRestoringScroll];
            }
        } else if (tableView == self.channelTableView) {
            DCChannel *channelAtRowIndex = [self displayedChannelAtIndexPath:indexPath];
            if (!channelAtRowIndex) return;

            [self markColdChatRestoreHandled];
            DCServerCommunicator.sharedInstance.selectedChannel = channelAtRowIndex;
            self.selectedChannel                                = channelAtRowIndex;

            [DCServerCommunicator.sharedInstance
                sendGuildSubscriptionWithGuildId:self.selectedGuild.snowflake
                                       channelId:self.selectedChannel.snowflake];

            [tableView deselectRowAtIndexPath:indexPath animated:YES];

            if ([self activateSelectedChannelInIPadSplitView]) {
                return;
            }
            if (self.experimentalMode) {
                [self activateSelectedChannelInExperimentalMode];
            } else {
                [self performSegueWithIdentifier:@"guilds to chat" sender:self];
            }
        }
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.rowHeight;
}

- (NSString *)compositeCacheKeyForFolder:(DCGuildFolder *)folder {
    if (!folder) return nil;
    NSMutableArray *parts = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"%ld", (long)folder.id]];
    NSUInteger count = MIN((NSUInteger)4, folder.guildIds.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSString *guildID = [folder.guildIds objectAtIndex:i];
        NSString *iconHash = @"-";
        for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
            if (![guild.snowflake isEqualToString:guildID]) continue;
            if ([guild.iconID isKindOfClass:[NSString class]] && guild.iconID.length)
                iconHash = guild.iconID;
            break;
        }
        [parts addObject:[NSString stringWithFormat:@"%@:%@", guildID ?: @"-", iconHash]];
    }
    return [parts componentsJoinedByString:@"|"];
}

- (UIImage *)compositeImageWithBaseImage:(UIImage *)baseImage icons:(NSArray *)icons {
    // Compose the guild base, centered folder tile, then the 2x2 guild grid.
    const CGFloat canvasSize = 48.0f;
    const CGFloat folderSize = 40.0f;
    const CGFloat folderInset = (canvasSize - folderSize) / 2.0f;
    CGSize size = CGSizeMake(canvasSize, canvasSize);
    CGRect folderRect = CGRectMake(folderInset, folderInset,
                                   folderSize, folderSize);

    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);

    UIImage *folderFoundation = [DCContentManager processedGuildIcon:baseImage];
    if (folderFoundation) {
        [folderFoundation drawInRect:CGRectMake(0.0f, 0.0f,
                                                canvasSize, canvasSize)];
    }

    // Lay the mini-icon grid inside the centered 40pt folder artwork.
    CGFloat quarterWidth  = folderSize / 2.0f;
    CGFloat quarterHeight = folderSize / 2.0f;

    CGFloat iconScale   = 0.6f; // icons are 60% of each grid quarter
    CGFloat iconWidth   = quarterWidth * iconScale;
    CGFloat iconHeight  = quarterHeight * iconScale;

    // Scale the original mini-icon spacing to the 40pt folder artwork.
    CGFloat iconPadding = folderSize * (25.0f / 448.0f);

    CGFloat leftCenterX   = CGRectGetMinX(folderRect) + quarterWidth * 0.5f + iconPadding;
    CGFloat rightCenterX  = CGRectGetMinX(folderRect) + quarterWidth * 1.5f - iconPadding;
    CGFloat topCenterY    = CGRectGetMinY(folderRect) + quarterHeight * 0.5f + iconPadding;
    CGFloat bottomCenterY = CGRectGetMinY(folderRect) + quarterHeight * 1.5f - iconPadding;

    CGPoint gridCenters[4] = {
        CGPointMake(leftCenterX,  topCenterY),
        CGPointMake(rightCenterX, topCenterY),
        CGPointMake(leftCenterX,  bottomCenterY),
        CGPointMake(rightCenterX, bottomCenterY)
    };

    // Draw each icon centered in its grid quarter
    for (NSUInteger i = 0; i < icons.count; i++) {
        id iconObj = icons[i];

        if (iconObj == nil || ![iconObj isKindOfClass:[UIImage class]]) {
            continue; // Skip this icon
        }

        UIImage *icon = iconObj;
        UIImage *miniIcon = [DCContentManager processedFolderMiniGuildIcon:icon];
        if (!miniIcon) continue;

        // The source mini icon is already rounded and rasterized at device scale.
        CGPoint center = gridCenters[i];
        CGRect rect = CGRectMake(center.x - iconWidth / 2.0f,
                                 center.y - iconHeight / 2.0f,
                                 iconWidth, iconHeight);
        [miniIcon drawInRect:rect];
    }

    // Get final composite image
    UIImage *compositeImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return compositeImage;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    

    if (tableView == self.guildTableView) {
        NSCAssert(
            self.displayGuilds && self.displayGuilds.count > indexPath.row,
            @"Guilds array is empty or index out of bounds"
        );

        id objectAtRowIndex = [self.displayGuilds objectAtIndex:indexPath.row];

        NSCAssert(objectAtRowIndex && objectAtRowIndex != [NSNull null], @"Guild at row index is nil or NSNull");

        // Use the DCGuildTableViewCell
        DCGuildTableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:@"guild"];
        if (cell == nil) {
            cell = [[DCGuildTableViewCell alloc]
                  initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:@"guild"];
        }
        [[cell viewWithTag:DCGuildMentionRevealHighlightTag] removeFromSuperview];
        [cell cancelFolderBadgeAnimation];
        @autoreleasepool {
            if ([objectAtRowIndex isKindOfClass:[DCGuild class]]) {
                DCGuild *guildAtRowIndex = objectAtRowIndex;

                // Show blue indicator if guild has any unread messages
                cell.unreadMessages.hidden = !guildAtRowIndex.unread;

                cell.mentionBadge.mentionCount = guildAtRowIndex.mentionCount;
                if (guildAtRowIndex.mentionCount > 0) {
                    cell.unreadMessages.hidden = NO;
                }
                [cell setNeedsLayout];

                // The 48pt tile is precomposited when the guild icon changes.
                cell.guildAvatar.image = guildAtRowIndex.compositedIcon
                    ?: [DCInterfaceStyle guildIconBaseImage];
            } else if ([objectAtRowIndex isKindOfClass:[DCGuildFolder class]]) {
                DCGuildFolder *folderAtRowIndex = objectAtRowIndex;
                
                // Sum mention counts across all guilds in the folder
                NSInteger folderMentionCount = 0;
                BOOL folderUnread = NO;
                for (NSString *guildId in folderAtRowIndex.guildIds) {
                    NSUInteger idx = [DCServerCommunicator.sharedInstance.guilds
                        indexOfObjectPassingTest:^BOOL(DCGuild *g, NSUInteger i, BOOL *stop) {
                            return [g.snowflake isEqualToString:guildId];
                        }];
                    if (idx != NSNotFound) {
                        DCGuild *guild = [DCServerCommunicator.sharedInstance.guilds objectAtIndex:idx];
                        folderMentionCount += guild.mentionCount;
                        if (guild.unread && (!guild.muted || guild.mentionCount > 0)) {
                            folderUnread = YES;
                        }
                    }
                }
                cell.unreadMessages.hidden = !folderUnread;
                
                cell.mentionBadge.mentionCount = folderAtRowIndex.opened
                    ? 0 : folderMentionCount;
                [cell setNeedsLayout];
                
                NSString *folderCacheKey = [self compositeCacheKeyForFolder:folderAtRowIndex];
                if (folderAtRowIndex.icon != nil &&
                    [folderAtRowIndex.iconCacheKey isEqualToString:folderCacheKey]) {
                    cell.guildAvatar.image = folderAtRowIndex.icon;
                    return cell;
                }

                // A successful cold RESUME never re-sends READY, so the source
                // guild UIImages may not exist yet. Prefer the last composite
                // produced from the same folder membership/icon hashes.
                UIImage *diskComposite = [[DCCacheManager sharedInstance]
                    cachedFolderCompositeForFolderID:folderAtRowIndex.id
                                             cacheKey:folderCacheKey];
                if (diskComposite) {
                    folderAtRowIndex.icon = diskComposite;
                    folderAtRowIndex.iconCacheKey = folderCacheKey;
                    cell.guildAvatar.image = diskComposite;
                    return cell;
                }

                UIImage *folderIcon   = [DCInterfaceStyle guildFolderImage];
                NSMutableArray *icons = [NSMutableArray array];
                BOOL allSourcesReady = YES;
                NSUInteger expectedSources = MIN((NSUInteger)4, folderAtRowIndex.guildIds.count);
                for (NSUInteger i = 0; i < expectedSources; i++) {
                    NSString *guildID = [folderAtRowIndex.guildIds objectAtIndex:i];
                    NSUInteger idx = [DCServerCommunicator.sharedInstance.guilds indexOfObjectPassingTest:^BOOL(DCGuild *obj, NSUInteger row, BOOL *stop) {
                        return [obj isKindOfClass:[DCGuild class]] && [obj.snowflake isEqualToString:guildID];
                    }];
                    if (idx == NSNotFound) {
                        allSourcesReady = NO;
                        continue;
                    }
                    DCGuild *guild = [DCServerCommunicator.sharedInstance.guilds objectAtIndex:idx];
                    if (!guild || ![guild isKindOfClass:[DCGuild class]]) {
                        allSourcesReady = NO;
                        continue;
                    }

                    // Guilds with no custom icon can derive their default locally.
                    if (!guild.iconID.length && !guild.icon) {
                        unsigned long long value = [guild.snowflake longLongValue];
                        NSUInteger selector = (NSUInteger)((value >> 22) % 6);
                        NSArray *defaults = [DCUser defaultAvatars];
                        if (selector < defaults.count)
                            guild.icon = [defaults objectAtIndex:selector];
                    }

                    BOOL waitingForHashBackedIcon =
                        guild.iconID.length &&
                        (!guild.icon || [[DCUser defaultAvatars] containsObject:guild.icon]);
                    if (waitingForHashBackedIcon) {
                        allSourcesReady = NO;
                        if (!self.folderIconHydrationRequests)
                            self.folderIconHydrationRequests = [NSMutableSet set];
                        if (![self.folderIconHydrationRequests containsObject:guild.snowflake]) {
                            [self.folderIconHydrationRequests addObject:guild.snowflake];
                            [DCServerCommunicator.sharedInstance
                                loadGuildIconHash:guild.iconID forGuild:guild];
                        }
                        continue;
                    }

                    if (!guild.icon) {
                        allSourcesReady = NO;
                        continue;
                    }
                    [icons addObject:guild.icon];
                }

                // A cache miss after a folder/icon change waits for the actual
                // first-four source icons instead of saving a placeholder composite.
                if (!allSourcesReady || icons.count != expectedSources) {
                    folderAtRowIndex.icon = nil;
                    folderAtRowIndex.iconCacheKey = nil;
                    // Show the folder foundation while mini icons hydrate.
                    cell.guildAvatar.image = [DCContentManager processedGuildIcon:folderIcon]
                        ?: [DCInterfaceStyle guildIconBaseImage];
                    return cell;
                }

                UIImage *compositeImage = [self
                    compositeImageWithBaseImage:folderIcon
                                          icons:icons];
                cell.guildAvatar.image = compositeImage;
                folderAtRowIndex.icon = compositeImage;
                folderAtRowIndex.iconCacheKey = folderCacheKey;
                [[DCCacheManager sharedInstance]
                    saveFolderComposite:compositeImage
                            forFolderID:folderAtRowIndex.id
                               cacheKey:folderCacheKey];
            }
        }
        return cell;
    } else if (tableView == self.channelTableView) {
        if ([self isDirectMessagesGuild:self.selectedGuild]) {
            DCPrivateChannelTableCell *cell =
                [tableView dequeueReusableCellWithIdentifier:@"private"];
            if (cell == nil) {
                cell = [[DCPrivateChannelTableCell alloc]
                      initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:@"private"];
            }
            [[cell viewWithTag:DCChannelMentionRevealHighlightTag] removeFromSuperview];

            DCChannel *channelAtRowIndex = [self displayedChannelAtIndexPath:indexPath];
            if (!channelAtRowIndex) {
                return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                               reuseIdentifier:nil];
            }

            @autoreleasepool {

                cell.mentionBadge.mentionCount = channelAtRowIndex.mentionCount;
                cell.unreadMessages.hidden = (channelAtRowIndex.mentionCount == 0 &&
                                              !channelAtRowIndex.unread);
                [cell setNeedsLayout];
                DCUser *buddy = [self directMessageBuddyForChannel:channelAtRowIndex];
                if (buddy) {
                    NSString *displayName = [buddy displayName];
                    if (displayName.length) {
                        channelAtRowIndex.name = displayName;
                        cell.nameLabel.text = displayName;
                    } else {
                        cell.nameLabel.text = channelAtRowIndex.name;
                    }

                    // Visible DM rows should be able to finish their own avatar
                    // hydration. Cold start intentionally warms only a small
                    // number of DM icons, so relying solely on preload work can
                    // leave deeper rows showing defaults indefinitely.
                    if (!buddy.profileImage) [DCTools getUserAvatar:buddy];

                    if (buddy.profileImage && buddy.profileImage.size.width > 0) {
                        cell.pfp.image = buddy.profileImage;
                    } else {
                        cell.pfp.image = [self fallbackAvatarForDMUser:buddy
                                                                  channel:channelAtRowIndex];
                    }

                    cell.statusImage.image =
                        [DCInterfaceStyle statusImageForStatus:buddy.status];
                    cell.statusImage.hidden = NO;
                } else {
                    // Always overwrite reused-cell state, even when recipient
                    // hydration is temporarily incomplete.
                    cell.nameLabel.text = channelAtRowIndex.name;
                    cell.pfp.image = [channelAtRowIndex.icon isKindOfClass:[UIImage class]]
                        ? channelAtRowIndex.icon : nil;
                    cell.statusImage.hidden = YES;
                }
            }

            return cell;
        } else {
            DCChannel *channelAtRowIndex = [self displayedChannelAtIndexPath:indexPath];
            if (!channelAtRowIndex) {
                return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                               reuseIdentifier:nil];
            }

            DCChannelViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"channel"];
            if (cell == nil) {
                cell = [[DCChannelViewCell alloc]
                      initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:@"channel"];
            }
            [[cell viewWithTag:DCChannelMentionRevealHighlightTag] removeFromSuperview];
            cell.mentionBadge.mentionCount = channelAtRowIndex.mentionCount;
            cell.messageIndicator.hidden = (channelAtRowIndex.mentionCount == 0 &&
                                            !(channelAtRowIndex.unread && !channelAtRowIndex.muted));
            [cell setNeedsLayout];
            cell.channelName.text = channelAtRowIndex.name;
            UIColor *readChannelColor = [UIColor colorWithRed:128.0 / 255.0
                                                        green:132.0 / 255.0
                                                         blue:143.0 / 255.0
                                                        alpha:1.0];
            if (channelAtRowIndex.muted) {
                // Muted channels always use the read-state color. Dim only the
                // name so mentions and other channel chrome remain legible.
                cell.channelName.textColor = readChannelColor;
                cell.channelName.alpha = 0.45;
            } else {
                cell.channelName.textColor = channelAtRowIndex.unread
                    ? [UIColor whiteColor] : readChannelColor;
                cell.channelName.alpha = 1.0;
            }
            cell.alpha = 1.0;

            return cell;
        }
    }
    NSCAssert(0, @"Unexpected table view type");
    abort();
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForHeaderInSection:(NSInteger)section {
    if (tableView != self.channelTableView) return 0.0f;
    return [self categoryInDisplayedSection:section]
        ? [DCChannelCategoryHeaderView headerHeight] : 0.0f;
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForFooterInSection:(NSInteger)section {
    return 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView
    viewForHeaderInSection:(NSInteger)section {
    if (tableView != self.channelTableView) return nil;
    DCChannel *category = [self categoryInDisplayedSection:section];
    if (!category) return nil;

    DCChannelCategoryHeaderView *header = [[DCChannelCategoryHeaderView alloc]
        initWithFrame:CGRectMake(0.0f, 0.0f, tableView.bounds.size.width,
                                 [DCChannelCategoryHeaderView headerHeight])];
    header.title = category.name;
    header.categoryID = category.snowflake;
    header.section = section;
    header.collapsed = [self isChannelCategoryCollapsed:category];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(didTapChannelCategoryHeader:)];
    [header addGestureRecognizer:tap];
    return header;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return tableView == self.channelTableView ? self.displayChannelSections.count : 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.guildTableView) {
        return section == 0 ? self.displayGuilds.count : 0;
    } else if (tableView == self.channelTableView) {
        return [self channelsInDisplayedSection:section].count;
    }
    return 0;
}

// SEGUE
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if (![segue.destinationViewController isKindOfClass:[DCChatViewController class]]) {
        return;
    }
    if (![segue.identifier isEqualToString:@"guilds to chat"]) {
        return;
    }
    DCChatViewController *chatViewController =
        [segue destinationViewController];

    if (![chatViewController isKindOfClass:[DCChatViewController class]]) {
        return;
    }
    DCChannel *selectedChannel =
        DCServerCommunicator.sharedInstance.selectedChannel;

    NSString *formattedChannelName;

    formattedChannelName = selectedChannel.name;
    chatViewController.navigationItem.title = formattedChannelName;
}
// SEGUE END
@end
