//
//  DCCInfoViewController.m
//  Discord Classic
//
//  Created by XML on 12/11/23.
//  Copyright (c) 2023 bag.xml. All rights reserved.
//

#import "DCInterfaceStyle.h"
#import "DCCInfoViewController.h"
#include "DCUser.h"
#include "DCGuild.h"
#include "DCChannel.h"
#include "DCServerCommunicator.h"
#include <CoreGraphics/CGGeometry.h>
#include "DCTools.h"
#include "DCRecipientTableCell.h"
#include "DCRole.h"
#include <Foundation/Foundation.h>
#import "DCContentManager.h"

static const NSUInteger DCMemberListPageSize = 100;
static const NSUInteger DCMemberListPrefetchThreshold = 25;
static const NSTimeInterval DCMemberListMinimumSubscriptionInterval = 1.5;
static const NSTimeInterval DCMemberListRefreshCheckDelay = 1.75;
static const NSUInteger DCMemberListMaximumRefreshRetries = 2;

@interface DCCInfoViewController ()
@property (strong, nonatomic) DCGuild *memberListGuild;
@property (strong, nonatomic) NSString *memberListChannelID;
@property (strong, nonatomic) NSArray *memberListGroups;
@property (strong, nonatomic) NSArray *memberListSectionStarts;
@property (strong, nonatomic) NSArray *desiredMemberListRanges;
@property (strong, nonatomic) NSArray *sentMemberListRanges;
@property (strong, nonatomic) NSDate *lastMemberListSubscriptionDate;
@property (assign, nonatomic) BOOL memberListVisible;
@property (assign, nonatomic) NSUInteger memberListRefreshRetryCount;
@property (assign, nonatomic) NSUInteger memberListGeneration;
@end

@implementation DCCInfoViewController

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
    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(guildMemberListUpdated:)
                                               name:@"GuildMemberListUpdated"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReloadUser:)
                                               name:@"RELOAD USER DATA"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(memberListChannelEntered:)
                                               name:@"GuildMemberListChannelEntered"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(selectedChannelChanged:)
                                               name:@"SelectedChannelChanged"
                                             object:nil];

    [self configureForSelectedChannel];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.memberListVisible = YES;
    [self configureForSelectedChannel];
    [self.tableView reloadData];

    if (self.memberListGuild && self.memberListChannelID.length > 0) {
        [self beginMemberListRefreshCycle];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.memberListVisible = NO;
    [self cancelPendingMemberListWork];

}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Member list safety

- (void)cancelPendingMemberListWork {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(flushMemberListSubscription)
                                               object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(verifyMemberListRefresh)
                                               object:nil];
}

- (BOOL)isMemberListContextCurrentForGeneration:(NSUInteger)generation
                                         guildID:(NSString *)guildID
                                       channelID:(NSString *)channelID {
    if (!self.memberListVisible || generation != self.memberListGeneration) return NO;

    DCChannel *selected = DCServerCommunicator.sharedInstance.selectedChannel;
    if (!selected || ![selected.snowflake isEqualToString:channelID]) return NO;
    if (![selected.parentGuild.snowflake isEqualToString:guildID]) return NO;
    if (![self.memberListChannelID isEqualToString:channelID]) return NO;
    if (![self.memberListGuild.snowflake isEqualToString:guildID]) return NO;
    return YES;
}

- (NSArray *)safeVisibleIndexPathsForReload {
    NSArray *visible = [self.tableView indexPathsForVisibleRows];
    if (visible.count == 0) return [NSArray array];

    NSInteger sectionCount = [self.tableView numberOfSections];
    NSMutableArray *valid = [NSMutableArray arrayWithCapacity:visible.count];
    for (NSIndexPath *indexPath in visible) {
        if (indexPath.section < 0 || indexPath.section >= sectionCount) continue;
        NSInteger rowCount = [self.tableView numberOfRowsInSection:indexPath.section];
        if (indexPath.row < 0 || indexPath.row >= rowCount) continue;
        [valid addObject:indexPath];
    }
    return valid;
}

