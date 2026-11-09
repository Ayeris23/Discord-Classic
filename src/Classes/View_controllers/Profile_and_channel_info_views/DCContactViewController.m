//
//  DCContactViewController.m
//  Discord Classic
//
//  Created by bag.xml on 27/01/24.
//  Copyright (c) 2024 bag.xml. All rights reserved.
//

#import "DCInterfaceStyle.h"
#import "DCContactViewController.h"
#import "DCChatViewController.h"
#include "DCUser.h"
#include <objc/NSObjCRuntime.h>
#include "DCServerCommunicator.h"
#include "DCGuild.h"
#import "DCContentManager.h"


@interface DCContactViewController ()

@property DCUser *user;
@property (weak, nonatomic) IBOutlet UIImageView *profileImageView;
@property (weak, nonatomic) IBOutlet UIView *bannerView;
@property (weak, nonatomic) IBOutlet UIImageView *profileBanner;
@property (weak, nonatomic) IBOutlet UILabel *nameLabel;
@property (weak, nonatomic) IBOutlet UILabel *handleLable;
@property (weak, nonatomic) IBOutlet UITextView *descriptionBox;
@property (weak, nonatomic) IBOutlet UIImageView *statusIcon;
@property (assign, nonatomic) BOOL openingDirectMessage;
@property (strong, nonatomic) UIActivityIndicatorView *directMessageSpinner;
@end

@implementation DCContactViewController

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadUserAvatar:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.navBar setBackgroundImage:[DCInterfaceStyle navigationBarBackgroundImage]
                      forBarMetrics:UIBarMetricsDefault];
    [self.doneButton setBackgroundImage:[DCInterfaceStyle primaryBarButtonBackgroundImage]
                               forState:UIControlStateNormal
                             barMetrics:UIBarMetricsDefault];
    [self.doneButton setBackgroundImage:[DCInterfaceStyle primaryBarButtonPressedBackgroundImage]
                               forState:UIControlStateHighlighted
                             barMetrics:UIBarMetricsDefault];

    self.conTableView.delegate              = self;
    self.conTableView.dataSource            = self;
    self.slideMenuController.gestureSupport = NO;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadUserAvatar:)
                                                 name:@"RELOAD USER DATA"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadUserAvatar:)
                                                 name:@"USER_PRESENCE_UPDATED"
                                               object:nil];
}

