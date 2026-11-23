//
//  DCPinnedMessagesViewController.m
//  Discord Classic
//
//  Created by Ayeris on 11/22/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCPinnedMessagesViewController.h"
#import "DCChatViewController.h"
#import "DCChannel.h"
#import "DCMessage.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"
#import "DCMessageStore.h"
#import "DCInterfaceStyle.h"
#import <objc/runtime.h>

static char DCPinnedPopoverAssociationKey;

@interface DCPinnedMessagesViewController ()
@property (nonatomic, strong) DCChannel *channel;
@property (nonatomic, strong) DCChatViewController *messageListController;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) UIPopoverController *hostPopover;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, assign) BOOL loadStarted;
@property (nonatomic, assign) NSUInteger loadGeneration;
- (void)loadPinnedMessages;
- (void)convertPinnedMessages:(NSArray *)rawMessages
                    fromIndex:(NSUInteger)index
                 intoMessages:(NSMutableArray *)converted
                      channel:(DCChannel *)channel
                   generation:(NSUInteger)generation;
- (void)resolveMissingReplyReferencesForMessages:(NSArray *)messages
                                        generation:(NSUInteger)generation;
- (void)applyReferencePayload:(NSDictionary *)payload toReply:(DCMessage *)reply;
- (void)applyCachedReference:(DCMessage *)reference toReply:(DCMessage *)reply;
- (void)fetchReferenceRequests:(NSArray *)requests
                      atIndex:(NSUInteger)index
                   generation:(NSUInteger)generation
                      retries:(NSUInteger)retries;
- (void)closePinnedMessages;
- (void)jumpToMessage:(DCMessage *)message;
- (void)jumpToMessageID:(NSString *)messageID
              channelID:(NSString *)channelID
                guildID:(NSString *)guildID;
- (void)clearPopover;
@end

@implementation DCPinnedMessagesViewController

+ (void)presentForChannel:(DCChannel *)channel
          fromController:(UIViewController *)presenter
     sourceBarButtonItem:(UIBarButtonItem *)barButtonItem {
    if (!channel.snowflake.length || !presenter) return;

    NSString *storyboardName = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        ? @"Storyboard-iPad" : @"Storyboard";
    UIStoryboard *chatStoryboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
    DCChatViewController *messageList = [chatStoryboard
        instantiateViewControllerWithIdentifier:@"DiscordChatViewController"];
    [messageList configureReadOnlyMessageListForChannel:channel];
    messageList.messageCellActionTitle = @"Jump to Message";

    DCPinnedMessagesViewController *viewer = [[DCPinnedMessagesViewController alloc] init];
    viewer.channel = channel;
    viewer.messageListController = messageList;
    viewer.presenter = presenter;
    __weak DCPinnedMessagesViewController *weakViewer = viewer;
    messageList.messageCellActionHandler = ^(DCMessage *message) {
        [weakViewer jumpToMessage:message];
    };
    messageList.messageReferenceJumpHandler = ^(NSString *messageID, NSString *channelID, NSString *guildID) {
        [weakViewer jumpToMessageID:messageID channelID:channelID guildID:guildID];
    };

    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:viewer];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && barButtonItem) {
        UIPopoverController *previous = objc_getAssociatedObject(
            presenter, &DCPinnedPopoverAssociationKey);
        if (previous) {
            previous.delegate = nil;
            [previous dismissPopoverAnimated:NO];
        }
        navigation.contentSizeForViewInPopover = CGSizeMake(500.0f, 630.0f);
        viewer.contentSizeForViewInPopover = navigation.contentSizeForViewInPopover;
        UIPopoverController *popover = [[UIPopoverController alloc]
            initWithContentViewController:navigation];
        if ([popover respondsToSelector:NSSelectorFromString(@"_setPopoverBackgroundStyle:")]) {
            @try {
                [popover setValue:[NSNumber numberWithInteger:3]
                         forKey:@"_popoverBackgroundStyle"];
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        viewer.hostPopover = popover;
        popover.delegate = viewer;
        objc_setAssociatedObject(presenter, &DCPinnedPopoverAssociationKey,
                                 popover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [popover presentPopoverFromBarButtonItem:barButtonItem
                       permittedArrowDirections:UIPopoverArrowDirectionAny
                                       animated:YES];
    } else {
        [presenter presentViewController:navigation animated:YES completion:nil];
    }
}

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 500, 630)];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"Pinned Messages";
    BOOL isPad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
    UIBarButtonItem *close = [[UIBarButtonItem alloc]
        initWithTitle:@"Done"
                style:isPad ? UIBarButtonItemStyleBordered : UIBarButtonItemStyleDone
               target:self action:@selector(closePinnedMessages)];
    if (!isPad) {
        [close setBackgroundImage:[DCInterfaceStyle primaryBarButtonBackgroundImage]
                       forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
        [close setBackgroundImage:[DCInterfaceStyle primaryBarButtonPressedBackgroundImage]
                       forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    }
    self.navigationItem.leftBarButtonItem = close;

    [self addChildViewController:self.messageListController];
    self.messageListController.view.frame = self.view.bounds;
    self.messageListController.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.messageListController.view];
    [self.messageListController didMoveToParentViewController:self];
    self.view.backgroundColor = self.messageListController.view.backgroundColor;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 300, 44)];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.textColor = [UIColor lightGrayColor];
    self.statusLabel.textAlignment = UITextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:14.0f];
    self.statusLabel.text = @"Loading pinned messages…";
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.statusLabel];
    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [self.view addSubview:self.loadingSpinner];
    [self.loadingSpinner startAnimating];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) return;

    UINavigationBar *navigationBar = self.navigationController.navigationBar;
    [DCInterfaceStyle applyNavigationTitleStyleToBar:navigationBar];
    [navigationBar setBackgroundImage:[DCInterfaceStyle navigationBarBackgroundImage]
                     forBarMetrics:UIBarMetricsDefault];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.loadStarted) [self loadPinnedMessages];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.statusLabel.center = CGPointMake(CGRectGetMidX(self.view.bounds),
                                           CGRectGetMidY(self.view.bounds));
    self.loadingSpinner.center = CGPointMake(CGRectGetMidX(self.view.bounds),
                                              CGRectGetMidY(self.view.bounds) - 28.0f);
}