#pragma mark - Member list model

- (void)configureForSelectedChannel {
    DCChannel *channel = DCServerCommunicator.sharedInstance.selectedChannel;
    if (!channel) {
        if (self.memberListGuild || self.memberListChannelID.length > 0) {
            self.memberListGeneration++;
            [self cancelPendingMemberListWork];
        }
        self.memberListGuild = nil;
        self.memberListChannelID = nil;
        self.memberListGroups = [NSArray array];
        self.memberListSectionStarts = [NSArray array];
        self.desiredMemberListRanges = nil;
        self.sentMemberListRanges = nil;
        self.lastMemberListSubscriptionDate = nil;
        self.memberListRefreshRetryCount = 0;
        self.recipients = [NSMutableArray array];
        return;
    }

    DCGuild *guild = channel.parentGuild;
    if (!guild.snowflake.length) {
        BOOL changedChannel = self.memberListGuild != nil ||
            ![self.memberListChannelID isEqualToString:channel.snowflake];
        if (changedChannel) {
            self.memberListGeneration++;
            [self cancelPendingMemberListWork];
            self.desiredMemberListRanges = nil;
            self.sentMemberListRanges = nil;
            self.lastMemberListSubscriptionDate = nil;
            self.memberListRefreshRetryCount = 0;
            DBGLOG(@"[MemberListGuard] generation=%lu DM channel=%@",
                   (unsigned long)self.memberListGeneration, channel.snowflake);
        }

        self.memberListGuild = nil;
        self.memberListChannelID = channel.snowflake;
        self.memberListGroups = [NSArray array];
        self.memberListSectionStarts = [NSArray array];

        NSMutableArray *canonicalRecipients = [NSMutableArray array];
        DCServerCommunicator *communicator = DCServerCommunicator.sharedInstance;
        NSString *currentUserID = communicator.snowflake;
        for (NSString *recipientID in channel.recipientIDs) {
            if (![recipientID isKindOfClass:[NSString class]] || recipientID.length == 0) continue;
            if (currentUserID.length && [recipientID isEqualToString:currentUserID]) continue;
            DCUser *user = [communicator userForSnowflake:recipientID];
            if (user && ![canonicalRecipients containsObject:user]) {
                [canonicalRecipients addObject:user];
            }
        }
        for (DCUser *recipient in channel.recipients) {
            if (![recipient isKindOfClass:[DCUser class]]) continue;
            if (currentUserID.length && [recipient.snowflake isEqualToString:currentUserID]) continue;
            BOOL alreadyPresent = NO;
            for (DCUser *existing in canonicalRecipients) {
                if (existing == recipient || [existing.snowflake isEqualToString:recipient.snowflake]) {
                    alreadyPresent = YES;
                    break;
                }
            }
            if (!alreadyPresent) [canonicalRecipients addObject:recipient];
        }
        self.recipients = canonicalRecipients;
        self.title = channel.name;
        self.navigationItem.title = self.title;
        return;
    }

    BOOL changedChannel = self.memberListGuild != guild ||
        ![self.memberListChannelID isEqualToString:channel.snowflake];

    self.memberListGuild = guild;
    self.memberListChannelID = channel.snowflake;
    self.title = guild.name;
    self.navigationItem.title = self.title;

    if (changedChannel) {
        self.memberListGeneration++;
        [self cancelPendingMemberListWork];
        self.desiredMemberListRanges = nil;
        self.sentMemberListRanges = nil;
        self.lastMemberListSubscriptionDate = nil;
        self.memberListRefreshRetryCount = 0;
        DBGLOG(@"[MemberListGuard] generation=%lu guild=%@ channel=%@",
               (unsigned long)self.memberListGeneration,
               guild.snowflake, channel.snowflake);
    }

    [self rebuildMemberListSections];
}

