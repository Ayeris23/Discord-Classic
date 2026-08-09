//
//  DCMenuViewController.m
//  Discord Classic
//
//  Created by bag.xml on 27/01/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCMenuViewController.h"
#include "DCTools.h"
#include <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
#include <UIKit/UIKit.h>
#include <dispatch/dispatch.h>
#include <objc/NSObjCRuntime.h>
#include "DCGuild.h"
#include "DCGuildFolder.h"
#include "DCServerCommunicator.h"
#include "DCUser.h"
#import "MentionBadge.h"
#import "DCContentManager.h"
#import "DCCacheManager.h"

@interface DCMenuViewController ()
@property NSMutableArray *displayGuilds;
@property DCChannel *optionChannel;
@property (assign, nonatomic) BOOL shouldAttemptColdChatRestore;
@property (assign, nonatomic) BOOL coldChatRestoreAlreadyHandled;
@property (strong, nonatomic) NSMutableSet *folderIconHydrationRequests;
@end

@implementation DCMenuViewController

- (BOOL)isDirectMessagesGuild:(DCGuild *)guild {
    return guild && guild.snowflake == nil &&
           [guild.name isEqualToString:@"Direct Messages"];
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

    NSString *guildName = guild.name ?: @"Discord";
    [self.navigationItem setTitle:guildName];
    self.guildLabel.text = guildName;

    if ([self isDirectMessagesGuild:guild]) {
        [guild.channels sortUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
            NSString *idA = ([a.lastMessageId isKindOfClass:[NSString class]]) ? a.lastMessageId : @"0";
            NSString *idB = ([b.lastMessageId isKindOfClass:[NSString class]]) ? b.lastMessageId : @"0";
            return [idB localizedStandardCompare:idA];
        }];

        self.totalView.hidden = NO;
        self.userName.text = DCServerCommunicator.sharedInstance.currentUserInfo.globalName;
        self.globalName.text = [NSString stringWithFormat:@"@%@",
                                DCServerCommunicator.sharedInstance.currentUserInfo.username ?: @""];
        self.guildTotalView.hidden = YES;
        self.guildBanner.image = [UIImage imageNamed:@"No-Header"];
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
        self.guildBanner.image = guild.banner ?: [UIImage imageNamed:@"No-Header"];
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
                                           selector:@selector(handleReady)
                                               name:@"MENTION_COUNT_UPDATED"
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
        setBackgroundImage:[UIImage imageNamed:@"TbarBG"]
             forBarMetrics:UIBarMetricsDefault];

    self.experimentalMode =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"experimentalMode"];
    self.totalView.hidden = YES;

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleLongPress:)];
    longPress.minimumPressDuration          = 0.5; // seconds
    [self.channelTableView addGestureRecognizer:longPress];
}

- (void)viewDidUnload {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    // nil IBOutlets
    self.guildTableView = nil;
    self.channelTableView = nil;
    self.refreshControl = nil;
    // ... nil any other IBOutlets
    [super viewDidUnload];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint point          = [gestureRecognizer locationInView:self.channelTableView];
        NSIndexPath *indexPath = [self.channelTableView indexPathForRowAtPoint:point];
        if (!indexPath) {
            return;
        }
        DCChannel *channelAtRowIndex = [self.selectedGuild.channels objectAtIndex:indexPath.row];
        if (!channelAtRowIndex) {
            return;
        }
        self.optionChannel = channelAtRowIndex;

        UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:channelAtRowIndex.name
                                                                 delegate:self
                                                        cancelButtonTitle:@"Okay"
                                                   destructiveButtonTitle:nil
                                                        otherButtonTitles:@"Copy Channel ID",
                                                                          nil];

        actionSheet.tag = 2;
        [actionSheet showInView:self.view.superview ? self.view.superview : self.view];
    }
}

// Cold-launch fallback. The normal Phase 5 path is restored by the app
// delegate before first presentation using the storyboard's chat identifier.
// This remains only for a cache miss where READY later discovers the channel.
- (void)attemptColdChatRestoreIfNeeded {
    if (!self.shouldAttemptColdChatRestore) return;

    NSString *channelID =
        [[DCCacheManager sharedInstance] loadLastActiveChatChannelID];

    if (channelID.length == 0) {
        self.shouldAttemptColdChatRestore = NO;
        return;
    }

    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in guild.channels) {
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

// block that handles what the app does if you open it via a push ntoification

- (void)handleNotificationTap:(NSNotification *)notification {
    NSString *channelId = notification.userInfo[@"channelId"];
    if (channelId) {
        // NSLog(@"Navigating to channel with ID: %@", channelId);
        [self navigateToChannelWithId:channelId];
    }
}

- (void)exitedChatController {
    // NSLog(@"EXITING CHAT VIEW");
    self.selectedChannel = nil;
}

- (void)navigateToChannelWithId:(NSString *)channelId {
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in guild.channels) {
            if (![channel.snowflake isEqualToString:channelId]) {
                continue;
            }
            // NSLog(@"channel id: %@", channelId);
            if (self.selectedChannel &&
                [self.selectedChannel.snowflake
                    isEqualToString:channelId]) {
                // NSLog(@"ok");
                return;
            }
            self.selectedGuild                                  = guild;
            self.selectedChannel                                = channel;
            DCServerCommunicator.sharedInstance.selectedChannel = channel;

            dispatch_async(dispatch_get_main_queue(), ^{
                [self performSegueWithIdentifier:@"guilds to chat"
                                          sender:self];
            });
            return;
        }
    }
}
// end of block

