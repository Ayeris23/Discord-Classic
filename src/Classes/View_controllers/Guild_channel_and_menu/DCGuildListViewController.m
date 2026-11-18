//
//  DCGuildViewController.m
//  Discord Classic
//
//  Created by bag.xml on 3/4/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCGuildListViewController.h"
#import "DCChannelListViewController.h"
#import "DCGuild.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"

@interface DCGuildListViewController ()
@property (strong, nonatomic) NSMutableSet *pendingAckGuilds;
@property (assign, nonatomic) BOOL ackRefreshScheduled;
@end

@implementation DCGuildListViewController

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Go to settings if no token is set
    if (!DCServerCommunicator.sharedInstance.token.length) {
        [self performSegueWithIdentifier:@"to Settings" sender:self];
    }

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReady)
                                               name:@"READY"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleMessageAck:)
                                               name:@"MESSAGE ACK"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReady)
                                               name:@"RELOAD GUILD LIST"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReady)
                                               name:@"RELOAD GUILD"
                                             object:nil];
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
    DCChannel *channel = [DCServerCommunicator.sharedInstance.channels objectForKey:channelID];
    if (!channel.parentGuild) return;
    if (!self.pendingAckGuilds) self.pendingAckGuilds = [NSMutableSet set];
    [self.pendingAckGuilds addObject:channel.parentGuild];

    if (self.ackRefreshScheduled) return;
    self.ackRefreshScheduled = YES;
    __weak DCGuildListViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.075 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf flushMessageAckUpdates];
    });
}

- (void)flushMessageAckUpdates {
    self.ackRefreshScheduled = NO;
    NSSet *guilds = [self.pendingAckGuilds copy];
    [self.pendingAckGuilds removeAllObjects];
    if (!self.isViewLoaded || !self.view.window) return;

    NSArray *allGuilds = DCServerCommunicator.sharedInstance.guilds;
    if ([self.tableView numberOfRowsInSection:0] != (NSInteger)allGuilds.count) {
        [self.tableView reloadData];
        return;
    }
    NSSet *visible = [NSSet setWithArray:[self.tableView indexPathsForVisibleRows] ?: @[]];
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger index = 0;
    for (DCGuild *guild in allGuilds) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:index inSection:0];
        if ([guilds containsObject:guild] && [visible containsObject:path])
            [rows addObject:path];
        index++;
    }
    if (rows.count)
        [self.tableView reloadRowsAtIndexPaths:rows
                              withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)handleReady {
    // Refresh tableView data on READY notification
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}


- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"Guild Cell"];

    DCGuild *guildAtRowIndex = [DCServerCommunicator.sharedInstance.guilds
        objectAtIndex:indexPath.row];

    // Show blue indicator if guild has any unread messages
    if (guildAtRowIndex.unread) {
        [cell setAccessoryType:UITableViewCellAccessoryDetailDisclosureButton];
    } else {
        [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
    }

    // Guild name and icon
    [cell.textLabel setText:guildAtRowIndex.name];
    [cell.imageView setImage:guildAtRowIndex.icon];

    return cell;
}


- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([DCServerCommunicator.sharedInstance.guilds objectAtIndex:indexPath.row]
        != DCServerCommunicator.sharedInstance.selectedGuild) {
        // loadedUsers is now the canonical user store and may have been
        // restored from disk. Guild switches must not discard it; expensive
        // image/layout state is handled by the dedicated caches instead.
        // Assign the selected guild
        DCServerCommunicator.sharedInstance.selectedGuild =
            [DCServerCommunicator.sharedInstance.guilds
                objectAtIndex:indexPath.row];
    }

    // Transition to channel list
    [self performSegueWithIdentifier:@"Guilds to Channels" sender:self];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"Guilds to Channels"]) {
        DCChannelListViewController *channelListViewController =
            [segue destinationViewController];

        if ([channelListViewController
                isKindOfClass:DCChannelListViewController.class]) {
            // Assign selected guild for the channel list we are transitioning
            // to.
            channelListViewController.selectedGuild =
                DCServerCommunicator.sharedInstance.selectedGuild;
        }
    }
}

- (IBAction)joinGuildPrompt:(id)sender {
    UIAlertView *joinPrompt =
        [[UIAlertView alloc] initWithTitle:@"Enter invite code"
                                   message:nil
                                  delegate:self
                         cancelButtonTitle:@"Cancel"
                         otherButtonTitles:@"Join", nil];

    joinPrompt.alertViewStyle = UIAlertViewStylePlainTextInput;
    joinPrompt.delegate = self;
    [joinPrompt show];
}

- (void)alertView:(UIAlertView *)alertView
    clickedButtonAtIndex:(NSInteger)buttonIndex {
    if ([[alertView buttonTitleAtIndex:buttonIndex] isEqualToString:@"Join"]) {
        [DCTools joinGuild:[alertView textFieldAtIndex:0].text];
    }
}

- (void)reconnect {
    [DCServerCommunicator.sharedInstance reconnect];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return DCServerCommunicator.sharedInstance.guilds.count;
}


@end