- (void)rebuildMemberListSections {
    DCGuild *guild = self.memberListGuild;
    if (!guild) {
        self.memberListGroups = [NSArray array];
        self.memberListSectionStarts = [NSArray array];
        return;
    }

    NSArray *groups = nil;
    @synchronized(guild) {
        groups = [guild.memberListGroups copy];
    }
    if (![groups isKindOfClass:[NSArray class]]) groups = [NSArray array];

    NSMutableArray *starts = [NSMutableArray arrayWithCapacity:groups.count];
    NSUInteger absoluteIndex = 0;
    for (NSDictionary *group in groups) {
        [starts addObject:@(absoluteIndex)];
        NSUInteger count = [[group objectForKey:@"count"] unsignedIntegerValue];
        absoluteIndex += count + 1;
    }

    self.memberListGroups = groups;
    self.memberListSectionStarts = starts;
}

- (NSUInteger)memberListStreamLength {
    if (self.memberListGroups.count == 0) return 0;
    NSDictionary *lastGroup = [self.memberListGroups lastObject];
    NSUInteger lastStart = [[self.memberListSectionStarts lastObject] unsignedIntegerValue];
    return lastStart + [[lastGroup objectForKey:@"count"] unsignedIntegerValue] + 1;
}

- (NSUInteger)absoluteMemberListIndexForIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= self.memberListSectionStarts.count) return NSNotFound;
    NSUInteger sectionStart = [[self.memberListSectionStarts objectAtIndex:indexPath.section] unsignedIntegerValue];
    return sectionStart + 1 + (NSUInteger)indexPath.row;
}

- (id)memberListItemAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger absoluteIndex = [self absoluteMemberListIndexForIndexPath:indexPath];
    if (absoluteIndex == NSNotFound || !self.memberListGuild) return nil;
    @synchronized(self.memberListGuild) {
        return [self.memberListGuild.memberListItems objectForKey:@(absoluteIndex)];
    }
}

- (BOOL)memberListAbsoluteIndexIsStale:(NSUInteger)absoluteIndex {
    if (absoluteIndex == NSNotFound || !self.memberListGuild) return NO;
    @synchronized(self.memberListGuild) {
        return [self.memberListGuild.memberListStaleIndexes containsIndex:absoluteIndex];
    }
}

- (NSString *)titleForMemberListGroup:(NSDictionary *)group {
    NSString *groupID = [group objectForKey:@"id"];
    if ([groupID isEqualToString:@"online"]) return @"Online";
    if ([groupID isEqualToString:@"offline"]) return @"Offline";

    DCRole *role = [self.memberListGuild.roles objectForKey:groupID];
    if (!role) role = [DCServerCommunicator.sharedInstance roleForSnowflake:groupID];
    if (role.name.length > 0) return role.name;
    return groupID ?: @"Members";
}

- (NSUInteger)preferredMemberListRefreshAbsoluteIndex {
    if (!self.memberListGuild || self.memberListGroups.count == 0) return 0;

    NSArray *visibleRows = [self.tableView indexPathsForVisibleRows];
    if (visibleRows.count == 0) return 0;

    NSIndexPath *middle = [visibleRows objectAtIndex:(visibleRows.count / 2)];
    NSUInteger absoluteIndex = [self absoluteMemberListIndexForIndexPath:middle];
    return absoluteIndex == NSNotFound ? 0 : absoluteIndex;
}

- (void)beginMemberListRefreshCycle {
    if (!self.memberListVisible || !self.memberListGuild || !self.memberListChannelID.length) return;

    [self cancelPendingMemberListWork];

    self.desiredMemberListRanges = nil;
    self.sentMemberListRanges = nil;
    self.memberListRefreshRetryCount = 0;

    // Channel entry already sends Discord's baseline subscription. Give that
    // response a brief head start, then request the currently visible ranges.
    self.lastMemberListSubscriptionDate = [NSDate date];
    NSUInteger absoluteIndex = [self preferredMemberListRefreshAbsoluteIndex];
    [self queueMemberListSubscriptionAroundAbsoluteIndex:absoluteIndex immediate:NO];
}