- (void)setSelectedUser:(DCUser *)user {
    if (!user || !user.snowflake.length) return;
    DCUser *canonical = [DCServerCommunicator.sharedInstance userForSnowflake:user.snowflake];
    self.user = canonical ?: user;
    (void)self.view;
    self.snowflake = self.user.snowflake;
    [self reloadUserAvatar:nil];
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"]) {
        NSString *userID = [user.snowflake copy];
        __weak DCContactViewController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:
                    [NSString stringWithFormat:@"/users/%@/profile?with_mutual_guilds=false&with_mutual_friends=true&with_mutual_friends_count=false", userID]
                    token:DCServerCommunicator.sharedInstance.token];
                request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
                request.timeoutInterval = 15.0;
                [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
                NSHTTPURLResponse *httpResponse = nil;
                NSError *error = nil;
                NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                   returningResponse:&httpResponse error:&error];
                if (!data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
                    return;
                }

                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (![parsed isKindOfClass:[NSDictionary class]]) return;
                NSDictionary *response = (NSDictionary *)parsed;
                NSDictionary *profile = [response[@"user_profile"] isKindOfClass:[NSDictionary class]]
                    ? response[@"user_profile"] : nil;
                NSDictionary *userInfo = [response[@"user"] isKindOfClass:[NSDictionary class]]
                    ? response[@"user"] : nil;
                NSArray *accounts = [response[@"connected_accounts"] isKindOfClass:[NSArray class]]
                    ? response[@"connected_accounts"] : [NSArray array];
                NSArray *friends = [response[@"mutual_friends"] isKindOfClass:[NSArray class]]
                    ? response[@"mutual_friends"] : [NSArray array];
                NSString *pronouns = [profile[@"pronouns"] isKindOfClass:[NSString class]]
                    ? profile[@"pronouns"] : ([userInfo[@"pronouns"] isKindOfClass:[NSString class]] ? userInfo[@"pronouns"] : nil);
                NSString *bio = [profile[@"bio"] isKindOfClass:[NSString class]]
                    ? profile[@"bio"] : ([userInfo[@"bio"] isKindOfClass:[NSString class]] ? userInfo[@"bio"] : nil);
                NSString *bannerHash = [userInfo[@"banner"] isKindOfClass:[NSString class]] ? userInfo[@"banner"] : nil;
                NSString *bannerColor = [userInfo[@"banner_color"] isKindOfClass:[NSString class]] ? userInfo[@"banner_color"] : nil;
                NSString *bannerID = [userInfo[@"id"] isKindOfClass:[NSString class]] ? userInfo[@"id"] : userID;

                UIImage *banner = nil;
                if (bannerHash.length) {
                    NSString *URLString = [NSString stringWithFormat:
                        @"https://cdn.discordapp.com/banners/%@/%@.png?size=640", bannerID, bannerHash];
                    NSURLRequest *bannerRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:URLString]
                                                                   cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                               timeoutInterval:15.0];
                    NSData *imageData = [NSURLConnection sendSynchronousRequest:bannerRequest
                                                               returningResponse:nil error:nil];
                    if (imageData.length) banner = [UIImage imageWithData:imageData];
                }
                UIColor *color = bannerColor.length ? [UIColorHex colorWithHexString:bannerColor] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    DCContactViewController *strongSelf = weakSelf;
                    if (!strongSelf || ![strongSelf.snowflake isEqualToString:userID]) return;
                    if (userInfo) {
                        DCUser *updatedUser = [DCTools convertJsonUser:userInfo cache:YES];
                        if (updatedUser && [updatedUser.snowflake isEqualToString:userID]) {
                            strongSelf.user = updatedUser;
                            [strongSelf reloadUserAvatar:nil];
                            [NSNotificationCenter.defaultCenter
                                postNotificationName:@"RELOAD USER DATA"
                                              object:updatedUser];
                        }
                    }
                    strongSelf.connectedAccounts = accounts;
                    strongSelf.mutualFriends = friends;
                    strongSelf.pronounLabel.text = pronouns ?: @"";
                    strongSelf.descriptionBox.text = bio ?: @"";
                    if (banner) strongSelf.profileBanner.image = banner;
                    else if (color) strongSelf.bannerView.backgroundColor = color;
                    [strongSelf.conTableView reloadData];
                });
            }
        });
    }
}


- (void)reloadUserAvatar:(NSNotification *)notification {
    if (!self.user) return;
    DCUser *changedUser = [notification.object isKindOfClass:[DCUser class]]
        ? notification.object : nil;
    if (notification && changedUser &&
        ![changedUser.snowflake isEqualToString:self.snowflake]) return;

    DCUser *canonical = [DCServerCommunicator.sharedInstance userForSnowflake:self.snowflake];
    if (canonical) self.user = canonical;
    NSString *name = self.user.displayName;
    self.navigationItem.title = name.length ? name : @"Unknown User";
    self.nameLabel.text = name.length ? name : @"Unknown User";
    self.handleLable.text = self.user.username ?: @"";
    self.statusIcon.image = [DCInterfaceStyle statusImageForStatus:self.user.status];

    if (!self.user.profileImage) [DCTools getUserAvatar:self.user];
    UIImage *processed = self.user.rawProfileImage
        ? [DCContentManager processedAvatarForUser:self.user context:DCAssetContextProfile]
        : self.user.profileImage;
    if (processed && processed.size.width > 0) self.profileImageView.image = processed;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UINavigationController *)navigationControllerContainingChatFromPresenter:(UIViewController *)presenter {
    UINavigationController *navigationController =
        [presenter isKindOfClass:[UINavigationController class]]
            ? (UINavigationController *)presenter : presenter.navigationController;
    for (UIViewController *controller in navigationController.viewControllers) {
        if ([controller isKindOfClass:[DCChatViewController class]]) return navigationController;
    }

    UISplitViewController *splitViewController =
        [presenter isKindOfClass:[UISplitViewController class]]
            ? (UISplitViewController *)presenter : presenter.splitViewController;
    for (UIViewController *controller in splitViewController.viewControllers) {
        UINavigationController *detailNavigation =
            [controller isKindOfClass:[UINavigationController class]]
                ? (UINavigationController *)controller : controller.navigationController;
        for (UIViewController *candidate in detailNavigation.viewControllers) {
            if ([candidate isKindOfClass:[DCChatViewController class]]) return detailNavigation;
        }
    }
    return nil;
}