// reload
- (void)handleReady {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Refresh selectedGuild pointer if it's the DM guild, or recover if a
        // live GUILD_DELETE removed the guild currently shown in the channel pane.
        BOOL selectedGuildStillExists = NO;
        if (self.selectedGuild) {
            for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
                if (guild == self.selectedGuild ||
                    (guild.snowflake && [guild.snowflake isEqualToString:self.selectedGuild.snowflake])) {
                    self.selectedGuild = guild;
                    selectedGuildStillExists = YES;
                    break;
                }
            }
        }
        if (!selectedGuildStillExists && DCServerCommunicator.sharedInstance.guilds.count) {
            self.selectedGuild = [DCServerCommunicator.sharedInstance.guilds objectAtIndex:0];
            self.selectedChannel = nil;
            DCServerCommunicator.sharedInstance.selectedGuild = self.selectedGuild;
        }

        if (self.selectedGuild) {
            [self.navigationItem setTitle:self.selectedGuild.name];
            self.guildLabel.text = self.selectedGuild.name;
            self.guildBanner.image = self.selectedGuild.banner ?: [UIImage imageNamed:@"No-Header"];
        }

        [self.guildTableView reloadData];
        [self.channelTableView reloadData];

        if (!self.refreshControl) {
            self.refreshControl = UIRefreshControl.new;

            self.refreshControl.attributedTitle =
                [[NSAttributedString alloc] initWithString:@"Reload"];

            [self.guildTableView addSubview:self.refreshControl];

            [self.refreshControl addTarget:self
                                    action:@selector(reconnect)
                          forControlEvents:UIControlEventValueChanged];
        }

        [self attemptColdChatRestoreIfNeeded];
    });
}

- (void)handleChannelContextChanged:(NSNotification *)notification {
    NSString *channelId = notification.userInfo[@"channelId"];
    if (!channelId) return;
    
    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
        for (DCChannel *channel in guild.channels) {
            if (![channel.snowflake isEqualToString:channelId]) continue;
            
            self.selectedGuild = guild;
            self.selectedChannel = channel;
            DCServerCommunicator.sharedInstance.selectedGuild = guild;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationItem setTitle:guild.name];
                self.guildLabel.text = guild.name;
                [self.channelTableView reloadData];
            });
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
            self.selectedGuild = guild;
            DCServerCommunicator.sharedInstance.selectedGuild = guild;
            [self.navigationItem setTitle:guild.name];
            self.guildLabel.text = guild.name;
            if (self.selectedGuild.banner) {
                self.guildBanner.image = self.selectedGuild.banner;
            } else {
                self.guildBanner.image = [UIImage imageNamed:@"No-Header"];
            }
            [self.channelTableView reloadData];
        });
        return;
    }
}