- (void)clearPopover {
    UIViewController *presenter = self.presenter;
    if (presenter && objc_getAssociatedObject(presenter, &DCPinnedPopoverAssociationKey)
        == self.hostPopover) {
        objc_setAssociatedObject(presenter, &DCPinnedPopoverAssociationKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController {
    if (popoverController != self.hostPopover) return;
    ++self.loadGeneration;
    [self clearPopover];
    self.hostPopover = nil;
}

- (void)closePinnedMessages {
    ++self.loadGeneration;
    if (self.hostPopover) {
        UIPopoverController *popover = self.hostPopover;
        popover.delegate = nil;
        [popover dismissPopoverAnimated:YES];
        [self clearPopover];
        self.hostPopover = nil;
    } else {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)jumpToMessage:(DCMessage *)message {
    [self jumpToMessageID:message.snowflake
                channelID:self.channel.snowflake
                  guildID:nil];
}

- (void)jumpToMessageID:(NSString *)messageID
              channelID:(NSString *)channelID
                guildID:(NSString *)guildID {
    if (!messageID.length || !channelID.length) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        messageID, @"messageID", channelID, @"channelID", nil];
    if (guildID.length) [info setObject:guildID forKey:@"guildID"];
    ++self.loadGeneration;
    if (self.hostPopover) {
        UIPopoverController *popover = self.hostPopover;
        popover.delegate = nil;
        [popover dismissPopoverAnimated:YES];
        [self clearPopover];
        self.hostPopover = nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DCPinnedMessageJumpRequested"
                                                            object:nil userInfo:info];
    } else {
        [self.navigationController dismissViewControllerAnimated:YES completion:^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DCPinnedMessageJumpRequested"
                                                                object:nil userInfo:info];
        }];
    }
}