- (BOOL)memberListHasMissingVisibleRowsReturningIndex:(NSUInteger *)missingIndex {
    if (!self.memberListGuild) return NO;
    if (self.memberListGroups.count == 0) {
        if (missingIndex) *missingIndex = 0;
        return YES;
    }

    NSArray *visibleRows = [self.tableView indexPathsForVisibleRows];
    if (visibleRows.count == 0) return NO;

    for (NSIndexPath *indexPath in visibleRows) {
        NSUInteger absoluteIndex = [self absoluteMemberListIndexForIndexPath:indexPath];
        id item = [self memberListItemAtIndexPath:indexPath];
        if (item && ![self memberListAbsoluteIndexIsStale:absoluteIndex]) continue;
        if (missingIndex) *missingIndex = absoluteIndex == NSNotFound ? 0 : absoluteIndex;
        return YES;
    }
    return NO;
}

- (void)scheduleMemberListRefreshVerification {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(verifyMemberListRefresh)
                                               object:nil];
    if (!self.memberListVisible || !self.memberListGuild) return;
    [self performSelector:@selector(verifyMemberListRefresh)
               withObject:nil
               afterDelay:DCMemberListRefreshCheckDelay];
}

- (void)verifyMemberListRefresh {
    if (!self.memberListVisible || !self.memberListGuild || !self.memberListChannelID.length) return;

    NSUInteger missingIndex = 0;
    if (![self memberListHasMissingVisibleRowsReturningIndex:&missingIndex]) {
        self.memberListRefreshRetryCount = 0;
        return;
    }

    if (self.memberListRefreshRetryCount >= DCMemberListMaximumRefreshRetries) {
        DBGLOG(@"[MemberList] Visible range still incomplete after %lu retries",
               (unsigned long)self.memberListRefreshRetryCount);
        return;
    }

    self.memberListRefreshRetryCount++;
    self.desiredMemberListRanges = nil;
    self.sentMemberListRanges = nil;
    [self queueMemberListSubscriptionAroundAbsoluteIndex:missingIndex immediate:NO];
}

#pragma mark - Member list subscriptions

- (NSArray *)memberListRangesAroundAbsoluteIndex:(NSUInteger)absoluteIndex {
    NSUInteger streamLength = [self memberListStreamLength];
    NSUInteger page = absoluteIndex / DCMemberListPageSize;

    NSMutableArray *pages = [NSMutableArray arrayWithObject:@0];
    if (page > 0) [pages addObject:@(page)];

    NSUInteger pageOffset = absoluteIndex % DCMemberListPageSize;
    BOOL shouldPrefetchNext = page > 0 ||
        pageOffset >= (DCMemberListPageSize - DCMemberListPrefetchThreshold);
    if (shouldPrefetchNext) {
        NSUInteger nextPage = page + 1;
        NSUInteger nextStart = nextPage * DCMemberListPageSize;
        if (streamLength == 0 || nextStart < streamLength) {
            NSNumber *pageNumber = @(nextPage);
            if (![pages containsObject:pageNumber]) [pages addObject:pageNumber];
        }
    }

    NSMutableArray *ranges = [NSMutableArray arrayWithCapacity:pages.count];
    for (NSNumber *pageNumber in pages) {
        NSUInteger first = [pageNumber unsignedIntegerValue] * DCMemberListPageSize;
        [ranges addObject:@[ @(first), @(first + DCMemberListPageSize - 1) ]];
    }
    return ranges;
}

- (void)queueMemberListSubscriptionAroundAbsoluteIndex:(NSUInteger)absoluteIndex
                                              immediate:(BOOL)immediate {
    if (!self.memberListVisible || !self.memberListGuild || !self.memberListChannelID.length) return;

    NSArray *ranges = [self memberListRangesAroundAbsoluteIndex:absoluteIndex];
    if ([ranges isEqualToArray:self.desiredMemberListRanges] ||
        [ranges isEqualToArray:self.sentMemberListRanges]) {
        return;
    }

    self.desiredMemberListRanges = ranges;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(flushMemberListSubscription)
                                               object:nil];
    if (immediate) {
        [self flushMemberListSubscription];
    } else {
        [self performSelector:@selector(flushMemberListSubscription)
                   withObject:nil
                   afterDelay:0.20];
    }
}