- (void)reloadGuild:(NSNotification *)notification {
    assertMainThread();
    DCGuild *guild = notification.object;
    if (guild == nil) return;

    // A folder-cache miss may have lazily requested this guild icon. A normal
    // RELOAD GUILD means the runtime asset/state changed, so allow future
    // recovery attempts and let the folder row reevaluate its composite key.
    if (guild.snowflake.length)
        [self.folderIconHydrationRequests removeObject:guild.snowflake];

    // Keep the selected-guild chrome synchronized with surgical GUILD_UPDATE
    // events without needing a full READY-style table rebuild.
    if (self.selectedGuild == guild ||
        (self.selectedGuild.snowflake &&
         [self.selectedGuild.snowflake isEqualToString:guild.snowflake])) {
        self.selectedGuild = guild;
        [self.navigationItem setTitle:guild.name];
        self.guildLabel.text = guild.name;
        self.guildBanner.image = guild.banner ?: [UIImage imageNamed:@"No-Header"];
    }

    if (self.displayGuilds == nil) {
        return;
    }

    if (self.selectedGuild == guild ||
        (self.selectedGuild.snowflake.length &&
         [self.selectedGuild.snowflake isEqualToString:guild.snowflake])) {
        if (![self isDirectMessagesGuild:guild]) {
            self.guildBanner.image = guild.banner ?: [UIImage imageNamed:@"No-Header"];
        }
    }

    if (!DCServerCommunicator.sharedInstance.guildsIsSorted) {
        return;
    }
    
    // Guard against count mismatch — fall back to full reload
    if (self.displayGuilds.count != [self.guildTableView numberOfRowsInSection:0]) {
        [self.guildTableView reloadData];
        return;
    }

    // Collect index paths to reload before touching the table
    NSMutableArray *indexPaths = [NSMutableArray array];

    NSUInteger folderIdx = [self.displayGuilds
        indexOfObjectPassingTest:^BOOL(DCGuildFolder *folder, NSUInteger idx, BOOL *stop) {
            return [folder isKindOfClass:[DCGuildFolder class]]
                && [folder.guildIds indexOfObject:guild.snowflake] < 4;
        }];
    if (folderIdx != NSNotFound) {
        [indexPaths addObject:[NSIndexPath indexPathForRow:folderIdx inSection:0]];
    }

    NSUInteger index = [self.displayGuilds indexOfObject:guild];
    if (index != NSNotFound) {
        [indexPaths addObject:[NSIndexPath indexPathForRow:index inSection:0]];
    }

    // Only touch the table if we actually have something to reload
    if (indexPaths.count == 0) {
        return;
    }

    [self.guildTableView beginUpdates];
    [self.guildTableView reloadRowsAtIndexPaths:indexPaths
                               withRowAnimation:UITableViewRowAnimationNone];
    [self.guildTableView endUpdates];
}

- (void)updateStatusForUser:(DCUser *)updatedUser {
    assertMainThread();
    if (!updatedUser || ![updatedUser isKindOfClass:[DCUser class]] ||
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

    NSUInteger idx = [privateGuild.channels
        indexOfObjectPassingTest:^BOOL(DCChannel *chan, NSUInteger row, BOOL *stop) {
            if (chan.type != DCChannelTypeDM || chan.recipients.count != 1)
                return NO;
            DCUser *buddy = [chan.recipients objectAtIndex:0];
            return [buddy.snowflake isEqualToString:updatedUser.snowflake];
        }];
    if (idx == NSNotFound) return;

    // If the DM list is not currently visible there is nothing to redraw now;
    // cellForRowAtIndexPath: will read the canonical user's status later.
    if (![self isDirectMessagesGuild:self.selectedGuild] ||
        idx >= (NSUInteger)[self.channelTableView numberOfRowsInSection:0])
        return;

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:idx inSection:0];
    [self.channelTableView reloadRowsAtIndexPaths:@[ indexPath ]
                                 withRowAnimation:UITableViewRowAnimationNone];
}

- (void)reloadTable {
    [self handleMessageAck:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.reloadControl endRefreshing];
    });
}

- (void)reconnect {
    [DCServerCommunicator.sharedInstance reconnect];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.refreshControl endRefreshing];
    });
}

// reload end
// misc
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (void)handleMessageAck:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.guildTableView reloadData];
        
        // Only reload channel table if the message is in the currently displayed guild
        NSString *channelId = notification.userInfo[@"channelId"];
        if (channelId && self.selectedGuild) {
            BOOL channelInSelectedGuild = NO;
            for (DCChannel *channel in self.selectedGuild.channels) {
                if ([channel.snowflake isEqualToString:channelId]) {
                    channelInSelectedGuild = YES;
                    break;
                }
            }
            // Also reload if it's a DM channel list
            DCChannel *incomingChannel = [DCServerCommunicator.sharedInstance.channels objectForKey:channelId];
            BOOL isDMChannel = (incomingChannel && (incomingChannel.type == 1 || incomingChannel.type == 3));

            if (channelInSelectedGuild || isDMChannel) {
                // Re-sort DM list if we're viewing Direct Messages
                if ([self isDirectMessagesGuild:self.selectedGuild]) {
                    [self.selectedGuild.channels sortUsingComparator:^NSComparisonResult(DCChannel *a, DCChannel *b) {
                        NSString *idA = ([a.lastMessageId isKindOfClass:[NSString class]]) ? a.lastMessageId : @"0";
                        NSString *idB = ([b.lastMessageId isKindOfClass:[NSString class]]) ? b.lastMessageId : @"0";
                        return [idB localizedStandardCompare:idA];
                    }];
                }
                [self.channelTableView reloadData];
            }
        } else {
            // No channel info, reload both to be safe
            [self.channelTableView reloadData];
        }
    });
}