- (void)loadPinnedMessages {
    if (self.loadStarted) return;
    self.loadStarted = YES;
    NSUInteger generation = ++self.loadGeneration;
    DCChannel *channel = self.channel;
    NSString *channelID = [channel.snowflake copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    __weak DCPinnedMessagesViewController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSMutableArray *rawMessages = [NSMutableArray array];
            NSString *before = nil;
            BOOL hasMore = YES;
            BOOL failed = NO;
            NSUInteger pageCount = 0;
            while (hasMore && pageCount < 5) {
                NSMutableString *path = [NSMutableString stringWithFormat:
                    @"/channels/%@/messages/pins?limit=50", channelID];
                if (before.length) {
                    NSString *escaped = [[before stringByAddingPercentEscapesUsingEncoding:
                        NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"+"
                        withString:@"%2B"];
                    [path appendFormat:@"&before=%@", escaped];
                }
                NSMutableURLRequest *request =
                    [DCServerCommunicator requestWithPath:path token:token];
                request.timeoutInterval = 15.0;
                [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
                NSHTTPURLResponse *response = nil;
                NSError *error = nil;
                NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                   returningResponse:&response
                                                               error:&error];
                id json = data && response.statusCode == 200 && !error
                    ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (![json isKindOfClass:[NSDictionary class]]) {
                    if (pageCount == 0) {
                        NSString *legacyPath = [NSString stringWithFormat:
                            @"/channels/%@/pins", channelID];
                        NSMutableURLRequest *legacyRequest =
                            [DCServerCommunicator requestWithPath:legacyPath token:token];
                        [legacyRequest setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
                        NSData *legacyData = [NSURLConnection sendSynchronousRequest:legacyRequest
                                                             returningResponse:&response
                                                                         error:&error];
                        id legacy = legacyData && response.statusCode == 200 && !error
                            ? [NSJSONSerialization JSONObjectWithData:legacyData
                                                               options:0 error:nil] : nil;
                        if ([legacy isKindOfClass:[NSArray class]]) {
                            [rawMessages addObjectsFromArray:legacy];
                            break;
                        }
                    }
                    failed = YES;
                    break;
                }
                NSArray *items = [json objectForKey:@"items"];
                if (![items isKindOfClass:[NSArray class]]) {
                    failed = YES;
                    break;
                }
                NSString *oldBefore = before;
                for (NSDictionary *item in items) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *message = [item objectForKey:@"message"];
                    if ([message isKindOfClass:[NSDictionary class]]) {
                        [rawMessages addObject:message];
                    }
                    NSString *pinnedAt = [item objectForKey:@"pinned_at"];
                    if ([pinnedAt isKindOfClass:[NSString class]]) before = pinnedAt;
                }
                pageCount++;
                hasMore = [[json objectForKey:@"has_more"] boolValue] &&
                    items.count > 0 && before.length && ![before isEqualToString:oldBefore];
            }

            if (failed && rawMessages.count == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    DCPinnedMessagesViewController *viewer = weakSelf;
                    if (!viewer || generation != viewer.loadGeneration) return;
                    [viewer.loadingSpinner stopAnimating];
                    viewer.statusLabel.text = @"Unable to load pinned messages.";
                });
                return;
            }

            [rawMessages sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                  NSDictionary *b) {
                id rawA = [a objectForKey:@"id"];
                id rawB = [b objectForKey:@"id"];
                NSString *idA = [rawA isKindOfClass:[NSString class]] ? rawA : @"";
                NSString *idB = [rawB isKindOfClass:[NSString class]] ? rawB : @"";
                if (idA.length != idB.length)
                    return idA.length < idB.length
                        ? NSOrderedAscending : NSOrderedDescending;
                return [idA compare:idB options:NSLiteralSearch];
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                DCPinnedMessagesViewController *viewer = weakSelf;
                if (!viewer || generation != viewer.loadGeneration) return;
                viewer.statusLabel.text = @"Preparing pinned messages…";
                NSMutableArray *converted = [NSMutableArray arrayWithCapacity:rawMessages.count];
                [viewer convertPinnedMessages:rawMessages fromIndex:0
                                  intoMessages:converted channel:channel
                                    generation:generation];
            });
        }
    });
}

- (void)convertPinnedMessages:(NSArray *)rawMessages
                    fromIndex:(NSUInteger)index
                 intoMessages:(NSMutableArray *)converted
                      channel:(DCChannel *)channel
                   generation:(NSUInteger)generation {
    if (generation != self.loadGeneration) return;

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.008;
    NSUInteger count = rawMessages.count;
    NSUInteger processed = 0;
    while (index < count && processed < 4) {
        @autoreleasepool {
            DCMessage *message = [DCTools convertJsonMessage:[rawMessages objectAtIndex:index]
                                          deferLegacyLayout:YES channel:channel];
            if (message) [converted addObject:message];
        }
        ++index;
        ++processed;
        if (CFAbsoluteTimeGetCurrent() >= deadline) break;
    }

    if (index == count) {
        [self.messageListController setReadOnlyMessages:converted];
        [self.loadingSpinner stopAnimating];
        self.statusLabel.text = converted.count
            ? nil : @"No pinned messages in this channel.";
        self.statusLabel.hidden = converted.count > 0;
        __weak DCPinnedMessagesViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            DCPinnedMessagesViewController *viewer = weakSelf;
            if (!viewer || generation != viewer.loadGeneration) return;
            [viewer resolveMissingReplyReferencesForMessages:converted generation:generation];
        });
        return;
    }

    __weak DCPinnedMessagesViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.005 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DCPinnedMessagesViewController *viewer = weakSelf;
        if (!viewer || generation != viewer.loadGeneration) return;
        [viewer convertPinnedMessages:rawMessages fromIndex:index
                          intoMessages:converted channel:channel
                            generation:generation];
    });
}