- (void)flushMemberListSubscription {
    if (!self.memberListVisible || !self.memberListGuild || !self.memberListChannelID.length) return;
    if (!self.desiredMemberListRanges ||
        [self.desiredMemberListRanges isEqualToArray:self.sentMemberListRanges]) {
        return;
    }

    if (self.lastMemberListSubscriptionDate) {
        NSTimeInterval elapsed = -[self.lastMemberListSubscriptionDate timeIntervalSinceNow];
        if (elapsed < DCMemberListMinimumSubscriptionInterval) {
            NSTimeInterval delay = DCMemberListMinimumSubscriptionInterval - elapsed;
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(flushMemberListSubscription)
                                                       object:nil];
            [self performSelector:@selector(flushMemberListSubscription)
                       withObject:nil
                       afterDelay:delay];
            return;
        }
    }

    NSArray *ranges = [self.desiredMemberListRanges copy];
    [DCServerCommunicator.sharedInstance
        sendGuildMemberListSubscriptionWithGuildId:self.memberListGuild.snowflake
                                          channelId:self.memberListChannelID
                                             ranges:ranges];
    self.sentMemberListRanges = ranges;
    self.lastMemberListSubscriptionDate = [NSDate date];
    [self scheduleMemberListRefreshVerification];
}

#pragma mark - Notifications

- (void)selectedChannelChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self selectedChannelChanged:notification];
        });
        return;
    }

    if (!self.memberListVisible) return;

    [self configureForSelectedChannel];
    [self.tableView reloadData];

    if (self.memberListGuild && self.memberListChannelID.length > 0) {
        [self beginMemberListRefreshCycle];
    }
}

- (void)memberListChannelEntered:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self memberListChannelEntered:notification];
        });
        return;
    }

    NSDictionary *userInfo = notification.userInfo;
    NSString *guildID = [userInfo objectForKey:@"guild_id"];
    NSString *channelID = [userInfo objectForKey:@"channel_id"];
    DCChannel *selectedChannel = DCServerCommunicator.sharedInstance.selectedChannel;

    if (!self.memberListVisible || !selectedChannel ||
        ![selectedChannel.snowflake isEqualToString:channelID] ||
        ![selectedChannel.parentGuild.snowflake isEqualToString:guildID]) {
        return;
    }

    [self configureForSelectedChannel];
    [self.tableView reloadData];
    [self beginMemberListRefreshCycle];
}

- (void)guildMemberListUpdated:(NSNotification *)notification {
    DCChannel *channel = DCServerCommunicator.sharedInstance.selectedChannel;
    if (!channel) return;

    if (!channel.parentGuild.snowflake.length) {
        NSString *channelID = [channel.snowflake copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            DCChannel *current = DCServerCommunicator.sharedInstance.selectedChannel;
            if (!self.memberListVisible ||
                ![current.snowflake isEqualToString:channelID] ||
                current.parentGuild.snowflake.length) return;
            [self configureForSelectedChannel];
            [self.tableView reloadData];
        });
        return;
    }

    DCGuild *updatedGuild = [notification.object isKindOfClass:[DCGuild class]]
        ? (DCGuild *)notification.object : channel.parentGuild;
    if (![updatedGuild.snowflake isEqualToString:channel.parentGuild.snowflake]) return;

    NSDictionary *updateInfo = notification.userInfo;
    BOOL materialSync = [[updateInfo objectForKey:@"material_sync"] boolValue];
    BOOL invalidated = [[updateInfo objectForKey:@"invalidated"] boolValue];
    NSString *guildID = [channel.parentGuild.snowflake copy];
    NSString *channelID = [channel.snowflake copy];
    NSUInteger generation = self.memberListGeneration;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isMemberListContextCurrentForGeneration:generation
                                                    guildID:guildID
                                                  channelID:channelID]) {
            DBGLOG(@"[MemberListGuard] ignored stale update generation=%lu guild=%@ channel=%@",
                   (unsigned long)generation, guildID, channelID);
            return;
        }

        NSArray *oldGroups = self.memberListGroups;
        [self configureForSelectedChannel];
        if (![self isMemberListContextCurrentForGeneration:generation
                                                    guildID:guildID
                                                  channelID:channelID]) return;

        BOOL structureChanged = ![oldGroups isEqualToArray:self.memberListGroups];
        if (structureChanged) {
            [self.tableView reloadData];
        } else {
            NSArray *visible = [self safeVisibleIndexPathsForReload];
            if (visible.count > 0) {
                [self.tableView reloadRowsAtIndexPaths:visible
                                      withRowAnimation:UITableViewRowAnimationNone];
            }
        }

        if (materialSync) {
            NSUInteger missingIndex = 0;
            if (![self memberListHasMissingVisibleRowsReturningIndex:&missingIndex]) {
                self.memberListRefreshRetryCount = 0;
                [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                         selector:@selector(verifyMemberListRefresh)
                                                           object:nil];
            } else {
                [self scheduleMemberListRefreshVerification];
            }
        } else if (invalidated) {
            [self scheduleMemberListRefreshVerification];
        }
    });
}