// Keep the menu's visible chrome derived from the selected guild model.
// This matters on direct cold-chat restoration because the menu view is not
// loaded until the user taps Back; its storyboard labels may still contain
// their default Direct Messages text at that point.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self synchronizeSelectedGuildUI];
    [self.guildTableView reloadData];
    [self.channelTableView reloadData];
}

// misc end
- (IBAction)moreInfo:(id)sender {
    UIActionSheet *messageActionSheet =
        [[UIActionSheet alloc] initWithTitle:self.selectedGuild.name
                                    delegate:self
                           cancelButtonTitle:@"Okay"
                      destructiveButtonTitle:nil
                           otherButtonTitles:self.selectedGuild ? @"Copy Guild ID" : nil,
                                             nil];
    messageActionSheet.tag      = 1;
    messageActionSheet.delegate = self;
    [messageActionSheet showInView:self.view.superview ? self.view.superview : self.view];
}

- (void)actionSheet:(UIActionSheet *)popup
    clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (popup.tag == 1) {
        switch (buttonIndex) {
            case 0: {
                if (!self.selectedGuild) {
                    break; // No guild selected
                }
                // Copy guild ID
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string        = self.selectedGuild.snowflake;
                break;
            }
            default: {
                break;
            }
        }
    } else if (popup.tag == 2) {
        switch (buttonIndex) {
            case 0: {
                if (!self.optionChannel) {
                    break; // No channel selected
                }
                // Copy channel ID
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string        = self.optionChannel.snowflake;
                break;
            }
            default: {
                break;
            }
        }
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
            id selectedGuild = [self.displayGuilds objectAtIndex:indexPath.row];
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            if ([selectedGuild isKindOfClass:[DCGuildFolder class]]) {
                // NSLog(@"Folder selected: %@", selectedGuild);
                DCGuildFolder *folder           = selectedGuild;
                folder.opened                   = !folder.opened;
                NSDictionary *constFolderDict   = [[NSUserDefaults standardUserDefaults]
                    dictionaryForKey:[@(folder.id) stringValue]];
                NSMutableDictionary *folderDict = constFolderDict ? [constFolderDict mutableCopy] : [NSMutableDictionary dictionary];
                [folderDict setValue:[NSNumber numberWithBool:folder.opened] forKey:@"opened"];
                [[NSUserDefaults standardUserDefaults] setObject:folderDict
                                                          forKey:[@(folder.id) stringValue]];
                [[NSUserDefaults standardUserDefaults] synchronize];
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
                        // NSLog(@"add index: %lu, name: %@", (unsigned long)curIdx, guild.name);
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
                        // DCGuild *guild = [DCServerCommunicator.sharedInstance.guilds
                        //     objectAtIndex:[DCServerCommunicator.sharedInstance.guilds indexOfObjectPassingTest:^BOOL(DCGuild *g, NSUInteger idx, BOOL *stop) {
                        //         return [g.snowflake isEqualToString:folder.guildIds[i]];
                        //     }]];
                        // NSLog(@"remove index: %lu, name: %@", (unsigned long)(idx + i), guild.name);
                        [self.displayGuilds removeObjectAtIndex:idx];
                        [indexPathsToDelete addObject:[NSIndexPath indexPathForRow:idx + i inSection:0]];
                    }}
                    NSAssert(indexPathsToDelete.count == folder.guildIds.count, @"Index paths to delete count does not match folder guild IDs count (%@ != %@)", @(indexPathsToDelete.count), @(folder.guildIds.count));
                    [self.guildTableView deleteRowsAtIndexPaths:indexPathsToDelete withRowAnimation:UITableViewRowAnimationAutomatic];
                }
                [self.guildTableView endUpdates];
                return;
            }
            self.selectedGuild = selectedGuild;

            // Always route a guild-table selection through the same model-driven
            // synchronization path used by cold restore/viewWillAppear. Besides
            // updating the chrome and communicator selection, this is the
            // tap-time banner failsafe: if the guild has a persisted banner hash
            // but no runtime UIImage yet, synchronizeSelectedGuildUI asks the
            // normal SDWebImage-backed banner loader to materialize it.
            [self synchronizeSelectedGuildUI];

            @autoreleasepool {
                [self.channelTableView reloadData];
            }
        } else if (tableView == self.channelTableView) {
            if (!self.selectedGuild || !self.selectedGuild.channels || self.selectedGuild.channels.count <= indexPath.row) {
                DBGLOG(@"Selected guild or channels are not set or index out of bounds");
                return;
            }

            DCChannel *channelAtRowIndex =
                [self.selectedGuild.channels objectAtIndex:indexPath.row];

            // If the channel is a category, do nothing
            if (channelAtRowIndex.type == 4) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                return;
            }

            DCServerCommunicator.sharedInstance.selectedChannel = channelAtRowIndex;
            self.selectedChannel                                = channelAtRowIndex;

            [DCServerCommunicator.sharedInstance
                sendGuildSubscriptionWithGuildId:self.selectedGuild.snowflake
                                       channelId:self.selectedChannel.snowflake];

            // Mark channel messages as read and refresh the channel object
            // accordingly
            [DCServerCommunicator.sharedInstance.selectedChannel
                ackMessage:DCServerCommunicator.sharedInstance.selectedChannel
                               .lastMessageId];
            [DCServerCommunicator.sharedInstance.selectedChannel checkIfRead];

            // Remove the blue indicator since the channel has been read
            //[[self.channelTableView cellForRowAtIndexPath:indexPath]
            // setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
            [tableView deselectRowAtIndexPath:indexPath animated:YES];

            if (self.experimentalMode) {
                UINavigationController *navigationController =
                    (UINavigationController *)
                        self.slideMenuController.contentViewController;
                DCChatViewController *contentViewController =
                    navigationController.viewControllers.firstObject;
                if ([contentViewController
                        isKindOfClass:[DCChatViewController class]]) {

                    NSString *formattedChannelName;

                    formattedChannelName = DCServerCommunicator.sharedInstance
                                                   .selectedChannel.name;

                    [contentViewController activateSelectedChannel];

                    [NSNotificationCenter.defaultCenter
                        postNotificationName:@"GuildMemberListUpdated"
                                      object:nil];

                    [self.slideMenuController hideMenu:YES];
                }
            } else {
                [self performSegueWithIdentifier:@"guilds to chat" sender:self];
            }
            //[tableView cellForRowAtIndexPath:indexPath].accessoryType =
            // UITableViewCellAccessoryDisclosureIndicator;
        }
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.channelTableView) {
        DCChannel *channelAtRowIndex =
            [self.selectedGuild.channels objectAtIndex:indexPath.row];
        if (channelAtRowIndex.type == 4) {
            // Category cell height
            return 20.0;
        }
    }
    return tableView.rowHeight;
}