- (void)applyReferencePayload:(NSDictionary *)payload toReply:(DCMessage *)reply {
    if (![payload isKindOfClass:[NSDictionary class]] ||
        reply.referencedMessageState != DCMessageReferenceStateUnavailable) return;

    NSDictionary *authorJSON = [payload objectForKey:@"author"];
    if (![authorJSON isKindOfClass:[NSDictionary class]]) return;

    DCMessage *reference = reply.referencedMessage;
    NSString *targetID = reference.snowflake;
    id payloadID = [payload objectForKey:@"id"];
    if ([payloadID isKindOfClass:[NSString class]] && targetID.length &&
        ![targetID isEqualToString:payloadID]) return;

    DCUser *author = [DCTools convertJsonUser:authorJSON cache:YES];
    if (!author) return;

    if (!reference) reference = [DCMessage new];
    reference.snowflake = targetID.length ? targetID : payloadID;
    reference.author = author;
    id content = [payload objectForKey:@"content"];
    reference.content = [content isKindOfClass:[NSString class]] && [content length]
        ? content : @"Click to view attachment";
    reply.referencedMessage = reference;
    reply.referencedMessageState = DCMessageReferenceStateResolved;
    [self.messageListController refreshReadOnlyMessage:reply];
}

- (void)applyCachedReference:(DCMessage *)source toReply:(DCMessage *)reply {
    if (!source.author || !source.snowflake.length ||
        reply.referencedMessageState != DCMessageReferenceStateUnavailable ||
        ![reply.referencedMessage.snowflake isEqualToString:source.snowflake]) return;

    DCMessage *reference = reply.referencedMessage;
    reference.author = source.author;
    reference.content = source.content.length ? source.content : @"Click to view attachment";
    reply.referencedMessageState = DCMessageReferenceStateResolved;
    [self.messageListController refreshReadOnlyMessage:reply];
}

- (void)resolveMissingReplyReferencesForMessages:(NSArray *)messages
                                        generation:(NSUInteger)generation {
    if (generation != self.loadGeneration) return;

    NSMutableDictionary *pinnedPayloads = [NSMutableDictionary dictionaryWithCapacity:messages.count];
    for (DCMessage *message in messages) {
        if (message.snowflake.length && message.sourceJSON) {
            [pinnedPayloads setObject:message.sourceJSON forKey:message.snowflake];
        }
    }

    // A live chat already owns its message models. Reuse them without disk I/O
    // or a network request, and keep the read-only pin window independent.
    DCChannelWindow *loadedWindow = [[DCMessageStore sharedInstance]
        loadedWindowForChannel:self.channel.snowflake];
    NSMutableDictionary *cachedMessages = [NSMutableDictionary dictionary];
    for (DCMessage *cached in loadedWindow.messages) {
        if (cached.snowflake.length && cached.author) {
            [cachedMessages setObject:cached forKey:cached.snowflake];
        }
    }

    NSUInteger cacheHits = 0;
    NSUInteger replyCount = 0;
    NSUInteger deletedCount = 0;
    NSUInteger missingIDCount = 0;
    NSMutableArray *requests = [NSMutableArray array];
    NSMutableDictionary *requestsByKey = [NSMutableDictionary dictionary];
    for (DCMessage *message in [messages reverseObjectEnumerator]) {
        if (message.messageType != DCMessageTypeReply) continue;
        replyCount++;
        if (message.referencedMessageState == DCMessageReferenceStateDeleted) {
            deletedCount++;
            continue;
        }
        if (message.referencedMessageState != DCMessageReferenceStateUnavailable) continue;
        if (!message.referencedMessage.snowflake.length) {
            missingIDCount++;
            continue;
        }

        NSString *targetID = message.referencedMessage.snowflake;
        NSDictionary *metadata = [message.sourceJSON objectForKey:@"message_reference"];
        id rawChannelID = [metadata isKindOfClass:[NSDictionary class]]
            ? [metadata objectForKey:@"channel_id"] : nil;
        NSString *channelID = [rawChannelID isKindOfClass:[NSString class]] &&
            [rawChannelID length] ? rawChannelID : self.channel.snowflake;
        if (!channelID.length) continue;

        if ([channelID isEqualToString:self.channel.snowflake]) {
            DCMessage *cached = [cachedMessages objectForKey:targetID];
            if (cached) {
                [self applyCachedReference:cached toReply:message];
            }
            if (message.referencedMessageState != DCMessageReferenceStateResolved) {
                NSDictionary *localPayload = [pinnedPayloads objectForKey:targetID];
                if (localPayload) {
                    [self applyReferencePayload:localPayload toReply:message];
                }
            }
            if (message.referencedMessageState == DCMessageReferenceStateResolved) {
                cacheHits++;
                continue;
            }
        }

        NSString *key = [NSString stringWithFormat:@"%@:%@", channelID, targetID];
        NSMutableDictionary *request = [requestsByKey objectForKey:key];
        if (!request) {
            request = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                channelID, @"channelID", targetID, @"messageID",
                [NSMutableArray array], @"replies", nil];
            [requestsByKey setObject:request forKey:key];
            [requests addObject:request];
        }
        [[request objectForKey:@"replies"] addObject:message];
    }
    if (replyCount) {
        NSLog(@"[Pins] Replies %lu: %lu cached, %lu history lookups, %lu deleted, %lu missing IDs",
              (unsigned long)replyCount, (unsigned long)cacheHits,
              (unsigned long)requests.count, (unsigned long)deletedCount,
              (unsigned long)missingIDCount);
    }
    [self fetchReferenceRequests:requests atIndex:0 generation:generation retries:0];
}