- (void)handleReloadUser:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleReloadUser:notification];
        });
        return;
    }

    if (!self.memberListVisible) return;

    DCUser *user = notification.object;
    if (!user) return;

    if (!self.memberListGuild) {
        NSUInteger index = [self.recipients indexOfObjectPassingTest:^BOOL(DCUser *recipient, NSUInteger idx, BOOL *stop) {
            return recipient == user ||
                (recipient.snowflake.length > 0 &&
                 [recipient.snowflake isEqualToString:user.snowflake]);
        }];
        if (index == NSNotFound) return;
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
        if (index < (NSUInteger)[self.tableView numberOfRowsInSection:0]) {
            if (indexPath.section < [self.tableView numberOfSections] &&
                indexPath.row < [self.tableView numberOfRowsInSection:indexPath.section]) {
                [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
            }
        }
        return;
    }

    for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
        DCUser *visibleUser = [self memberListItemAtIndexPath:indexPath];
        if (![visibleUser isKindOfClass:[DCUser class]]) continue;
        if (visibleUser == user || [visibleUser.snowflake isEqualToString:user.snowflake]) {
            if (indexPath.section < [self.tableView numberOfSections] &&
                indexPath.row < [self.tableView numberOfRowsInSection:indexPath.section]) {
                [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
            }
        }
    }
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (!self.memberListGuild) return 1;
    return self.memberListGroups.count > 0 ? self.memberListGroups.count : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!DCServerCommunicator.sharedInstance.selectedChannel) return 0;
    if (!self.memberListGuild) return self.recipients.count;
    if (self.memberListGroups.count == 0) return 1;
    if (section >= (NSInteger)self.memberListGroups.count) return 0;
    return [[[self.memberListGroups objectAtIndex:section] objectForKey:@"count"] integerValue];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (!self.memberListGuild || self.memberListGroups.count == 0) return 0.01f;
    return 22.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (!self.memberListGuild || self.memberListGroups.count == 0 ||
        section >= (NSInteger)self.memberListGroups.count) {
        return nil;
    }

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 22.0f)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.backgroundColor = [UIColor colorWithWhite:0.13f alpha:0.96f];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, tableView.bounds.size.width - 20, 22.0f)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.backgroundColor = [UIColor clearColor];
    label.textColor = [UIColor colorWithWhite:1.0f alpha:0.55f];
    label.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:12.0f];
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0, 1);
    label.text = [self titleForMemberListGroup:[self.memberListGroups objectAtIndex:section]];
    [header addSubview:label];
    return header;
}