- (void)navigateToDirectMessageChannel:(DCChannel *)channel {
    if (!channel.snowflake.length) return;
    NSString *channelID = [channel.snowflake copy];

    // A presented contact card should return to the existing chat, not push another one.
    UINavigationController *chatNavigation = nil;
    DCChatViewController *chatController = nil;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"experimentalMode"]) {
        chatNavigation = [self navigationControllerContainingChatFromPresenter:self.presentingViewController];
        for (UIViewController *controller in chatNavigation.viewControllers) {
            if ([controller isKindOfClass:[DCChatViewController class]]) {
                chatController = (DCChatViewController *)controller;
                break;
            }
        }
    }

    __weak UINavigationController *weakChatNavigation = chatNavigation;
    __weak DCChatViewController *weakChatController = chatController;
    [self dismissViewControllerAnimated:YES completion:^{
        UINavigationController *navigationController = weakChatNavigation;
        DCChatViewController *existingChat = weakChatController;
        DCChannel *targetChannel = [DCServerCommunicator.sharedInstance.channels objectForKey:channelID];
        if (navigationController && existingChat &&
            [navigationController.viewControllers containsObject:existingChat] && targetChannel) {
            [existingChat navigateToChannel:targetChannel];
            if (navigationController.topViewController != existingChat) {
                [navigationController popToViewController:existingChat animated:NO];
            }
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"NavigateToChannel"
                                                            object:nil
                                                          userInfo:@{@"channelId": channelID}];
    }];
}

// buttons
- (IBAction)throwToChat:(id)sender {
    if (self.openingDirectMessage || !self.snowflake.length) return;
    DCChannel *channel = [self findPrivateChannelForUser:self.snowflake];
    if (channel) {
        [self navigateToDirectMessageChannel:channel];
        return;
    }

    self.openingDirectMessage = YES;
    self.chatButton.enabled = NO;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    spinner.center = CGPointMake(CGRectGetMidX(self.chatButton.bounds),
                                 CGRectGetMidY(self.chatButton.bounds));
    [self.chatButton addSubview:spinner];
    [spinner startAnimating];
    self.directMessageSpinner = spinner;
    NSString *userID = [self.snowflake copy];
    __weak DCContactViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:@"/users/@me/channels"
                token:DCServerCommunicator.sharedInstance.token];
            request.HTTPMethod = @"POST";
            request.timeoutInterval = 15.0;
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"recipient_id": userID}
                                                                options:0 error:nil];
            NSHTTPURLResponse *httpResponse = nil;
            NSError *error = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                               returningResponse:&httpResponse error:&error];
            id response = data && httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                DCContactViewController *strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf.snowflake isEqualToString:userID]) return;
                strongSelf.openingDirectMessage = NO;
                strongSelf.chatButton.enabled = YES;
                [strongSelf.directMessageSpinner stopAnimating];
                [strongSelf.directMessageSpinner removeFromSuperview];
                strongSelf.directMessageSpinner = nil;
                DCChannel *created = [response isKindOfClass:[NSDictionary class]]
                    ? [DCServerCommunicator.sharedInstance registerCreatedDirectMessageFromResponse:response]
                    : nil;
                if (created) {
                    [strongSelf navigateToDirectMessageChannel:created];
                } else {
                    [[[UIAlertView alloc] initWithTitle:@"Unable to Open Direct Message"
                                               message:@"The conversation could not be opened. Please try again."
                                              delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                }
            });
        }
    });
}

