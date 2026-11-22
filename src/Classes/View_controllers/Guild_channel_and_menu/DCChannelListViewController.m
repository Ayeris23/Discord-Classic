//
//  DCChannelViewController.m
//  Discord Classic
//
//  Created by bag.xml on 3/5/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCChannelListViewController.h"
#import "DCCInfoViewController.h"
#import "DCChannel.h"
#import "DCChatViewController.h"
#import "DCGuild.h"
#import "DCServerCommunicator.h"
#import "TRMalleableFrameView.h"

@interface DCChannelListViewController ()
@property int selectedChannelIndex;
@property (strong, nonatomic) NSArray *displayChannels;
@property DCChannel *selectedChannel;
@property (strong, nonatomic) NSMutableSet *pendingAckChannelIDs;
@property (assign, nonatomic) BOOL pendingFullChannelReload;
@property (assign, nonatomic) BOOL ackRefreshScheduled;
@end

@implementation DCChannelListViewController

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleMessageAck:)
                                               name:@"MESSAGE ACK"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleMessageAck:)
                                               name:@"RELOAD CHANNEL LIST"
                                             object:nil];
}


- (void)reloadDisplayedChannels {
    self.displayChannels = self.selectedGuild
        ? [self.selectedGuild channelsSnapshot] : [NSArray array];
    [self.tableView reloadData];
}

- (DCChannel *)displayedChannelAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section != 0 || indexPath.row < 0 ||
        (NSUInteger)indexPath.row >= self.displayChannels.count) return nil;
    return [self.displayChannels objectAtIndex:(NSUInteger)indexPath.row];
}

- (BOOL)displayedChannelsMatch:(NSArray *)channels {
    if (self.displayChannels.count != channels.count) return NO;
    for (NSUInteger i = 0; i < channels.count; i++) {
        if ([self.displayChannels objectAtIndex:i] != [channels objectAtIndex:i]) return NO;
    }
    return YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationItem setTitle:self.selectedGuild.name];
    [self reloadDisplayedChannels];
    [DCServerCommunicator.sharedInstance setSelectedChannel:nil];

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
    if (![channelID isKindOfClass:[NSString class]] || !channelID.length) {
        self.pendingFullChannelReload = YES;
    } else {
        if (!self.pendingAckChannelIDs) self.pendingAckChannelIDs = [NSMutableSet set];
        [self.pendingAckChannelIDs addObject:channelID];
    }

    if (self.ackRefreshScheduled) return;
    self.ackRefreshScheduled = YES;
    __weak DCChannelListViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.075 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf flushMessageAckUpdates];
    });
}

- (void)flushMessageAckUpdates {
    self.ackRefreshScheduled = NO;
    BOOL fullReload = self.pendingFullChannelReload;
    self.pendingFullChannelReload = NO;
    NSSet *channelIDs = [self.pendingAckChannelIDs copy];
    [self.pendingAckChannelIDs removeAllObjects];
    if (!self.isViewLoaded || !self.view.window) return;

    if (fullReload || ![self displayedChannelsMatch:
                        [self.selectedGuild channelsSnapshot]] ||
        [self.tableView numberOfRowsInSection:0] != (NSInteger)self.displayChannels.count) {
        [self reloadDisplayedChannels];
        return;
    }

    NSSet *visible = [NSSet setWithArray:[self.tableView indexPathsForVisibleRows] ?: @[]];
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger index = 0;
    for (DCChannel *channel in self.displayChannels) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:index inSection:0];
        if (channel.snowflake.length && [channelIDs containsObject:channel.snowflake] &&
            [visible containsObject:path]) {
            [rows addObject:path];
        }
        index++;
    }
    if (rows.count)
        [self.tableView reloadRowsAtIndexPaths:rows
                              withRowAnimation:UITableViewRowAnimationNone];
}


- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Show blue indicator if channel contains any unread messages
    DCChannel *channelAtRowIndex = [self displayedChannelAtIndexPath:indexPath];
    if (!channelAtRowIndex) {
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:nil];
    }

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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Channel Cell"];

    cell.accessoryType = channelAtRowIndex.unread
        ? UITableViewCellAccessoryDetailDisclosureButton
        : UITableViewCellAccessoryDisclosureIndicator;

    // Channel name
    cell.textLabel.text = channelAtRowIndex.name;

    return cell;
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    // make guild icons a fixed size
    cell.imageView.frame               = CGRectMake(0, 0, 32, 32);
    cell.imageView.layer.cornerRadius  = cell.imageView.frame.size.height / 2.0;
    cell.imageView.layer.masksToBounds = YES;
    [cell.imageView setNeedsDisplay];
    [cell layoutIfNeeded];
}


- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    DCChannel *channel = [self displayedChannelAtIndexPath:indexPath];
    if (!channel) return;
    DCServerCommunicator.sharedInstance.selectedChannel = channel;

    if (channel.type == 4) {
        // If the channel is a category, do nothing
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    // Transition to chat view
    [self performSegueWithIdentifier:@"Channels to Chat" sender:self];
}


- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"Channels to Chat"]) {
        DCChatViewController *chatViewController =
            [segue destinationViewController];

        if ([chatViewController isKindOfClass:[DCChatViewController class]]) {
            // Add a '#' if appropriate to the channel name in the navigation bar
            NSString *formattedChannelName;
            if (DCServerCommunicator.sharedInstance.selectedChannel.type == 0) {
                formattedChannelName = [@"#"
                    stringByAppendingString:DCServerCommunicator.sharedInstance
                                                .selectedChannel.name];
            } else {
                formattedChannelName = DCServerCommunicator.sharedInstance.selectedChannel.name;
            }
            chatViewController.navigationItem.title = formattedChannelName;

        }
    } else if ([segue.identifier isEqualToString:@"Channels to RightSidebar"]) {
        DCCInfoViewController *rightSidebar = [segue destinationViewController];

        if ([rightSidebar isKindOfClass:[DCChatViewController class]]) {
            rightSidebar.navigationItem.title = self.selectedGuild.name;
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return self.displayChannels.count;
}
@end