- (UITableViewCell *)loadingMemberCellForTableView:(UITableView *)tableView {
    DCRecipientTableCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Members cell"];
    if (!cell) {
        cell = [[DCRecipientTableCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:@"Members cell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
    cell.userName.text = @"Loading Members…";
    cell.userName.textColor = [UIColor colorWithWhite:1.0f alpha:0.45f];
    cell.userPFP.image = nil;
    cell.statusLight.hidden = YES;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.memberListGuild && self.memberListGroups.count == 0) {
        return [self loadingMemberCellForTableView:tableView];
    }

    id item = nil;
    if (self.memberListGuild) {
        NSUInteger absoluteIndex = [self absoluteMemberListIndexForIndexPath:indexPath];
        item = [self memberListItemAtIndexPath:indexPath];
        if (![item isKindOfClass:[DCUser class]]) {
            if (absoluteIndex != NSNotFound) {
                [self queueMemberListSubscriptionAroundAbsoluteIndex:absoluteIndex immediate:NO];
            }
            return [self loadingMemberCellForTableView:tableView];
        }
        if ([self memberListAbsoluteIndexIsStale:absoluteIndex]) {
            [self queueMemberListSubscriptionAroundAbsoluteIndex:absoluteIndex immediate:NO];
        }
    } else if (indexPath.row < (NSInteger)self.recipients.count) {
        item = [self.recipients objectAtIndex:indexPath.row];
    }

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"]) {
        DCRecipientTableCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Members cell"];
        if (!cell) {
            NSCAssert(NO, @"Failed to dequeue DCRecipientTableCell");
            abort();
        }

        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.userInteractionEnabled = YES;
        DCUser *user = [item isKindOfClass:[DCUser class]] ? (DCUser *)item : nil;
        if (!user) return [self loadingMemberCellForTableView:tableView];

        DCGuild *guild = self.memberListGuild ?: DCServerCommunicator.sharedInstance.selectedChannel.parentGuild;
        cell.userName.text = [user displayNameInGuild:guild];
        cell.userName.textColor = [DCInterfaceStyle roleColorForUser:user inGuild:guild];

        UIImage *avatar = [DCTools cachedUserAvatar:user inGuild:guild];
        if (avatar && avatar.size.width > 0) {
            cell.userPFP.image = avatar;
        } else {
            cell.userPFP.image = user.profileImage;
            [DCTools getUserAvatar:user inGuild:guild];
        }

        if (guild.snowflake.length > 0) {
            cell.statusLight.hidden = NO;
            cell.statusLight.image = [DCInterfaceStyle statusImageForStatus:user.status];
        } else {
            cell.statusLight.hidden = YES;
        }
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Members Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Members Cell"];
    }
    DCUser *user = [item isKindOfClass:[DCUser class]] ? (DCUser *)item : nil;
    cell.textLabel.text = user ? user.username : @"Loading Members…";
    cell.selectionStyle = user ? UITableViewCellSelectionStyleGray : UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = user != nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
                                    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.memberListGuild || self.memberListGroups.count == 0) return;
    NSUInteger absoluteIndex = [self absoluteMemberListIndexForIndexPath:indexPath];
    if (absoluteIndex == NSNotFound) return;

    NSUInteger pageOffset = absoluteIndex % DCMemberListPageSize;
    id item = [self memberListItemAtIndexPath:indexPath];
    BOOL stale = [self memberListAbsoluteIndexIsStale:absoluteIndex];
    if (!item || stale || pageOffset >= (DCMemberListPageSize - DCMemberListPrefetchThreshold)) {
        [self queueMemberListSubscriptionAroundAbsoluteIndex:absoluteIndex immediate:NO];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    id item = self.memberListGuild
        ? [self memberListItemAtIndexPath:indexPath]
        : (indexPath.row < (NSInteger)self.recipients.count
            ? [self.recipients objectAtIndex:indexPath.row] : nil);

    if (![item isKindOfClass:[DCUser class]]) {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        return;
    }

    self.selectedUser = (DCUser *)item;
    [self performSegueWithIdentifier:@"channelinfo to contact" sender:self];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[DCContactViewController class]]) {
        DCContactViewController *contactVC = (DCContactViewController *)segue.destinationViewController;
        contactVC.selectedUser = self.selectedUser;
    }
}

@end