/*table view*/
- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"] == NO) {
        if (self.connectedAccounts.count == 0) {
            self.noConnections = YES;
            return 1;
        } else {
            self.noConnections = NO;
            return self.connectedAccounts.count;
        }
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.noConnections == NO) {
        DCConnectedAccountsCell *cell =
            [tableView dequeueReusableCellWithIdentifier:@"Connection"];

        NSArray *accountsArray    = (NSArray *)self.connectedAccounts;
        NSDictionary *accountDict = accountsArray[indexPath.row];
        cell.name.text            = accountDict[@"name"];
        cell.typeIcon.image       = [DCInterfaceStyle connectedAccountIconForType:accountDict[@"type"]];

        // steam, playstation, domain

        if ([accountDict[@"type"] isEqualToString:@"youtube"]) {
            cell.type.text      = @"YouTube";

        } else if ([accountDict[@"type"] isEqualToString:@"twitter"]) {
            cell.type.text      = @"Twitter";

        } else if ([accountDict[@"type"] isEqualToString:@"bluesky"]) {
            cell.type.text      = @"BlueSky";

        } else if ([accountDict[@"type"] isEqualToString:@"twitch"]) {
            cell.type.text      = @"Twitch";

        } else if ([accountDict[@"type"] isEqualToString:@"reddit"]) {
            cell.type.text      = @"Reddit";

        } else if ([accountDict[@"type"] isEqualToString:@"xbox"]) {
            cell.type.text      = @"Xbox-Live";

        } else if ([accountDict[@"type"] isEqualToString:@"steam"]) {
            cell.type.text      = @"Steam";

        } else if ([accountDict[@"type"] isEqualToString:@"playstation"]) {
            cell.type.text      = @"PlayStationNetwork";

        } else if ([accountDict[@"type"] isEqualToString:@"domain"]) {
            cell.type.text      = @"Domain/Website";

        } else if ([accountDict[@"type"] isEqualToString:@"spotify"]) {
            cell.type.text      = @"Spotify";

        } else if ([accountDict[@"type"] isEqualToString:@"github"]) {
            cell.type.text      = @"GitHub";

        } else {
            cell.type.text      = accountDict[@"type"];
        }

        return cell;
    } else if (self.noConnections == YES) {
        UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:@"No-Connection"];
        if (!cell) {
            cell = UITableViewCell.new;
        }
        return cell;
    }
    NSAssert(0, @"Unexpected state");
    abort();
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 120;
}

- (IBAction)throwToMutualFriends:(id)sender {
    [self performSegueWithIdentifier:@"about to mutual friends" sender:self];
}



- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"about to mutual friends"]) {
        if ([segue.destinationViewController isKindOfClass:[DCMutualFriendsViewController class]]) {
            DCMutualFriendsViewController *friendmutualVC =
                (DCMutualFriendsViewController *)
                    segue.destinationViewController;
            friendmutualVC.mutualFriendsList = self.mutualFriends;
        }
    }
}

- (DCChannel *)findPrivateChannelForUser:(NSString *)userId {
    NSUInteger idx = [DCServerCommunicator.sharedInstance.guilds indexOfObjectPassingTest:^BOOL(DCGuild *g, NSUInteger idx, BOOL *stop) {
        return [g.name isEqualToString:@"Direct Messages"];
    }];
    if (idx == NSNotFound) {
        return nil;
    }
    DCGuild *privGuild = [DCServerCommunicator.sharedInstance.guilds objectAtIndex:idx];
    for (DCChannel *channel in privGuild.channels) {
        if (channel.type != DCChannelTypeDM) continue;
        for (DCUser *user in channel.recipients) {
            if ([user.snowflake isEqualToString:userId]) return channel;
        }
        if ([channel.recipientIDs containsObject:userId]) return channel;
        for (DCUser *user in channel.users) {
            if ([user.snowflake isEqualToString:userId]) return channel;
        }
    }
    return nil;
}

- (IBAction)clickedDone:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