- (void)fetchReferenceRequests:(NSArray *)requests
                      atIndex:(NSUInteger)index
                   generation:(NSUInteger)generation
                      retries:(NSUInteger)retries {
    if (generation != self.loadGeneration || index >= requests.count) return;

    NSDictionary *requestInfo = [requests objectAtIndex:index];
    NSString *channelID = [requestInfo objectForKey:@"channelID"];
    NSString *messageID = [requestInfo objectForKey:@"messageID"];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    __weak DCPinnedMessagesViewController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSString *path = [NSString stringWithFormat:
                @"/channels/%@/messages?around=%@&limit=3", channelID, messageID];
            NSMutableURLRequest *request =
                [DCServerCommunicator requestWithPath:path token:token];
            request.timeoutInterval = 15.0;
            NSHTTPURLResponse *response = nil;
            NSError *error = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                               returningResponse:&response
                                                           error:&error];
            id json = data && !error
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *payload = nil;
            if (response.statusCode == 200 && [json isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)json) {
                    if ([item isKindOfClass:[NSDictionary class]] &&
                        [[item objectForKey:@"id"] isEqual:messageID]) {
                        payload = item;
                        break;
                    }
                }
            }
            NSTimeInterval retryDelay = 0;
            if (response.statusCode == 429 && retries < 2) {
                id rawDelay = [json isKindOfClass:[NSDictionary class]]
                    ? [json objectForKey:@"retry_after"] : nil;
                retryDelay = [rawDelay respondsToSelector:@selector(doubleValue)]
                    ? MAX(0.5, MIN(60.0, [rawDelay doubleValue])) : 1.0;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                DCPinnedMessagesViewController *viewer = weakSelf;
                if (!viewer || generation != viewer.loadGeneration) return;

                if (retryDelay > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                  (int64_t)(retryDelay * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        DCPinnedMessagesViewController *currentViewer = weakSelf;
                        if (!currentViewer || generation != currentViewer.loadGeneration) return;
                        [currentViewer fetchReferenceRequests:requests atIndex:index
                                                    generation:generation retries:retries + 1];
                    });
                    return;
                }

                if (response.statusCode == 429) {
                    NSLog(@"[Pins] Reply hydration stopped after repeated rate limiting");
                    return;
                }

                if (payload) {
                    for (DCMessage *reply in [requestInfo objectForKey:@"replies"]) {
                        [viewer applyReferencePayload:payload toReply:reply];
                    }
                } else {
                    NSLog(@"[Pins] Reply reference %@ unavailable in channel %@ (HTTP %ld%@)",
                          messageID, channelID, (long)response.statusCode,
                          error ? [NSString stringWithFormat:@", %@", error.code == NSURLErrorTimedOut
                              ? @"timeout" : @"network error"] : @"");
                }
                [viewer fetchReferenceRequests:requests atIndex:index + 1
                                    generation:generation retries:0];
            });
        }
    });
}

- (void)dealloc {
    ++_loadGeneration;
}

@end