- (NSString *)compositeCacheKeyForFolder:(DCGuildFolder *)folder {
    if (!folder) return nil;
    NSMutableArray *parts = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"v1:%ld", (long)folder.id]];
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
    CGSize size = baseImage.size;

    // Begin image context
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);

    // Draw base image first
    [baseImage drawInRect:CGRectMake(0, 0, size.width, size.height)];

    // Define grid quarters (2x2 grid)
    CGFloat quarterWidth  = size.width / 2.0;
    CGFloat quarterHeight = size.height / 2.0;

    // Icon size relative to quarter
    CGFloat iconScale   = 0.6; // icons are 60% of the quarter size
    CGFloat iconWidth   = quarterWidth * iconScale;
    CGFloat iconHeight  = quarterHeight * iconScale;
    CGFloat iconPadding = 25.0; // icon centering

    // Precompute grid quarter centers
    CGPoint gridCenters[4] = {
        CGPointMake(quarterWidth * 0.5 + iconPadding, quarterHeight * 0.5 + iconPadding), // Top-left
        CGPointMake(quarterWidth * 1.5 - iconPadding, quarterHeight * 0.5 + iconPadding), // Top-right
        CGPointMake(quarterWidth * 0.5 + iconPadding, quarterHeight * 1.5 - iconPadding), // Bottom-left
        CGPointMake(quarterWidth * 1.5 - iconPadding, quarterHeight * 1.5 - iconPadding)  // Bottom-right
    };

    // Draw each icon centered in its grid quarter
    for (NSUInteger i = 0; i < icons.count; i++) {
        id iconObj = icons[i];

        if (iconObj == nil || ![iconObj isKindOfClass:[UIImage class]]) {
            continue; // Skip this icon
        }

        UIImage *icon = iconObj;

        // Compute rect so icon is centered in its quarter
        CGPoint center = gridCenters[i];
        CGRect rect    = CGRectMake(center.x - iconWidth / 2.0, center.y - iconHeight / 2.0, iconWidth, iconHeight);

        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSaveGState(context);

        // Clip with rounded corners
        UIBezierPath *clipPath = [UIBezierPath bezierPathWithRoundedRect:rect
                                                            cornerRadius:iconWidth / 6.0];
        [clipPath addClip];

        [icon drawInRect:rect];

        CGContextRestoreGState(context);
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
        @autoreleasepool {
            if ([objectAtRowIndex isKindOfClass:[DCGuild class]]) {
                DCGuild *guildAtRowIndex = objectAtRowIndex;

                // Show blue indicator if guild has any unread messages
                cell.unreadMessages.hidden = !guildAtRowIndex.unread;

                cell.mentionBadge.mentionCount = guildAtRowIndex.mentionCount;
                if (guildAtRowIndex.mentionCount > 0) {
                    cell.unreadMessages.hidden = NO;
                    CGSize badgeSize = [cell.mentionBadge sizeThatFits:CGSizeZero];
                    CGRect avatarFrame = cell.guildAvatar.frame;
                    cell.mentionBadge.frame = CGRectMake(
                        avatarFrame.origin.x + avatarFrame.size.width - badgeSize.width + 8,
                        avatarFrame.origin.y + avatarFrame.size.height - badgeSize.height + 8,
                        badgeSize.width, badgeSize.height
                    );
                }

                // Guild name and icon
                if (guildAtRowIndex.icon) {
                    cell.guildAvatar.image = guildAtRowIndex.icon;
                }

                cell.guildAvatar.layer.cornerRadius =
                    cell.guildAvatar.frame.size.width / 6.0;
                cell.guildAvatar.layer.masksToBounds = YES;
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
                
                cell.mentionBadge.mentionCount = folderMentionCount;
                if (folderMentionCount > 0) {
                    CGSize badgeSize = [cell.mentionBadge sizeThatFits:CGSizeZero];
                    CGRect avatarFrame = cell.guildAvatar.frame;
                    cell.mentionBadge.frame = CGRectMake(
                        avatarFrame.origin.x + avatarFrame.size.width - badgeSize.width + 8,
                        avatarFrame.origin.y + avatarFrame.size.height - badgeSize.height + 8,
                        badgeSize.width, badgeSize.height
                    );
                }
                
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

                UIImage *folderIcon   = [UIImage imageNamed:@"folder"];
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
                    cell.guildAvatar.image = folderIcon;
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

            NSCAssert(
                self.selectedGuild && self.selectedGuild.channels && self.selectedGuild.channels.count > indexPath.row,
                @"Invalid guild, channel, or index"
            );

            @autoreleasepool {
                DCChannel *channelAtRowIndex =
                    [self.selectedGuild.channels objectAtIndex:indexPath.row];

                NSCAssert((NSNull *)channelAtRowIndex != [NSNull null], @"Channel at row index is NSNull");

                cell.mentionBadge.mentionCount = channelAtRowIndex.mentionCount;
                if (channelAtRowIndex.mentionCount > 0) {
                    cell.unreadMessages.hidden = NO;
                    CGSize badgeSize = [cell.mentionBadge sizeThatFits:CGSizeZero];
                    cell.mentionBadge.frame = CGRectMake(
                        cell.contentView.bounds.size.width - badgeSize.width - 10,
                        (cell.contentView.bounds.size.height - badgeSize.height) / 2 - 1,
                        badgeSize.width, badgeSize.height
                    );
                    cell.nameLabel.frame = CGRectMake(
                        cell.nameLabel.frame.origin.x,
                        cell.nameLabel.frame.origin.y,
                        cell.mentionBadge.frame.origin.x - cell.nameLabel.frame.origin.x - 8,
                        cell.nameLabel.frame.size.height
                    );
                } else {
                    cell.unreadMessages.hidden = !channelAtRowIndex.unread;
                    cell.nameLabel.frame = CGRectMake(
                        cell.nameLabel.frame.origin.x,
                        cell.nameLabel.frame.origin.y,
                        cell.contentView.bounds.size.width - cell.nameLabel.frame.origin.x - 10,
                        cell.nameLabel.frame.size.height
                    );
                }
                cell.nameLabel.text = channelAtRowIndex.name;

                if (channelAtRowIndex.type == 1 && channelAtRowIndex.users.count == 2) {
                    DCUser *buddy = [channelAtRowIndex.users firstObject];
                    if (buddy.profileImage && buddy.profileImage.size.width > 0) {
                        cell.pfp.image = buddy.profileImage;
                    } else {
                        cell.pfp.image = channelAtRowIndex.icon;
                    }
                } else if (channelAtRowIndex.icon != nil &&
                           [channelAtRowIndex.icon isKindOfClass:[UIImage class]]) {
                    cell.pfp.image = channelAtRowIndex.icon;
                }

                // Presence indicator logic for DM channels (type 1, one-on-one)
                if (channelAtRowIndex.type == 1
                    && channelAtRowIndex.users.count == 2) {
                    DCUser *buddy = [channelAtRowIndex.users firstObject];

                    // Update the status image based on the buddy's status
                    // DBGLOG(@"Buddy found for DM channel %@ with status: %ld", buddy.username, (long)buddy.status);
                    NSString *statusImageName =
                        [DCMenuViewController imageNameForStatus:buddy.status];
                    cell.statusImage.image =
                        [UIImage imageNamed:statusImageName];

                    cell.statusImage.hidden = NO;
                } else {
                    // Hide status indicator for non-DM or group channels
                    cell.statusImage.hidden = YES;
                }
            }

            return cell;
        } else {
            NSCAssert(self.selectedGuild && self.selectedGuild.channels && self.selectedGuild.channels.count > indexPath.row, @"Invalid guild, channel, or index");

            DCChannel *channelAtRowIndex =
                [self.selectedGuild.channels objectAtIndex:indexPath.row];

            NSCAssert((NSNull *)channelAtRowIndex != [NSNull null], @"Channel at row index is NSNull");

            if (channelAtRowIndex.type == 4) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Category Cell"];
                if (cell == nil) {
                    cell = [[UITableViewCell alloc]
                          initWithStyle:UITableViewCellStyleDefault
                        reuseIdentifier:@"Category Cell"];
                    // make unclickable
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.userInteractionEnabled = NO;
                    cell.textLabel.enabled = NO;
                    cell.textLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:15.0];
                    cell.detailTextLabel.enabled = NO;
                    cell.alpha = 0.5;
                    cell.accessoryType = UITableViewCellAccessoryNone;
                }
                cell.textLabel.text = channelAtRowIndex.name;
                return cell;
            }

            DCChannelViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"channel"];
            if (cell == nil) {
                cell = [[DCChannelViewCell alloc]
                      initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:@"channel"];
            }
            cell.mentionBadge.mentionCount = channelAtRowIndex.mentionCount;
            if (channelAtRowIndex.mentionCount > 0) {
                cell.messageIndicator.hidden = NO;
                CGSize badgeSize = [cell.mentionBadge sizeThatFits:CGSizeZero];
                cell.mentionBadge.frame = CGRectMake(
                    cell.contentView.bounds.size.width - badgeSize.width - 10,
                    (cell.contentView.bounds.size.height - badgeSize.height) / 2 - 1,
                    badgeSize.width, badgeSize.height
                );
                cell.channelName.frame = CGRectMake(
                    cell.channelName.frame.origin.x,
                    cell.channelName.frame.origin.y,
                    cell.mentionBadge.frame.origin.x - cell.channelName.frame.origin.x - 8,
                    cell.channelName.frame.size.height
                );
            } else {
                cell.messageIndicator.hidden = !(channelAtRowIndex.unread && !channelAtRowIndex.muted);
                cell.channelName.frame = CGRectMake(
                    cell.channelName.frame.origin.x,
                    cell.channelName.frame.origin.y,
                    cell.contentView.bounds.size.width - cell.channelName.frame.origin.x - 10,
                    cell.channelName.frame.size.height
                );
            }
            cell.channelName.text = channelAtRowIndex.name;
            cell.channelName.textColor = channelAtRowIndex.unread
                ? [UIColor whiteColor]
                : [UIColor colorWithRed:128.0 / 255.0
                                  green:132.0 / 255.0
                                   blue:143.0 / 255.0
                                  alpha:1.0];
            cell.alpha = channelAtRowIndex.muted ? 0.05 : 1.0;

            return cell;
        }
    }
    NSCAssert(0, @"Unexpected table view type");
    abort();
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForHeaderInSection:(NSInteger)section {
    return (section == 0) ? 0 : 28.0;
}

- (UIView *)tableView:(UITableView *)tableView
    viewForHeaderInSection:(NSInteger)section {
    NSCAssert(section != 0, @"Unexpected section");

    UIView *headerView = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, tableView.frame.size.width, 28)];
    UIImageView *backgroundImageView =
        [[UIImageView alloc] initWithFrame:headerView.bounds];
    backgroundImageView.contentMode = UIViewContentModeScaleToFill;

    UILabel *label  = [[UILabel alloc]
        initWithFrame:CGRectMake(10, 5, tableView.frame.size.width - 20, 18)];
    label.textColor = [UIColor colorWithRed:158.0 / 255.0
                                      green:159.0 / 255.0
                                       blue:159.0 / 255.0
                                      alpha:1.0];

    backgroundImageView.image = [UIImage imageNamed:@"headerSeparator"];
    label.layer.shadowColor   = [UIColor blackColor].CGColor;
    label.layer.shadowOffset  = CGSizeMake(0, 1);
    label.backgroundColor     = [UIColor clearColor];
    label.font                = [UIFont boldSystemFontOfSize:16];


    [headerView addSubview:backgroundImageView];
    if (section == 1) {
        label.text = @"Chats";
    }

    [headerView addSubview:label];
    return headerView;
}


+ (NSString *)imageNameForStatus:(DCUserStatus)status {
    switch (status) {
        case DCUserStatusOnline:
            return @"online";
        case DCUserStatusDoNotDisturb:
            return @"dnd";
        case DCUserStatusIdle:
            return @"absent";
        case DCUserStatusOffline:
        default:
            return @"offline";
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.guildTableView && DCServerCommunicator.sharedInstance.guilds) {
        // Sorting guilds based on userInfo[@"guildPositions"] array
        if (!DCServerCommunicator.sharedInstance.guildsIsSorted) {
            NSUInteger guildCount        = [DCServerCommunicator.sharedInstance.currentUserInfo.guildPositions count] + 1;
            NSMutableArray *sortedGuilds = [NSMutableArray arrayWithCapacity:guildCount];
            NSNull *nullObject           = [NSNull null];
            NSMutableArray *cached = DCServerCommunicator.sharedInstance.cachedDisplayLayout;
                if (cached.count) {
                    self.displayGuilds = cached;
                    DCServerCommunicator.sharedInstance.cachedDisplayLayout = nil;
                    DCServerCommunicator.sharedInstance.guildsIsSorted = YES;
                } else {
                    // init to be able to index
                    for (NSUInteger i = 0; i < guildCount; i++) {
                        [sortedGuilds addObject:nullObject];
                    }
                    for (DCGuild *guild in DCServerCommunicator.sharedInstance.guilds) {
                        NSUInteger index = [DCServerCommunicator.sharedInstance.currentUserInfo.guildPositions indexOfObject:guild.snowflake];
                        if (index != NSNotFound) {
                            [sortedGuilds insertObject:guild atIndex:index + 1];
                        } else if ([[sortedGuilds objectAtIndex:0] isEqual:nullObject]) {
                            // If the first element is still null, must be private guild
                            [sortedGuilds insertObject:(id)guild atIndex:0];
                        } else {
                            // Otherwise, append to the end of the array
                            [sortedGuilds addObject:guild];
                        }
                    }
                    [sortedGuilds removeObjectIdenticalTo:nullObject];
                    NSAssert(sortedGuilds && [sortedGuilds count] != 0, @"No sorted guilds found");
                    DCServerCommunicator.sharedInstance.guilds = sortedGuilds;
                    sortedGuilds                               = [NSMutableArray arrayWithObject:DCServerCommunicator.sharedInstance.guilds[0]]; // Add private guild at index 0
                    NSMutableSet *handledGuildIds = NSMutableSet.new;
                    for (DCGuildFolder *folder in DCServerCommunicator.sharedInstance.currentUserInfo.guildFolders) {
                        if (folder.id) {
                            [sortedGuilds addObject:folder];
                        }
                        if (folder.opened) {
                            NSArray *folderGuilds = [[DCServerCommunicator.sharedInstance.guilds 
                                filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCGuild *guild, NSDictionary *bindings) {
                                    return [folder.guildIds containsObject:guild.snowflake];
                                }]]
                                sortedArrayUsingComparator:^NSComparisonResult(DCGuild *a, DCGuild *b) {
                                    NSUInteger index1 = [folder.guildIds indexOfObject:a.snowflake];
                                    NSUInteger index2 = [folder.guildIds indexOfObject:b.snowflake];
                                    if (index1 < index2) {
                                        return NSOrderedAscending;
                                    } else if (index1 > index2) {
                                        return NSOrderedDescending;
                                    } else {
                                        return NSOrderedSame;
                                    }
                                }];

                            [sortedGuilds addObjectsFromArray:folderGuilds];
                        }
                        [handledGuildIds addObjectsFromArray:folder.guildIds];
                    }
                    NSMutableArray *origCopy = [[[DCServerCommunicator.sharedInstance.guilds reverseObjectEnumerator] allObjects] mutableCopy];
                    [origCopy filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
                        if ([evaluatedObject isKindOfClass:[DCGuild class]]) {
                            DCGuild *guild = (DCGuild *)evaluatedObject;
                            return guild.snowflake && ![handledGuildIds containsObject:guild.snowflake];
                        }
                        return NO;
                    }]]; // get difference
                    if (origCopy.count > 0) {
                        NSRange range = NSMakeRange(1, [origCopy count]);
                        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:range];
                        [sortedGuilds insertObjects:origCopy atIndexes:indexSet];
                    }
                    self.displayGuilds                      = sortedGuilds;
                    DCServerCommunicator.sharedInstance.guildsIsSorted = YES;
                }
        }

        return self.displayGuilds.count;
    } else if (tableView == self.channelTableView && self.selectedGuild && self.selectedGuild.channels) {
        return self.selectedGuild.channels.count;
    } else {
        return 0;
    }
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
