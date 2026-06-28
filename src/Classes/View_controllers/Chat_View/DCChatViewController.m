//
//  DCChatViewController.m
//  Discord Classic
//
//  Created by bag.xml on 3/6/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCChatViewController.h"
#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include "DCEmoji.h"
#include "SDWebImageManager.h"

#include <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
#include <UIKit/UIKit.h>
#include <malloc/malloc.h>
#include <objc/NSObjCRuntime.h>
#import <MediaPlayer/MediaPlayer.h>

#import "DCCInfoViewController.h"
#import "DCChatTableCell.h"
#import "DCChatVideoAttachment.h"
#import "DCChatGifAttachment.h"
#import "DCGifInfo.h"
#import "DCImageViewController.h"
#import "DCMessage.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"
#import "DCUser.h"
#import "QuickLook/QuickLook.h"
#import "TRMalleableFrameView.h"
#import "UILazyImage.h"
#import "UILazyImageView.h"
#import "DCCacheManager.h"
#import "DTLinkButton.h"
#import "DCMarkdownParser.h"
#import "DTCoreTextLayouter.h"
#import "DTCoreTextLayoutFrame.h"
#import "DTImageTextAttachment.h"
#import "DCMessageStore.h"
#import "DCChannelWindow.h"
#import "DCMessageLayoutBuilder.h"

@interface DCChatViewController ()
@property (nonatomic, readonly) NSMutableArray *messages;
@property (strong, nonatomic) DCMessageLayoutBuilder *messageLayoutBuilder;
@property (nonatomic, strong) DCChannelWindow *currentWindow;
@property (assign, nonatomic) NSUInteger numberOfMessagesLoaded;
@property (strong, nonatomic) UIImage *selectedImage;
@property (assign, nonatomic) BOOL oldMode;
// @property (strong, nonatomic) UIRefreshControl *refreshControl;
@property (assign, nonatomic) BOOL loadingOlderMessages;
@property (assign, nonatomic) BOOL loadingNewerMessages;
@property (strong, nonatomic) UIView *typingIndicatorView;
@property (strong, nonatomic) UILabel *typingLabel;
@property (strong, nonatomic) NSMutableDictionary *typingUsers;
@property (assign, nonatomic) CGFloat keyboardHeight;
@property (strong, nonatomic) DCMessage *replyingToMessage;
@property (assign, nonatomic) BOOL disablePing;
@property (strong, nonatomic) DCMessage *editingMessage;
@property (nonatomic, retain) NSIndexPath *longPressedIndexPath;
@property (nonatomic, retain) UIColor *longPressedCellPreviousColor;
@property (nonatomic, retain) NSIndexPath *touchHighlightIndexPath;
@property (nonatomic, retain) UIColor *touchHighlightPreviousColor;
@property (nonatomic, assign) NSUInteger olderLoadGeneration;
@property (nonatomic, assign) NSUInteger newerLoadGeneration;
@property (nonatomic, assign) NSUInteger reconcileGeneration;
@property (nonatomic, copy) NSString *reconcilingChannelID;
@end

// dynamic message box vars
CGFloat _baseToolbarHeight;
CGFloat _baseInputHeight;
CGFloat _baseMsgFieldBGHeight;
CGFloat _baseInputOriginY;

static const int kProximityLoadBurst = 15;
static const NSInteger kChatWindowCeiling = 80;

@implementation DCChatViewController
@synthesize currentWindow = _currentWindow;

int lastTimeInterval = 0; // for typing indicator

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

static dispatch_queue_t chat_messages_queue;
- (dispatch_queue_t)get_chat_messages_queue {
    if (chat_messages_queue == nil) {
        chat_messages_queue = dispatch_queue_create(
            [@"Discord::API::Chat::Messages" UTF8String],
            DISPATCH_QUEUE_SERIAL
        );
    }
    return chat_messages_queue;
}

- (DCChannelWindow *)currentWindow {
    if (!_currentWindow) {
        NSString *cid = DCServerCommunicator.sharedInstance.selectedChannel.snowflake;
        if (cid) _currentWindow = [[DCMessageStore sharedInstance] windowForChannel:cid];
    }
    return _currentWindow;
}

- (NSMutableArray *)messages {
    return self.currentWindow.messages;
}

// Point the controller at the window for whatever channel is now selected.
// Called at every channel-entry point so the cached window can't go stale.
- (void)syncWindowForSelectedChannel {
    NSString *cid = DCServerCommunicator.sharedInstance.selectedChannel.snowflake;
    self.currentWindow = cid ? [[DCMessageStore sharedInstance] windowForChannel:cid] : nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [[UIApplication sharedApplication] setStatusBarHidden:NO];

    if ([[NSUserDefaults standardUserDefaults]
            boolForKey:@"experimentalMode"]) {
        [self.navigationController.navigationBar
            setBackgroundImage:[UIImage imageNamed:@"TbarBG"]
                 forBarMetrics:UIBarMetricsDefault];
    }

    [self handleSelectedChannel];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.chatTableView.transform = CGAffineTransformMakeScale(1, -1);

    DBGLOG(@"%s: Loading chat view controller", __PRETTY_FUNCTION__);

    UITapGestureRecognizer *gestureRecognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(dismissKeyboard:)];
    [self.view addGestureRecognizer:gestureRecognizer];
    gestureRecognizer.cancelsTouchesInView = NO;
    gestureRecognizer.delegate             = self;

    UILongPressGestureRecognizer *feedbackRecognizer = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleCellPressHighlight:)];
    feedbackRecognizer.minimumPressDuration = 0.1;
    feedbackRecognizer.cancelsTouchesInView = NO;
    feedbackRecognizer.delegate = self;
    [self.chatTableView addGestureRecognizer:feedbackRecognizer];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleCellLongPress:)];
    longPress.minimumPressDuration = 0.5;
    [self.chatTableView addGestureRecognizer:longPress];

    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"experimentalMode"]) {
        self.slideMenuController.bouncing = YES;
        self.slideMenuController.gestureSupport =
            APLSlideMenuGestureSupportDrag;
        self.slideMenuController.separatorColor = [UIColor grayColor];
        // Go to settings if no token is set
        if (!DCServerCommunicator.sharedInstance.token.length) {
            [self performSegueWithIdentifier:@"to Tokenpage" sender:self];
        }
    }

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(handleMessageCreate:)
               name:@"MESSAGE CREATE"
             object:nil];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(handleMessageDelete:)
               name:@"MESSAGE DELETE"
             object:nil];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(handleMessageEdit:)
               name:@"MESSAGE EDIT"
             object:nil];
    [NSNotificationCenter.defaultCenter 
        addObserver:self
           selector:@selector(emojiImageReady:)
               name:@"EMOJI IMAGE READY"
             object:nil];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(handleTyping:)
               name:@"TYPING START"
             object:nil];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(handleStopTyping:)
               name:@"TYPING STOP"
             object:nil];

    // use NUKE/RELOAD CHAT DATA very sparingly, it is very expensive and lags the chat
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleChatReset)
                                               name:@"NUKE CHAT DATA"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleAsyncReload)
                                               name:@"RELOAD CHAT DATA"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReloadUser:)
                                               name:@"RELOAD USER DATA"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReloadMessage:)
                                               name:@"RELOAD MESSAGE DATA"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleReady)
                                               name:@"READY"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleForwardReconcile)
                                               name:@"CONNECTION_RESTORED"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleForwardReconcile)
                                               name:@"BACKGROUND_RECONNECT"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleGuildMemberListUpdated:)
                                               name:@"GUILD MEMBER LIST UPDATED"
                                             object:nil];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(keyboardWillShow:)
               name:UIKeyboardWillShowNotification
             object:nil];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(keyboardWillHide:)
               name:UIKeyboardWillHideNotification
             object:nil];

    self.oldMode =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"hackyMode"];
    if (self.oldMode == NO) {
        [self.nbbar setBackgroundImage:[UIImage imageNamed:@"TbarBG"]
                         forBarMetrics:UIBarMetricsDefault];
        [self.nbmodaldone setBackgroundImage:[UIImage imageNamed:@"BarButtonDone"]
                                    forState:UIControlStateNormal
                                  barMetrics:UIBarMetricsDefault];
        [self.nbmodaldone
            setBackgroundImage:[UIImage imageNamed:@"BarButtonDonePressed"]
                      forState:UIControlStateHighlighted
                    barMetrics:UIBarMetricsDefault];

        // [[UIToolbar appearance] setBackgroundImage:[UIImage imageNamed:@"ToolbarBG"]
        //                         forToolbarPosition:UIToolbarPositionAny
        //                                 barMetrics:UIBarMetricsDefault];

        UIImage *toolbarBG = [UIImage imageNamed:@"ToolbarBG"];
        UIEdgeInsets toolbarCaps = UIEdgeInsetsMake(23, 0, 20, 0); // top/bottom caps, full width stretches center
        UIImage *stretchableToolbarBG;
        if ([toolbarBG respondsToSelector:@selector(resizableImageWithCapInsets:resizingMode:)]) {
            stretchableToolbarBG = [toolbarBG resizableImageWithCapInsets:toolbarCaps
                                                             resizingMode:UIImageResizingModeStretch];
        } else {
            stretchableToolbarBG = [toolbarBG stretchableImageWithLeftCapWidth:0 topCapHeight:10];
        }
        self.toolbarBG.image = stretchableToolbarBG;
        self.toolbar.clipsToBounds       = NO;

        CAGradientLayer *shadow = [CAGradientLayer layer];
        shadow.frame = CGRectMake(0, -3, [UIScreen mainScreen].bounds.size.width, 3);
        shadow.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                          (id)[UIColor colorWithWhite:0 alpha:0.15].CGColor];
        [self.toolbar.layer insertSublayer:shadow atIndex:0];

        [self.sidebarButton setBackgroundImage:[UIImage imageNamed:@"BarButton"]
                                      forState:UIControlStateNormal
                                    barMetrics:UIBarMetricsDefault];
        [self.sidebarButton
            setBackgroundImage:[UIImage imageNamed:@"BarButtonPressed"]
                      forState:UIControlStateHighlighted
                    barMetrics:UIBarMetricsDefault];

        [self.memberButton setBackgroundImage:[UIImage imageNamed:@"BarButton"]
                                     forState:UIControlStateNormal
                                   barMetrics:UIBarMetricsDefault];
        [self.memberButton
            setBackgroundImage:[UIImage imageNamed:@"BarButtonPressed"]
                      forState:UIControlStateHighlighted
                    barMetrics:UIBarMetricsDefault];


        [self.sendButton setBackgroundImage:[UIImage imageNamed:@"SendMessageButton"]
                                   forState:UIControlStateNormal];
        [self.sendButton setBackgroundImage:[UIImage imageNamed:@"SendMessageButtonPressed"]
                                   forState:UIControlStateHighlighted];

        [self.photoButton setBackgroundImage:[UIImage imageNamed:@"CameraButton"]
                                    forState:UIControlStateNormal];
        [self.photoButton setBackgroundImage:[UIImage imageNamed:@"CameraButtonPressed"]
                                    forState:UIControlStateHighlighted];
    }

    lastTimeInterval = 0;

    self.inputField.delegate = self;
    self.inputFieldPlaceholder.text     = DCServerCommunicator.sharedInstance.selectedChannel.writeable
            ? [NSString stringWithFormat:@"Message%@%@",
                                     ![DCServerCommunicator.sharedInstance.selectedChannel.parentGuild.name isEqualToString:@"Direct Messages"]
                                             ? @" #"
                                             : (DCServerCommunicator.sharedInstance.selectedChannel.recipients.count > 2 ? @" " : @" @"),
                                     DCServerCommunicator.sharedInstance.selectedChannel.name]
            : @"No Permission";
    self.toolbar.userInteractionEnabled = DCServerCommunicator.sharedInstance.selectedChannel.writeable;
    self.inputFieldPlaceholder.hidden   = NO;
    // resizable inputField
    _baseInputHeight      = self.inputField.frame.size.height;
    _baseMsgFieldBGHeight = self.messageFieldBG.frame.size.height;
    _baseToolbarHeight    = self.toolbar.frame.size.height;
    _baseInputOriginY = self.inputField.frame.origin.y;

    self.inputField.scrollEnabled = NO;

    self.typingIndicatorView                  = [[UIView alloc] initWithFrame:CGRectMake(
                                                                 0,
                                                                 self.view.frame.size.height - self.view.frame.origin.y - self.toolbar.height - 43,
                                                                 self.view.frame.size.width,
                                                                 20
                                                             )];
    self.typingIndicatorView.backgroundColor  = [UIColor darkGrayColor];
    self.typingIndicatorView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.typingIndicatorView.hidden           = YES;

    self.typingLabel                 = [[UILabel alloc] initWithFrame:CGRectMake(
                                                          8, 0,
                                                          self.typingIndicatorView.frame.size.width - 16,
                                                          20
                                                      )];
    self.typingLabel.font            = [UIFont systemFontOfSize:12];
    self.typingLabel.textColor       = [UIColor lightGrayColor];
    self.typingLabel.backgroundColor = [UIColor clearColor];

    [self.typingIndicatorView addSubview:self.typingLabel];
    [self.view addSubview:self.typingIndicatorView];
    self.typingUsers = [NSMutableDictionary dictionary];
    
    // Message Input bitmap
    UIImage *img = [UIImage imageNamed:@"MessageField"];
    UIEdgeInsets caps = UIEdgeInsetsMake(15, 15, 15, 15);
    
    UIImage *stretch;
    if ([img respondsToSelector:@selector(resizableImageWithCapInsets:resizingMode:)]) {
        stretch = [img resizableImageWithCapInsets:caps resizingMode:UIImageResizingModeStretch];
    } else {
        stretch = [img stretchableImageWithLeftCapWidth:15 topCapHeight:15];
    }
    
    self.messageFieldBG.image = stretch;

    if (self.oldMode) {
        [self.chatTableView registerNib:[UINib nibWithNibName:@"O-DCChatTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"OldMode Message Cell"];
        [self.chatTableView registerNib:[UINib nibWithNibName:@"O-DCChatGroupedTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"OldMode Grouped Message Cell"];
        [self.chatTableView registerNib:[UINib nibWithNibName:@"O-DCChatReplyTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"OldMode Reply Message Cell"];
        [self.chatTableView registerNib:[UINib nibWithNibName:@"O-DCUniversalTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"OldMode Universal Typehandler Cell"];
    } else {
        [self.chatTableView registerNib:[UINib nibWithNibName:@"DCChatGroupedTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"Grouped Message Cell"];
        [self.chatTableView registerNib:[UINib nibWithNibName:@"DCChatTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"Message Cell"];
        [self.chatTableView registerNib:[UINib nibWithNibName:@"DCChatReplyTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"Reply Message Cell"];
        [self.chatTableView registerNib:[UINib nibWithNibName:@"DCUniversalTableCell"
                                                       bundle:nil]
                 forCellReuseIdentifier:@"Universal Typehandler Cell"];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in self.toolbar.layer.sublayers) {
        if ([layer isKindOfClass:[CAGradientLayer class]]) {
            layer.frame = CGRectMake(0, -3, self.toolbar.bounds.size.width, 3);
            break;
        }
    }
}

- (BOOL)viewingPresentTime {
    NSString *cid = DCServerCommunicator.sharedInstance.selectedChannel.snowflake;
    if (!cid) return NO;
    return [[DCMessageStore sharedInstance] windowForChannel:cid].atPresentTime;
}

- (void)setViewingPresentTime:(BOOL)viewingPresentTime {
    NSString *cid = DCServerCommunicator.sharedInstance.selectedChannel.snowflake;
    if (!cid) return;
    [[DCMessageStore sharedInstance] windowForChannel:cid].atPresentTime = viewingPresentTime;
}

- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    self.inputFieldPlaceholder.hidden = self.inputField.text.length != 0;
    lastTimeInterval                  = 0;
    return YES;
}

- (void)textViewDidChange:(UITextView *)textView {
    self.inputFieldPlaceholder.hidden = self.inputField.text.length != 0;
    int currentTimeInterval           = [[NSDate date] timeIntervalSince1970];
    if (currentTimeInterval - lastTimeInterval >= 10) {
        [DCServerCommunicator.sharedInstance
                .selectedChannel sendTypingIndicator];
        lastTimeInterval = currentTimeInterval;
    }
    [self resizeInputField];
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    self.inputFieldPlaceholder.hidden = self.inputField.text.length != 0;
    lastTimeInterval                  = 0;
}

- (void)handleChannelLoadCold:(DCChannel *)channel {
    DCServerCommunicator.sharedInstance.selectedChannel = channel;
    [self syncWindowForSelectedChannel];

    [self.messages removeAllObjects];
    self.currentWindow.hasMoreBefore = YES;
    self.currentWindow.hasMoreAfter = NO;
    self.currentWindow.atPresentTime = YES;

    [self.chatTableView reloadData];
    [self getMessages:50 beforeMessage:nil];
}

- (void)handleChatReset {
    assertMainThread();
    DBGLOG(@"%s: Resetting chat data", __PRETTY_FUNCTION__);

    // DEBUG: chat caching disabled — drop any retained window so every entry
    // cold-loads from scratch. Also neutralizes the re-entry duplication path
    // NSString *cid = DCServerCommunicator.sharedInstance.selectedChannel.snowflake;
    // if (cid) [[DCMessageStore sharedInstance] removeWindowForChannel:cid];

    [self syncWindowForSelectedChannel];
    @autoreleasepool {
        self.selectedMessage = nil;
        self.selectedImage = nil;
        self.typingUsers = [NSMutableDictionary dictionary];
        self.replyingToMessage = nil;
        self.editingMessage = nil;
        [self.messages removeAllObjects];
        self.currentWindow.hasMoreBefore = YES;
        self.currentWindow.hasMoreAfter = NO;
        self.currentWindow.atPresentTime = YES;
        self.numberOfMessagesLoaded = 0;
        self.disablePing = NO;
    }
    self.inputFieldPlaceholder.text     = DCServerCommunicator.sharedInstance.selectedChannel.writeable
            ? [NSString stringWithFormat:@"Message%@%@",
                                     ![DCServerCommunicator.sharedInstance.selectedChannel.parentGuild.name isEqualToString:@"Direct Messages"]
                                             ? @" #"
                                             : (DCServerCommunicator.sharedInstance.selectedChannel.recipients.count > 2 ? @" " : @" @"),
                                     DCServerCommunicator.sharedInstance.selectedChannel.name]
            : @"No Permission";
    self.toolbar.userInteractionEnabled = DCServerCommunicator.sharedInstance.selectedChannel.writeable;
    self.typingIndicatorView.hidden     = YES;
    self.chatTableView.height = self.view.height - self.keyboardHeight - self.toolbar.height;
    self.typingIndicatorView.y = self.view.height - self.keyboardHeight - self.toolbar.height - 20;
    [self.chatTableView
        setContentOffset:CGPointMake(
                             0,
                             self.chatTableView.contentSize.height
                                 - self.chatTableView.frame.size.height
                         )
                animated:NO];
    [self handleAsyncReload];
    // [DCServerCommunicator.sharedInstance description];
}

- (void)handleAsyncReload {
    if (!self.chatTableView) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // NSLog(@"async reload!");
        //  about contact CoreControl
        @autoreleasepool {
            [[DCCacheManager sharedInstance] invalidateAllMessages];
            [self.chatTableView reloadData];
        }
    });
}

- (void)handleReady {
    assertMainThread();
    [self handleSelectedChannel];
}
    
- (void)handleForwardReconcile {
    assertMainThread();

    DCChannel *channel =
        DCServerCommunicator.sharedInstance.selectedChannel;
    DCChannelWindow *window = self.currentWindow;
    NSString *channelID = [channel.snowflake copy];

    if (!channel || !window || window.messages.count == 0) {
        return;
    }

    if (!window.atPresentTime || window.hasMoreAfter) {
        return;
    }

    if ([self.reconcilingChannelID isEqualToString:channelID]) {
        return;
    }

    NSUInteger generation = ++self.reconcileGeneration;
    self.reconcilingChannelID = channelID;

    DCMessage *anchor = window.messages.lastObject;

    dispatch_async([self get_chat_messages_queue], ^{
        DCMessageDelta *delta =
            [[DCMessageStore sharedInstance]
                reconcileForwardForChannel:channel
                              afterMessage:anchor];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.reconcileGeneration) {
                return;
            }

            self.reconcilingChannelID = nil;

            BOOL sameChannel =
                [DCServerCommunicator.sharedInstance.selectedChannel.snowflake
                    isEqualToString:channelID];

            if (!sameChannel || self.currentWindow != window) {
                return;
            }

            if (!delta) return;
            if (DCServerCommunicator.sharedInstance.selectedChannel != channel) return;

            if (delta.requiresFullReload) {
                [self.messages removeAllObjects];
                [self.messages addObjectsFromArray:delta.replacementMessages];
                [self.chatTableView reloadData];
                if (self.viewingPresentTime && self.messages.count > 0) {
                    [self.chatTableView setContentOffset:CGPointZero animated:NO];
                }
                return;
            }

            // Dedup against the live tail — gateway replay may have already
            // inserted some of these via MESSAGE CREATE before the fetch returned.
            NSMutableArray *toInsert = NSMutableArray.new;
            for (DCMessage *msg in delta.candidateMessages) {
                BOOL present = NO;
                for (DCMessage *existing in self.messages) {
                    if ([existing.snowflake isEqualToString:msg.snowflake]) { present = YES; break; }
                }
                if (!present) [toInsert addObject:msg];
            }
            if (toInsert.count == 0) return;

            NSMutableArray *indexPaths = NSMutableArray.new;
            NSUInteger insertCount = toInsert.count;
            for (NSUInteger i = 0; i < insertCount; i++) {
                [indexPaths addObject:[NSIndexPath indexPathForRow:i inSection:0]];
                [self.messages addObject:toInsert[i]];
            }
            [self.chatTableView beginUpdates];
            [self.chatTableView insertRowsAtIndexPaths:indexPaths
                                      withRowAnimation:UITableViewRowAnimationNone];
            [self.chatTableView endUpdates];

            if (self.messages.count >= 2) {
                NSIndexPath *previousNewestPath = [NSIndexPath indexPathForRow:insertCount inSection:0];
                [self.chatTableView beginUpdates];
                [self.chatTableView reloadRowsAtIndexPaths:@[previousNewestPath]
                                          withRowAnimation:UITableViewRowAnimationNone];
                [self.chatTableView endUpdates];
            }

            if (self.viewingPresentTime) {
                [self.chatTableView setContentOffset:CGPointZero animated:YES];
            }
        });
    });
}

- (void)handleSelectedChannel {
    NSAssert([NSThread isMainThread], @"Must activate channel on main thread");

    DCChannel *channel =
        DCServerCommunicator.sharedInstance.selectedChannel;

    if (!channel.snowflake.length || !self.chatTableView) {
        return;
    }

    DCChannelWindow *previousWindow = _currentWindow;
    [self syncWindowForSelectedChannel];

    BOOL changedWindow = previousWindow != self.currentWindow;

    // Immediately display cached content.
    [self.chatTableView reloadData];

    if (!changedWindow) {
        // Returning from a profile/modal while still viewing the same channel.
        if (self.currentWindow.atPresentTime &&
            !self.currentWindow.hasMoreAfter) {
            [self handleForwardReconcile];
        }
        return;
    }

    // Invalidate controller-global pagination requests from the old channel.
    self.olderLoadGeneration++;
    self.newerLoadGeneration++;
    self.loadingOlderMessages = NO;
    self.loadingNewerMessages = NO;

    if (self.messages.count == 0) {
        [self handleChannelLoadCold:channel];
        return;
    }

    if (self.currentWindow.hasMoreAfter) {
        [self handleChannelLoadCold:channel];
        return;
    }

    self.currentWindow.atPresentTime = YES;
    [self.chatTableView setContentOffset:CGPointZero animated:NO];
    [self handleForwardReconcile];
}

- (void)handleReloadUser:(NSNotification *)notification {
    assertMainThread();
    if (!self.chatTableView) return;

    DCUser *user = notification.object;
    for (int i = 0; i < self.messages.count; i++) {
        DCMessage *message = [self.messages objectAtIndex:i];
        BOOL authorMatches = [message.author.snowflake isEqualToString:user.snowflake];
        BOOL refAuthorMatches = [message.referencedMessage.author.snowflake isEqualToString:user.snowflake];
        if (!authorMatches && !refAuthorMatches) continue;

        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self rowForModelIndex:i] inSection:0];
        DCChatTableCell *cell = (DCChatTableCell *)[self.chatTableView cellForRowAtIndexPath:indexPath];
        if (!cell) {
            // Cell is off-screen — clear configuredSnowflake so it 
            // reconfigures correctly when it scrolls back into view
            [[DCCacheManager sharedInstance] invalidateSnowflake:message.snowflake];
            continue;
        }
        if (authorMatches) {
            cell.profileImage.image = user.profileImage;
            DCMessageLayout *layout = [self layoutForModelIndex:i];
            if (!layout.grouped) {
                NSString *displayName = [user displayNameInGuild:
                    DCServerCommunicator.sharedInstance.selectedChannel.parentGuild];
                if (displayName) {
                    cell.authorLabel.text = displayName;
                }
            }
        }
        if (refAuthorMatches) {
            cell.referencedProfileImage.image = user.profileImage;
        }
    }
}

- (void)handleReloadMessage:(NSNotification *)notification {
    assertMainThread();
    if (!self.chatTableView) {
        return;
    }

    NSInteger rowCount = [self.chatTableView numberOfRowsInSection:0];
    if (rowCount != self.messages.count) {
        NSLog(@"%s: Row count mismatch! Expected %ld but got %ld", __PRETTY_FUNCTION__, (long)self.messages.count, (long)rowCount);
        [self handleAsyncReload];
        return;
    }

    DCMessage *message = notification.object;
    NSUInteger index   = [self.messages indexOfObject:message];
    if (index == NSNotFound || index >= self.messages.count) {
        return;
    }
    [[DCCacheManager sharedInstance] invalidateSnowflake:message.snowflake];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self rowForModelIndex:index] inSection:0];
    [self.chatTableView beginUpdates];
    [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
    [self.chatTableView endUpdates];
    // [self scrollWithIndex:indexPath];
}

- (void)handleMessageCreate:(NSNotification *)notification {
    assertMainThread();
    DCMessage *newMessage = [DCTools convertJsonMessage:notification.userInfo];

    NSString *channelID = notification.userInfo[@"channel_id"];
    if (![channelID isEqualToString:self.currentWindow.channelSnowflake]) {
        return;
    }

    if (self.currentWindow.hasMoreAfter) {
        NSAssert(!self.currentWindow.atPresentTime,
                 @"A present-time window cannot also have newer messages missing");
        return;
    }

    if (!newMessage.author.profileImage) {
        [DCTools getUserAvatar:newMessage.author];
    }

    NSInteger rowCount = [self.chatTableView numberOfRowsInSection:0];
    [self.messages addObject:newMessage];
    NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:0 inSection:0];
    if (rowCount != self.messages.count - 1) {
        NSLog(@"%s: Row count mismatch! Expected %ld but got %ld", __PRETTY_FUNCTION__, (long)self.messages.count, (long)rowCount);
        [self handleAsyncReload];
    } else {
        [self.chatTableView beginUpdates];
        [self.chatTableView insertRowsAtIndexPaths:@[ newIndexPath ] withRowAnimation:UITableViewRowAnimationNone];
        [self.chatTableView endUpdates];
        if (self.messages.count >= 2) {
            NSIndexPath *prevPath = [NSIndexPath indexPathForRow:1 inSection:0];
            [self.chatTableView beginUpdates];
            [self.chatTableView reloadRowsAtIndexPaths:@[prevPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
            [self.chatTableView endUpdates];
        }
    }

    if (self.viewingPresentTime) {
        [self.chatTableView setContentOffset:CGPointZero animated:YES];
        [self evictOldestDownToCeiling];
    }
}

- (void)handleGuildMemberListUpdated:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleGuildMemberListUpdated:notification];
        });
        return;
    }

    if (!self.chatTableView || !self.currentWindow) {
        return;
    }

    /*
     * Force layoutForModelIndex: to return new layout objects.
     * Otherwise cell.configuredLayout == layout may take the fast path
     * and preserve the old username label.
     */
    for (DCMessage *message in self.messages) {
        [[DCCacheManager sharedInstance]
            invalidateSnowflake:message.snowflake];

        //Reply positioning depends on the displayed author-name width.
        DCMessage *referenced = message.referencedMessage;
        if (referenced.author) {
            NSString *name = [referenced.author
                displayNameInGuild:
                    DCServerCommunicator.sharedInstance
                        .selectedChannel.parentGuild];

            CGFloat contentWidth =
                UIScreen.mainScreen.bounds.size.width - 63;

            CGSize nameSize =
                [name sizeWithFont:[UIFont boldSystemFontOfSize:10]
                 constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                     lineBreakMode:
                         (NSLineBreakMode)UILineBreakModeWordWrap];

            referenced.authorNameWidth = 80 + nameSize.width;
        }
    }

    [self.chatTableView reloadData];
}

- (void)handleMessageEdit:(NSNotification *)notification {
    assertMainThread();
    NSString *snowflake = [notification.userInfo objectForKey:@"id"];
    if (!snowflake || snowflake.length == 0) {
        NSLog(@"%s: No snowflake provided for message edit", __PRETTY_FUNCTION__);
        return;
    }
    NSUInteger index = [self.messages indexOfObjectPassingTest:^BOOL(DCMessage *msg, NSUInteger idx, BOOL *stop) {
        return [msg.snowflake isEqualToString:snowflake];
    }];
    if (index == NSNotFound || index >= self.messages.count) {
        NSLog(@"%s: Message with snowflake %@ not found", __PRETTY_FUNCTION__, snowflake);
        return;
    }
    DCMessage *compareMessage = [self.messages objectAtIndex:index];

    DCMessage *newMessage = [DCTools convertJsonMessage:notification.userInfo];

    // fix any potential missing fields from a partial response
    if (newMessage.author == nil || (NSNull *)newMessage.author == [NSNull null]) {
        newMessage.author = compareMessage.author;
        newMessage.contentHeight +=
            compareMessage.contentHeight; // assume it's an embed update
    }
    if (newMessage.content == nil || (NSNull *)newMessage.content == [NSNull null]) {
        newMessage.content = compareMessage.content;
    }
    if ((newMessage.attachments == nil || (NSNull *)newMessage.attachments == [NSNull null])
        && newMessage.attachmentCount > 0) {
        newMessage.attachments = compareMessage.attachments;
    }
    newMessage.timestamp = compareMessage.timestamp;
    if (newMessage.editedTimestamp == nil
        || (NSNull *)newMessage.editedTimestamp == [NSNull null]) {
        newMessage.editedTimestamp = compareMessage.editedTimestamp;
    }
    newMessage.prettyTimestamp   = compareMessage.prettyTimestamp;
    newMessage.referencedMessage = compareMessage.referencedMessage;

    NSInteger rowCount = [self.chatTableView numberOfRowsInSection:0];
    NSUInteger idx     = [self.messages indexOfObject:compareMessage];
    if (rowCount != self.messages.count) {
        NSLog(@"%s: Row count mismatch! Expected %ld but got %ld", __PRETTY_FUNCTION__, (long)self.messages.count, (long)rowCount);
        [self.messages replaceObjectAtIndex:idx
                                 withObject:newMessage];
        [self handleAsyncReload];
        return;
    }
    [self.chatTableView beginUpdates];
    [self.messages replaceObjectAtIndex:idx withObject:newMessage];

    // Invalidate layout for the edited message and both neighbors —
    // B's own height may change, A.followedByGrouped and C.grouped
    // may change if B's groupability changed.
    if (idx > 0)
        [[DCCacheManager sharedInstance] invalidateSnowflake:((DCMessage *)self.messages[idx - 1]).snowflake];
    [[DCCacheManager sharedInstance] invalidateSnowflake:newMessage.snowflake];
    if (idx + 1 < self.messages.count)
        [[DCCacheManager sharedInstance] invalidateSnowflake:((DCMessage *)self.messages[idx + 1]).snowflake];

    NSMutableArray *reloadPaths = [NSMutableArray array];
    if (idx > 0)
        [reloadPaths addObject:[NSIndexPath indexPathForRow:[self rowForModelIndex:idx - 1] inSection:0]];
    [reloadPaths addObject:[NSIndexPath indexPathForRow:[self rowForModelIndex:idx] inSection:0]];
    if (idx + 1 < self.messages.count)
        [reloadPaths addObject:[NSIndexPath indexPathForRow:[self rowForModelIndex:idx + 1] inSection:0]];

    [self.chatTableView reloadRowsAtIndexPaths:reloadPaths withRowAnimation:UITableViewRowAnimationAutomatic];
    [self.chatTableView endUpdates];
}

- (void)handleMessageDelete:(NSNotification *)notification {
    assertMainThread();
    if (!self.messages || self.messages.count == 0) {
        return;
    }

    NSUInteger index = [self.messages indexOfObjectPassingTest:^BOOL(DCMessage *msg, NSUInteger idx, BOOL *stop) {
        return [msg.snowflake isEqualToString:[notification.userInfo objectForKey:@"id"]];
    }];
    if (index == NSNotFound || index >= self.messages.count) {
        return;
    }

    NSInteger rowCount = [self.chatTableView numberOfRowsInSection:0];
    if (rowCount != self.messages.count) {
        NSLog(@"%s: Row count mismatch! Expected %ld but got %ld", __PRETTY_FUNCTION__, (long)self.messages.count, (long)rowCount);
        [self.messages removeObjectAtIndex:index];
        [self handleAsyncReload];
    } else {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self rowForModelIndex:index] inSection:0];
        [self.chatTableView beginUpdates];
        [self.messages removeObjectAtIndex:index];
        [self.chatTableView deleteRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationAutomatic];
        [self.chatTableView endUpdates];
    }
}

- (void)handleTyping:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleTyping:notification];
        });
        return;
    }
    if (!self.typingIndicatorView) {
        DBGLOG(@"%s: Typing indicator view is not initialized", __PRETTY_FUNCTION__);
        return;
    }

    NSString *typingUserId = notification.object;
    if (!typingUserId) {
        DBGLOG(@"%s: No typing user provided", __PRETTY_FUNCTION__);
        return;
    }

    if ([typingUserId isEqualToString:DCServerCommunicator.sharedInstance.snowflake]) {
        // Ignore typing events from the current user
        return;
    }

    NSTimer *existingTimer = [self.typingUsers objectForKey:typingUserId];
    if (existingTimer) {
        [existingTimer invalidate];
        [self.typingUsers removeObjectForKey:typingUserId];
    }

    self.typingUsers[typingUserId] = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                                      target:self
                                                                    selector:@selector(typingTimerFired:)
                                                                    userInfo:typingUserId
                                                                     repeats:NO];
    // NSLog(@"%s: User %@ is typing, count: %lu", __PRETTY_FUNCTION__, ((DCUser *)[DCServerCommunicator.sharedInstance.loadedUsers objectForKey:typingUserId]).globalName, (unsigned long)self.typingUsers.count);
    [self updateTypingIndicator];
}

- (void)handleStopTyping:(NSNotification *)notification {
    if (!self.typingIndicatorView) {
        DBGLOG(@"%s: Typing indicator view is not initialized", __PRETTY_FUNCTION__);
        return;
    }

    NSString *typingUserId = notification.object;
    if (!typingUserId) {
        DBGLOG(@"%s: No typing user provided", __PRETTY_FUNCTION__);
        return;
    }

    if ([typingUserId isEqualToString:DCServerCommunicator.sharedInstance.snowflake]) {
        // Ignore typing events from the current user
        return;
    }

    NSTimer *existingTimer = [self.typingUsers objectForKey:typingUserId];
    if (existingTimer) {
        [existingTimer invalidate];
        [self.typingUsers removeObjectForKey:typingUserId];
    }
    // NSLog(@"%s: User %@ stopped typing, count: %lu", __PRETTY_FUNCTION__, ((DCUser *)[DCServerCommunicator.sharedInstance.loadedUsers objectForKey:typingUserId]).globalName, (unsigned long)self.typingUsers.count);
    [self updateTypingIndicator];
}

- (void)handleCellLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    CGPoint point = [recognizer locationInView:self.chatTableView];
    NSIndexPath *indexPath = [self.chatTableView indexPathForRowAtPoint:point];
    if (!indexPath || indexPath.row >= (NSInteger)self.messages.count) return;

    self.longPressedIndexPath        = self.touchHighlightIndexPath;
    self.touchHighlightIndexPath     = nil;

    DCMessage *pressed = [self.messages objectAtIndex:[self modelIndexForRow:indexPath.row]];
    self.selectedMessage = pressed;

    NSString *replyButton = self.replyingToMessage
            && [self.replyingToMessage.snowflake isEqualToString:self.selectedMessage.snowflake]
        ? @"Cancel Reply"
        : @"Reply";

    if ([self.selectedMessage.author.snowflake
            isEqualToString:DCServerCommunicator.sharedInstance.snowflake]) {
        NSString *editButton = self.editingMessage
                && [self.editingMessage.snowflake isEqualToString:self.selectedMessage.snowflake]
            ? @"Cancel Edit"
            : @"Edit";
        UIActionSheet *messageActionSheet =
            [[UIActionSheet alloc] initWithTitle:self.selectedMessage.content
                                        delegate:self
                               cancelButtonTitle:@"Cancel"
                          destructiveButtonTitle:@"Delete"
                               otherButtonTitles:editButton,
                                                 replyButton,
                                                 @"Copy Message",
                                                 @"Copy Message ID",
                                                 nil];
        messageActionSheet.tag = 1;
        messageActionSheet.delegate = self;
        [messageActionSheet showFromRect:self.toolbar.frame inView:self.view animated:YES];
    } else {
        UIActionSheet *messageActionSheet = [[UIActionSheet alloc]
                     initWithTitle:self.selectedMessage.content
                          delegate:self
                 cancelButtonTitle:nil
            destructiveButtonTitle:nil
                 otherButtonTitles:nil];
        [messageActionSheet addButtonWithTitle:replyButton];
        if (self.replyingToMessage
            && [self.replyingToMessage.snowflake
                isEqualToString:self.selectedMessage.snowflake]) {
            [messageActionSheet addButtonWithTitle:self.disablePing
                ? @"Enable Ping" : @"Disable Ping"];
        }
        [messageActionSheet addButtonWithTitle:@"Mention"];
        [messageActionSheet addButtonWithTitle:@"Copy Message"];
        [messageActionSheet addButtonWithTitle:@"Copy Message ID"];
        messageActionSheet.cancelButtonIndex = [messageActionSheet addButtonWithTitle:@"Cancel"];
        messageActionSheet.tag = 3;
        messageActionSheet.delegate = self;
        [messageActionSheet showFromRect:self.toolbar.frame inView:self.view animated:YES];
    }
}

- (void)handleCellPressHighlight:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [recognizer locationInView:self.chatTableView];
        NSIndexPath *indexPath = [self.chatTableView indexPathForRowAtPoint:point];
        if (!indexPath || indexPath.row >= (NSInteger)self.messages.count) return;

        UITableViewCell *cell = [self.chatTableView cellForRowAtIndexPath:indexPath];
        if (!cell) return;

        self.touchHighlightIndexPath = indexPath;
        UIView *overlay = [[UIView alloc] initWithFrame:cell.contentView.bounds];
        overlay.tag = 9999;
        overlay.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.08f];
        overlay.userInteractionEnabled = NO;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:overlay];

    } else if (recognizer.state == UIGestureRecognizerStateEnded
               || recognizer.state == UIGestureRecognizerStateCancelled
               || recognizer.state == UIGestureRecognizerStateFailed) {
        // Belt-and-suspenders: strip overlay from any visible cell that has one
        for (UITableViewCell *visibleCell in self.chatTableView.visibleCells) {
            [[visibleCell.contentView viewWithTag:9999] removeFromSuperview];
        }
        self.touchHighlightIndexPath = nil;
    }
}

- (void)typingTimerFired:(NSTimer *)timer {
    NSString *typingUserId = timer.userInfo;
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"TYPING STOP"
                      object:typingUserId];
}

- (void)updateTypingIndicator {
    assertMainThread();
    if (self.typingUsers.count == 0) {
        [self.chatTableView
            setHeight:self.view.height - self.keyboardHeight - self.toolbar.height];
        self.typingIndicatorView.hidden = YES;
        return;
    }

    NSMutableArray *typingNames = [NSMutableArray array];
    for (NSString *userId in self.typingUsers.allKeys) {
        DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:userId];
        if (user) {
            [typingNames addObject:[user displayName]];
        }
    }

    NSString *typingText;
    if (typingNames.count == 1) {
        typingText = [NSString stringWithFormat:@"%@ is typing...", typingNames.firstObject];
    } else if (typingNames.count == 2) {
        typingText = [NSString stringWithFormat:@"%@ and %@ are typing...", typingNames[0], typingNames[1]];
    } else if (typingNames.count == 3) {
        typingText = [NSString stringWithFormat:@"%@, %@, and %@ are typing...", typingNames[0], typingNames[1], typingNames[2]];
    } else {
        typingText = @"Several users are typing...";
    }

    self.typingLabel.text           = typingText;
    self.typingIndicatorView.hidden = NO;
    [self.typingIndicatorView setNeedsDisplay];
    [self.chatTableView
        setHeight:self.view.height - self.keyboardHeight - 20 - self.toolbar.height];
    [self.typingIndicatorView setY:self.view.height - self.keyboardHeight - self.toolbar.height - 20];
}

- (void)getMessages:(int)numberOfMessages beforeMessage:(DCMessage *)message {
    NSAssert([NSThread isMainThread],
             @"getMessages:beforeMessage: must run on the main thread");

    DCChannel *channel = DCServerCommunicator.sharedInstance.selectedChannel;
    DCChannelWindow *targetWindow = self.currentWindow;
    NSString *channelId = [channel.snowflake copy];

    NSUInteger loadGeneration = ++self.olderLoadGeneration;
    self.loadingOlderMessages = YES;

    dispatch_async([self get_chat_messages_queue], ^{
        NSArray *newMessages =
            [[DCMessageStore sharedInstance] loadBeforeForChannel:channel
                                                    beforeMessage:message
                                                            limit:numberOfMessages];

        if (!newMessages) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // A newer older-message load now owns the flag.
                if (loadGeneration != self.olderLoadGeneration) {
                    return;
                }

                self.loadingOlderMessages = NO;
            });

            return;
        }

        for (DCMessage *newMessage in newMessages) {
            @autoreleasepool {
                if (!newMessage.author.profileImage) {
                    [DCTools getUserAvatar:newMessage.author];
                }

                if (newMessage.referencedMessage &&
                    newMessage.referencedMessage.author &&
                    !newMessage.referencedMessage.author.profileImage) {
                    [DCTools getUserAvatar:newMessage.referencedMessage.author];
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            /*
             * A newer request superseded this one. Do not modify the table,
             * window, or loading flag because those now belong to that request.
             */
            if (loadGeneration != self.olderLoadGeneration) {
                return;
            }

            BOOL sameChannel =
                [DCServerCommunicator.sharedInstance.selectedChannel.snowflake
                    isEqualToString:channelId];

            BOOL sameWindow = self.currentWindow == targetWindow;

            if (!sameChannel || !sameWindow) {
                self.loadingOlderMessages = NO;
                return;
            }

            NSArray *deduped = [self deduplicateAgainstWindow:newMessages];

            if (deduped.count == 0) {
                self.loadingOlderMessages = NO;
                return;
            }

            NSUInteger oldCount = self.messages.count;

            [self.messages insertObjects:deduped
                               atIndexes:[NSIndexSet
                                   indexSetWithIndexesInRange:
                                       NSMakeRange(0, deduped.count)]];

            BOOL didReload = NO;
            NSInteger rowCount =
                [self.chatTableView numberOfRowsInSection:0];

            if (rowCount != (NSInteger)oldCount) {
                [self.chatTableView reloadData];
                didReload = YES;
            } else {
                NSMutableArray *indexPaths =
                    [NSMutableArray arrayWithCapacity:deduped.count];

                for (NSUInteger row = oldCount;
                     row < self.messages.count;
                     row++) {
                    [indexPaths addObject:
                        [NSIndexPath indexPathForRow:row
                                         inSection:0]];
                }

                [UIView setAnimationsEnabled:NO];

                [self.chatTableView beginUpdates];
                [self.chatTableView insertRowsAtIndexPaths:indexPaths
                                          withRowAnimation:
                                              UITableViewRowAnimationNone];
                [self.chatTableView endUpdates];

                [UIView setAnimationsEnabled:YES];
            }

            /*
             * A nil anchor represents the initial/latest-message load.
             */
            if (message == nil) {
                self.chatTableView.contentOffset = CGPointZero;
            } else {
                NSInteger evictCount =
                    (NSInteger)self.messages.count - kChatWindowCeiling;

                if (evictCount > 0) {
                    CGFloat evictedHeight = 0.0;

                    /*
                     * These are rows at the visual newest edge. Calculate
                     * their height before deleting them.
                     */
                    if (!didReload) {
                        for (NSInteger row = 0;
                             row < evictCount;
                             row++) {
                            NSIndexPath *indexPath =
                                [NSIndexPath indexPathForRow:row
                                                 inSection:0];

                            evictedHeight +=
                                [self.chatTableView
                                    rectForRowAtIndexPath:indexPath].size.height;
                        }
                    }

                    NSRange tailRange =
                        NSMakeRange(self.messages.count - evictCount,
                                    evictCount);

                    NSArray *evictedMessages =
                        [self.messages subarrayWithRange:tailRange];

                    for (DCMessage *evictedMessage in evictedMessages) {
                        for (id attachment in evictedMessage.attachments) {
                            if ([attachment
                                    isKindOfClass:[UILazyImage class]]) {
                                ((UILazyImage *)attachment).image = nil;
                            }
                        }
                    }

                    [self.messages removeObjectsInRange:tailRange];

                    /*
                     * The model no longer contains the live/newest edge.
                     */
                    targetWindow.hasMoreAfter = YES;
                    targetWindow.atPresentTime = NO;

                    if (!didReload) {
                        NSMutableArray *evictPaths =
                            [NSMutableArray
                                arrayWithCapacity:evictCount];

                        for (NSInteger row = 0;
                             row < evictCount;
                             row++) {
                            [evictPaths addObject:
                                [NSIndexPath indexPathForRow:row
                                                 inSection:0]];
                        }

                        [UIView setAnimationsEnabled:NO];

                        [self.chatTableView beginUpdates];
                        [self.chatTableView
                            deleteRowsAtIndexPaths:evictPaths
                                  withRowAnimation:
                                      UITableViewRowAnimationNone];
                        [self.chatTableView endUpdates];

                        [UIView setAnimationsEnabled:YES];

                        CGPoint offset =
                            self.chatTableView.contentOffset;

                        offset.y =
                            MAX(0.0, offset.y - evictedHeight);

                        self.chatTableView.contentOffset = offset;
                    } else {
                        [self.chatTableView reloadData];
                    }
                }
            }

            self.loadingOlderMessages = NO;
        });

        /*
         * Determine validity on the main thread because selectedChannel and
         * currentWindow are UI/controller state.
         */
        dispatch_async(dispatch_get_main_queue(), ^{
            if (loadGeneration != self.olderLoadGeneration) {
                return;
            }

            BOOL sameChannel =
                [DCServerCommunicator.sharedInstance.selectedChannel.snowflake
                    isEqualToString:channelId];

            BOOL sameWindow = self.currentWindow == targetWindow;

            if (!sameChannel || !sameWindow) {
                return;
            }

            dispatch_async(
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),
                ^{
                    [self.messageLayoutBuilder
                        prewarmLayoutCacheForMessages:newMessages];
                });
        });
    });
}

- (void)getNewerMessages:(int)numberOfMessages afterMessage:(DCMessage *)message {
    NSAssert([NSThread isMainThread],
             @"getNewerMessages:afterMessage: must be called on the main thread");

    DCChannel *channel =
        DCServerCommunicator.sharedInstance.selectedChannel;

    DCChannelWindow *targetWindow = self.currentWindow;
    NSString *channelId = [channel.snowflake copy];

    /*
     * This request now owns loadingNewerMessages. Any previous newer-message
     * request becomes stale and must not modify the table or loading flag.
     */
    NSUInteger loadGeneration = ++self.newerLoadGeneration;
    self.loadingNewerMessages = YES;

    dispatch_async([self get_chat_messages_queue], ^{
        NSArray *newMessages =
            [[DCMessageStore sharedInstance]
                loadAfterForChannel:channel
                       afterMessage:message
                              limit:numberOfMessages];

        if (!newMessages) {
            dispatch_async(dispatch_get_main_queue(), ^{
                /*
                 * Do not clear the loading flag if a newer request has
                 * superseded this one.
                 */
                if (loadGeneration != self.newerLoadGeneration) {
                    return;
                }

                self.loadingNewerMessages = NO;
            });

            return;
        }

        for (DCMessage *newMessage in newMessages) {
            @autoreleasepool {
                if (!newMessage.author.profileImage) {
                    [DCTools getUserAvatar:newMessage.author];
                }

                if (newMessage.referencedMessage &&
                    newMessage.referencedMessage.author &&
                    !newMessage.referencedMessage.author.profileImage) {
                    [DCTools
                        getUserAvatar:newMessage.referencedMessage.author];
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            /*
             * A newer request now owns the controller's loading state.
             * This result must not touch anything.
             */
            if (loadGeneration != self.newerLoadGeneration) {
                return;
            }

            BOOL sameChannel =
                [DCServerCommunicator.sharedInstance.selectedChannel.snowflake
                    isEqualToString:channelId];

            BOOL sameWindow = self.currentWindow == targetWindow;

            if (!sameChannel || !sameWindow) {
                self.loadingNewerMessages = NO;
                return;
            }

            NSArray *deduped =
                [self deduplicateAgainstWindow:newMessages];

            if (deduped.count == 0) {
                self.loadingNewerMessages = NO;
                return;
            }

            NSUInteger oldCount = self.messages.count;

            NSInteger rowCount =
                [self.chatTableView numberOfRowsInSection:0];

            BOOL didReload =
                rowCount != (NSInteger)oldCount;

            /*
             * Newer messages append to the model tail. In the flipped table,
             * the model tail maps to rows beginning at zero.
             */
            [self.messages addObjectsFromArray:deduped];

            if (didReload) {
                [self.chatTableView reloadData];
            } else {
                NSMutableArray *indexPaths =
                    [NSMutableArray
                        arrayWithCapacity:deduped.count];

                for (NSUInteger row = 0;
                     row < deduped.count;
                     row++) {
                    [indexPaths addObject:
                        [NSIndexPath indexPathForRow:row
                                         inSection:0]];
                }

                [UIView setAnimationsEnabled:NO];

                [self.chatTableView beginUpdates];
                [self.chatTableView
                    insertRowsAtIndexPaths:indexPaths
                          withRowAnimation:
                              UITableViewRowAnimationNone];
                [self.chatTableView endUpdates];

                /*
                 * The previously newest visible message is now immediately
                 * after the inserted block—not necessarily row 1 when more
                 * than one message was inserted.
                 */
                NSUInteger previousNewestRow = deduped.count;

                if (oldCount > 0 &&
                    previousNewestRow < self.messages.count) {
                    NSIndexPath *previousNewestPath =
                        [NSIndexPath
                            indexPathForRow:previousNewestRow
                                 inSection:0];

                    [self.chatTableView beginUpdates];
                    [self.chatTableView
                        reloadRowsAtIndexPaths:
                            @[ previousNewestPath ]
                              withRowAnimation:
                                  UITableViewRowAnimationNone];
                    [self.chatTableView endUpdates];
                }

                [UIView setAnimationsEnabled:YES];

                /*
                 * Preserve the user's visual position. Adding rows at the
                 * content-top pushes all existing rows downward.
                 */
                CGFloat addedHeight = 0.0;

                for (NSUInteger row = 0;
                     row < deduped.count;
                     row++) {
                    NSIndexPath *indexPath =
                        [NSIndexPath indexPathForRow:row
                                         inSection:0];

                    addedHeight +=
                        [self.chatTableView
                            rectForRowAtIndexPath:indexPath].size.height;
                }

                CGPoint offset =
                    self.chatTableView.contentOffset;

                offset.y += addedHeight;
                self.chatTableView.contentOffset = offset;
            }

            /*
             * Trim the opposite edge only when the table and model were in
             * sync for the incremental insertion. Preserve the existing
             * reload fallback behavior otherwise.
             */
            if (!didReload) {
                [self evictOldestDownToCeiling];
            }

            self.loadingNewerMessages = NO;
        });

        /*
         * Validate UI-owned state on the main thread before scheduling
         * optional background prewarming.
         */
        dispatch_async(dispatch_get_main_queue(), ^{
            if (loadGeneration != self.newerLoadGeneration) {
                return;
            }

            BOOL sameChannel =
                [DCServerCommunicator.sharedInstance.selectedChannel.snowflake
                    isEqualToString:channelId];

            BOOL sameWindow = self.currentWindow == targetWindow;

            if (!sameChannel || !sameWindow) {
                return;
            }

            dispatch_async(
                dispatch_get_global_queue(
                    DISPATCH_QUEUE_PRIORITY_LOW, 0),
                ^{
                    [self.messageLayoutBuilder
                        prewarmLayoutCacheForMessages:newMessages];
                });
        });
    });
}

- (NSInteger)modelIndexForRow:(NSInteger)row {
    return (NSInteger)self.messages.count - 1 - row;
}

- (NSInteger)rowForModelIndex:(NSInteger)index {
    return (NSInteger)self.messages.count - 1 - index;
}

- (DCMessageLayoutBuilder *)messageLayoutBuilder {
    if (!_messageLayoutBuilder) {
        _messageLayoutBuilder = [DCMessageLayoutBuilder new];
    }
    return _messageLayoutBuilder;
}

- (DCMessageLayout *)layoutForModelIndex:(NSInteger)modelIndex {
    assertMainThread();
    if (modelIndex < 0 || modelIndex >= (NSInteger)self.messages.count) return nil;

    DCMessage *message = self.messages[modelIndex];
    DCMessage *previousMessage = (modelIndex > 0) ? self.messages[modelIndex - 1] : nil;
    DCMessage *nextMessage = (modelIndex + 1 < (NSInteger)self.messages.count)
        ? self.messages[modelIndex + 1] : nil;
    CGFloat tableWidth = self.chatTableView.bounds.size.width;

    BOOL hasUnloadedAttachments = NO;
    for (id attachment in message.attachments) {
        if ([attachment isKindOfClass:[NSArray class]] ||
            ([attachment isKindOfClass:[DCGifInfo class]] && !((DCGifInfo *)attachment).staticThumbnail)) {
            hasUnloadedAttachments = YES;
            break;
        }
    }

    if (!hasUnloadedAttachments) {
        DCMessageLayout *cached = [[DCCacheManager sharedInstance]
            layoutForSnowflake:message.snowflake
                     tableWidth:tableWidth
              previousSnowflake:previousMessage.snowflake
                  nextSnowflake:nextMessage.snowflake
                editedTimestamp:message.editedTimestamp];
        if (cached) return cached;
    }

    DCMessageLayout *layout = [self.messageLayoutBuilder layoutForMessage:message
                                                            previousMessage:previousMessage
                                                                 nextMessage:nextMessage
                                                                  tableWidth:tableWidth];

    if (!hasUnloadedAttachments) {
        [[DCCacheManager sharedInstance] setLayout:layout
                                        forSnowflake:message.snowflake
                                          tableWidth:tableWidth
                                   previousSnowflake:previousMessage.snowflake
                                       nextSnowflake:nextMessage.snowflake
                                     editedTimestamp:message.editedTimestamp];
    }

    return layout;
}

- (void)invalidateHeightCacheFor:(DCMessage *)m {
    if (!m.snowflake) return;
    [[DCCacheManager sharedInstance] invalidateSnowflake:m.snowflake];
}

- (void)invalidateOlderMessageLoad {
    NSAssert([NSThread isMainThread],
             @"Older message loads must be invalidated on the main thread");

    self.olderLoadGeneration++;
    self.loadingOlderMessages = NO;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DCChatTableCell *cell;

    @autoreleasepool {
        if (!self.messages || [self.messages count] <= indexPath.row) {
            NSCAssert(self.messages, @"Messages array is nil");
            NSCAssert([self.messages count] > indexPath.row, @"Invalid indexPath");
        }
        DCMessage *messageAtRowIndex = [self.messages objectAtIndex:[self modelIndexForRow:indexPath.row]];

        if (self.oldMode) {
            // NSSet *specialMessageTypes =
            //     [NSSet setWithArray:@[ @1, @2, @3, @4, @5, @6, @7, @8, @18 ]];

            // if (messageAtRowIndex.isGrouped
            //     && ![specialMessageTypes
            //         containsObject:@(messageAtRowIndex.messageType)]) {
            //     cell = [tableView dequeueReusableCellWithIdentifier:
            //                           @"OldMode Grouped Message Cell"];
            // } else if (messageAtRowIndex.referencedMessage != nil) {
            //     cell = [tableView dequeueReusableCellWithIdentifier:
            //                           @"OldMode Reply Message Cell"];
            // } else if ([specialMessageTypes
            //                containsObject:@(messageAtRowIndex.messageType)]) {
            //     cell = [tableView dequeueReusableCellWithIdentifier:
            //                           @"OldMode Universal Typehandler Cell"];
            // } else {
            //     cell = [tableView
            //         dequeueReusableCellWithIdentifier:@"OldMode Message Cell"];
            // }

            // if (messageAtRowIndex.referencedMessage != nil) {
            //     cell.referencedAuthorLabel.text = [messageAtRowIndex.referencedMessage.author 
            //         displayNameInGuild:DCServerCommunicator.sharedInstance.selectedChannel.parentGuild];
            //     cell.referencedMessage.text     = messageAtRowIndex.referencedMessage.content;
            //     cell.referencedMessage.frame    = CGRectMake(
            //         messageAtRowIndex.referencedMessage.authorNameWidth,
            //         cell.referencedMessage.y,
            //         self.chatTableView.width - messageAtRowIndex.authorNameWidth,
            //         cell.referencedMessage.height
            //     );

            //     if (messageAtRowIndex.referencedMessage.author.profileImage) {
            //         cell.referencedProfileImage.image =
            //             messageAtRowIndex.referencedMessage.author.profileImage;
            //     } else {
            //         [DCTools getUserAvatar:messageAtRowIndex.referencedMessage.author];
            //     }
            // }

            // if (!messageAtRowIndex.isGrouped) {
            //     cell.authorLabel.text = [messageAtRowIndex.author 
            //         displayNameInGuild:DCServerCommunicator.sharedInstance.selectedChannel.parentGuild];
            // }

            // cell.contentTextView.text = messageAtRowIndex.content;

            // cell.contentTextView.height = [cell.contentTextView
            //                                   sizeThatFits:CGSizeMake(
            //                                                    cell.contentTextView.width, MAXFLOAT
            //                                                )]
            //                                   .height;

            // if (!messageAtRowIndex.isGrouped) {
            //     cell.profileImage.image = messageAtRowIndex.author.profileImage;
            // }

            // cell.contentView.backgroundColor = messageAtRowIndex.pingingUser
            //     ? [UIColor redColor]
            //     : [UIColor clearColor];

            // // NSLog(@"%@", cell.subviews);
            // cell.contentTextView.hidden = NO;
            // for (UIView *subView in cell.subviews) {
            //     @autoreleasepool {
            //         if ([subView isKindOfClass:[UILazyImageView class]]
            //          || [subView isKindOfClass:[DCChatVideoAttachment class]]
            //          || [subView isKindOfClass:[QLPreviewController class]]
            //          || [subView isKindOfClass:[UIActivityIndicatorView class]]
            //             ) {
            //             [subView removeFromSuperview];
            //         }
            //     }
            // }
            // // dispatch_async(dispatch_get_main_queue(), ^{
            // float contentWidth = self.chatTableView.width - 63;
            // CGSize textSize = [messageAtRowIndex.content
            //          sizeWithFont:[UIFont systemFontOfSize:14]
            //     constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
            //         lineBreakMode:NSLineBreakByWordWrapping];
            // CGFloat correctTextHeight = ceil(textSize.height) + 2;
            // int imageViewOffset = correctTextHeight + 37;

            // // NSLog(@"[Message] snowflake: %@ attachmentCount: %d attachments: %lu", 
            // //     messageAtRowIndex.snowflake, 
            // //     messageAtRowIndex.attachmentCount,
            // //     (unsigned long)messageAtRowIndex.attachments.count);
            // for (id attachment in messageAtRowIndex.attachments) {
            //     NSLog(@"[Attachment] class: %@", NSStringFromClass([attachment class]));
            //     @autoreleasepool {
            //         if ([attachment isKindOfClass:[UILazyImage class]]) {
            //             UILazyImage *lazyImage     = attachment;
            //             UILazyImageView *imageView = [UILazyImageView new];
            //             imageView.frame            = CGRectMake(
            //                 11, imageViewOffset,
            //                 self.chatTableView.width - 22, 200
            //             );
            //             imageView.image       = lazyImage.image;
            //             imageView.contentMode = UIViewContentModeScaleAspectFit;
            //             imageView.imageURL    = lazyImage.imageURL;

            //             imageViewOffset += imageView.height + 11;

            //             UITapGestureRecognizer *singleTap =
            //                 [[UITapGestureRecognizer alloc]
            //                     initWithTarget:self
            //                             action:@selector(tappedImage:)];
            //             singleTap.numberOfTapsRequired   = 1;
            //             imageView.userInteractionEnabled = YES;
            //             [imageView addGestureRecognizer:singleTap];

            //             [cell addSubview:imageView];
            //         } else if ([attachment
            //                        isKindOfClass:[DCChatVideoAttachment class]]) {
            //             ////NSLog(@"add video!");
            //             DCChatVideoAttachment *video = attachment;

            //             UITapGestureRecognizer *singleTap =
            //                 [[UITapGestureRecognizer alloc]
            //                     initWithTarget:self
            //                             action:@selector(tappedVideo:)];
            //             singleTap.numberOfTapsRequired = 1;
            //             [video.playButton addGestureRecognizer:singleTap];
            //             video.playButton.userInteractionEnabled = YES;

            //             CGFloat aspectRatio = video.thumbnail.image.size.width /
            //                 video.thumbnail.image.size.height;
            //             int newWidth  = 200 * aspectRatio;
            //             int newHeight = 200;
            //             if (newWidth > self.chatTableView.width - 66) {
            //                 newWidth  = self.chatTableView.width - 66;
            //                 newHeight = newWidth / aspectRatio;
            //             }
            //             video.frame = CGRectMake(55, imageViewOffset, newWidth, newHeight);
            //             [video prepareForDisplay];

            //             imageViewOffset += newHeight;

            //             [cell addSubview:video];
            //         } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
            //             DCGifInfo *gifInfo = attachment;
            //             DCChatGifAttachment *gif = [[[NSBundle mainBundle]
            //                 loadNibNamed:@"DCChatGifAttachment"
            //                        owner:nil
            //                      options:nil] objectAtIndex:0];
            //             gif.staticThumbnail    = gifInfo.staticThumbnail;
            //             gif.gifThumbnail.image = gifInfo.staticThumbnail;
            //             gif.gifURL             = gifInfo.gifURL;
            //             CGFloat aspectRatio = gif.staticThumbnail.size.width / gif.staticThumbnail.size.height;
            //             int newWidth  = 200 * aspectRatio;
            //             int newHeight = 200;
            //             if (newWidth > self.chatTableView.width - 66) {
            //                 newWidth  = self.chatTableView.width - 66;
            //                 newHeight = newWidth / aspectRatio;
            //             }
            //             [gif setFrame:CGRectMake(55, imageViewOffset, newWidth, newHeight)];
            //             [gif prepareForDisplay];
            //             imageViewOffset += newHeight;
            //             [cell addSubview:gif];
            //         } else if ([attachment isKindOfClass:[QLPreviewController class]]) {
            //             ////NSLog(@"Add QuickLook!");
            //             QLPreviewController *preview = attachment;

            //             /*UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer
            //              alloc] initWithTarget:self action:@selector(tappedVideo:)];
            //              singleTap.numberOfTapsRequired = 1;
            //              [video.playButton addGestureRecognizer:singleTap];
            //              video.playButton.userInteractionEnabled = YES;

            //              CGFloat aspectRatio = video.thumbnail.image.size.width /
            //              video.thumbnail.image.size.height; int newWidth = 200 *
            //              aspectRatio; int newHeight = 200; if (newWidth >
            //              self.chatTableView.width - 66) { newWidth =
            //              self.chatTableView.width - 66; newHeight = newWidth /
            //              aspectRatio;
            //              }
            //              [video setFrame:CGRectMake(55, imageViewOffset, newWidth,
            //              newHeight)];*/

            //             imageViewOffset += 210;

            //             [cell addSubview:preview.view];
            //         } else if ([attachment isKindOfClass:[NSArray class]]) {
            //             NSArray *dimensions = attachment;
            //             if (dimensions.count == 2) {
            //                 int width  = [dimensions[0] intValue];
            //                 int height = [dimensions[1] intValue];
            //                 if (width <= 0 || height <= 0) {
            //                     continue;
            //                 }
            //                 CGFloat aspectRatio = (CGFloat)width / height;
            //                 int newWidth        = 200 * aspectRatio;
            //                 int newHeight       = 200;
            //                 if (newWidth > self.chatTableView.width - 66) {
            //                     newWidth  = self.chatTableView.width - 66;
            //                     newHeight = newWidth / aspectRatio;
            //                 }
            //                 UIActivityIndicatorView *activityIndicator =
            //                     [[UIActivityIndicatorView alloc]
            //                         initWithActivityIndicatorStyle:
            //                             UIActivityIndicatorViewStyleWhite];
            //                 [activityIndicator setFrame:CGRectMake(
            //                                                 11, imageViewOffset, newWidth,
            //                                                 newHeight
            //                                             )];
            //                 [activityIndicator setContentMode:UIViewContentModeScaleAspectFit];
            //                 imageViewOffset += newHeight + 11;

            //                 [cell addSubview:activityIndicator];
            //                 [activityIndicator startAnimating];
            //             }
            //         }
            //     }
            // }
        } else {
            NSInteger modelIndex = [self modelIndexForRow:indexPath.row];
            DCMessageLayout *layout = [self layoutForModelIndex:modelIndex];
            if (!layout) {
                return [tableView dequeueReusableCellWithIdentifier:@"Message Cell"];
            }
            // CFAbsoluteTime cellStart = CFAbsoluteTimeGetCurrent();
            static UIColor *replyHighlightColor = nil;
            static UIColor *pingColor = nil;
            static UIColor *normalColor = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                replyHighlightColor = [UIColor colorWithRed:55/255.0f green:59/255.0f blue:64/255.0f alpha:1.0f];
                pingColor           = [UIColor colorWithRed:46/255.0f green:45/255.0f blue:40/255.0f alpha:1.0f];
                normalColor         = [UIColor colorWithRed:40/255.0f green:41/255.0f blue:46/255.0f alpha:1.0f];
            });

            // TICK(init);
            cell = (DCChatTableCell *)[tableView dequeueReusableCellWithIdentifier:layout.reuseIdentifier];

            BOOL isReplyTarget =
                self.replyingToMessage &&
                [self.replyingToMessage.snowflake isEqualToString:messageAtRowIndex.snowflake];

            BOOL isEditTarget =
                self.editingMessage &&
                [self.editingMessage.snowflake isEqualToString:messageAtRowIndex.snowflake];

            if (cell.configuredLayout == layout && !isReplyTarget && !isEditTarget) {
                cell.profileImage.image = messageAtRowIndex.author.profileImage;

                DCGuild *guild =
                    DCServerCommunicator.sharedInstance.selectedChannel.parentGuild;

                if (!layout.grouped) {
                    cell.authorLabel.text =
                        [messageAtRowIndex.author displayNameInGuild:guild];
                }

                if (messageAtRowIndex.referencedMessage) {
                    cell.referencedProfileImage.image =
                        messageAtRowIndex.referencedMessage.author.profileImage;

                    if (layout.hasReference) {
                        cell.referencedAuthorLabel.text =
                            [messageAtRowIndex.referencedMessage.author
                                displayNameInGuild:guild];
                    }
                } else {
                    cell.referencedProfileImage.image = nil;
                    cell.referencedAuthorLabel.text = nil;
                }

                NSUInteger attachIdx = 0;

                for (UIView *subview in cell.contentView.subviews) {
                    if (![subview isKindOfClass:[UILazyImageView class]]) continue;

                    UILazyImage *attachment = nil;
                    NSUInteger lazyCount = 0;

                    for (id att in messageAtRowIndex.attachments) {
                        if (![att isKindOfClass:[UILazyImage class]]) continue;

                        if (lazyCount == attachIdx) {
                            attachment = att;
                            break;
                        }

                        lazyCount++;
                    }

                    ((UILazyImageView *)subview).image = attachment ? attachment.image : nil;
                    attachIdx++;
                }

                return cell;
            }
            // TOCK(init);
            cell.configuredLayout = nil;
            // cleanup loop
            for (UIView *subView in cell.subviews) {
                @autoreleasepool {
                    if ([subView isKindOfClass:[UILazyImageView class]]) {
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[DCChatVideoAttachment class]]) {
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[QLPreviewController class]]) {
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[UIButton class]] && 
                        ![subView isKindOfClass:[DTLinkButton class]]) {
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[DCChatGifAttachment class]]) {
                        [(DCChatGifAttachment *)subView stopPlayback];
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[UIActivityIndicatorView class]]) {
                        [subView removeFromSuperview];
                    }
                }
            }

            [cell.contentTextView removeAllCustomViewsForLinks];
            [cell.referencedMessage removeAllCustomViewsForLinks];

            if (layout.hasReference) {
                cell.referencedAuthorLabel.text = [messageAtRowIndex.referencedMessage.author 
                    displayNameInGuild:DCServerCommunicator.sharedInstance.selectedChannel.parentGuild];
                
                NSAttributedString *referencedContent = [[DCMarkdownParser sharedParser]
                    attributedStringFromMarkdown:messageAtRowIndex.referencedMessage.content
                                     maxFontSize:10.0f
                                           color:[UIColor colorWithRed:128/255.0f
                                                                green:128/255.0f
                                                                 blue:128/255.0f
                                                                alpha:1.0f]];
                cell.referencedMessage.attributedString = referencedContent;
                
                cell.referencedMessage.frame = CGRectMake(
                    messageAtRowIndex.referencedMessage.authorNameWidth,
                    cell.referencedMessage.y,
                    self.chatTableView.width - messageAtRowIndex.referencedMessage.authorNameWidth,
                    cell.referencedMessage.height
                );
                if (messageAtRowIndex.referencedMessage
                    && cell.referencedProfileImage.image != messageAtRowIndex.referencedMessage.author.profileImage) {
                    cell.referencedProfileImage.image = messageAtRowIndex.referencedMessage.author.profileImage;
                }
                UIButton *referencedMessageButton = [UIButton buttonWithType:UIButtonTypeCustom];
                referencedMessageButton.frame = CGRectMake(
                    cell.referencedProfileImage.x, 
                    cell.referencedMessage.y, 
                    cell.referencedMessage.x + cell.referencedMessage.width - cell.referencedProfileImage.x, 
                    cell.referencedMessage.height
                );
                referencedMessageButton.exclusiveTouch = YES;
                [referencedMessageButton addTarget:self
                                             action:@selector(tappedReferencedMessage:)
                                      forControlEvents:UIControlEventTouchUpInside];
                [cell addSubview:referencedMessageButton];
            }

            if (!layout.grouped) {
                NSString *displayName = [messageAtRowIndex.author 
                    displayNameInGuild:DCServerCommunicator.sharedInstance.selectedChannel.parentGuild];
                
                // Calculate natural sizes
                CGSize timestampSize = [messageAtRowIndex.prettyTimestamp 
                    sizeWithFont:cell.timestampLabel.font];
                CGSize nameSize = [displayName sizeWithFont:cell.authorLabel.font];
                
                CGFloat authorOriginX = cell.authorLabel.x;
                CGFloat gap = 8.0; // gap between name and timestamp
                CGFloat rightPadding = 8.0;
                CGFloat maxRightEdge = self.chatTableView.width - rightPadding;
                
                // Natural timestamp position — right after the name
                CGFloat naturalTimestampX = authorOriginX + nameSize.width + gap;
                
                // Maximum allowed timestamp X so it doesn't go off screen
                CGFloat maxTimestampX = maxRightEdge - timestampSize.width;
                
                // Timestamp sits at natural position unless that would push it too far
                CGFloat actualTimestampX = MIN(naturalTimestampX, maxTimestampX);
                
                // Author label is capped to whatever space is left before the timestamp
                CGFloat actualNameWidth = MAX(0, actualTimestampX - authorOriginX - gap);
                
                cell.authorLabel.text = displayName;
                cell.authorLabel.frame = CGRectMake(authorOriginX,
                                                    cell.authorLabel.y,
                                                    actualNameWidth,
                                                    cell.authorLabel.height);
                
                cell.timestampLabel.text = messageAtRowIndex.prettyTimestamp;
                cell.timestampLabel.frame = CGRectMake(actualTimestampX,
                                                       cell.timestampLabel.y,
                                                       timestampSize.width,
                                                       cell.timestampLabel.height);
            }

            if (messageAtRowIndex.messageType == DCMessageTypeRecipientAdd || messageAtRowIndex.messageType == DCMessageTypeUserJoin) {
                cell.universalImageView.image = [UIImage imageNamed:@"U-Add"];
            } else if (messageAtRowIndex.messageType == DCMessageTypeRecipientRemove) {
                cell.universalImageView.image = [UIImage imageNamed:@"U-Remove"];
            } else if (messageAtRowIndex.messageType == DCMessageTypeChannelNameChange || messageAtRowIndex.messageType == DCMessageTypeChannelIconChange) {
                cell.universalImageView.image = [UIImage imageNamed:@"U-Pen"];
            } else if (messageAtRowIndex.messageType == DCMessageTypeChannelPinnedMessage) {
                cell.universalImageView.image = [UIImage imageNamed:@"U-Pin"];
            } else if (messageAtRowIndex.messageType == DCMessageTypeGuildBoost || messageAtRowIndex.messageType == DCMessageTypeThreadCreated) {
                cell.universalImageView.image = [UIImage imageNamed:@"U-Boost"];
            }

            float contentWidth = self.chatTableView.width - 63;

            // Set content

            cell.contentTextView.delegate = self;
            cell.contentTextView.userInteractionEnabled = YES;

            NSCharacterSet *invisibleChars = [NSCharacterSet characterSetWithCharactersInString:@"\u00A0\u200B\n\r\t "];
            BOOL hasVisibleContent = [[messageAtRowIndex.content stringByTrimmingCharactersInSet:invisibleChars] length] > 0 
                || messageAtRowIndex.emojis.count > 0;
            CGFloat textHeight = layout.textHeight;

            if (!hasVisibleContent) {
                cell.contentTextView.attributedString = nil;
                cell.contentTextView.hidden = YES;
                cell.contentTextView.frame = CGRectMake(
                    cell.contentTextView.x,
                    cell.contentTextView.y,
                    cell.contentTextView.width,
                    0
                );
            } else {
                if (!messageAtRowIndex.attributedContent && messageAtRowIndex.content.length > 0) {
                    messageAtRowIndex.attributedContent = [[DCMarkdownParser sharedParser]
                        attributedStringFromMarkdown:messageAtRowIndex.content];
                }
                cell.contentTextView.hidden = NO;
                cell.contentTextView.attributedString = messageAtRowIndex.attributedContent;
                [cell.contentTextView layoutSubviewsInRect:CGRectInfinite];
                cell.contentTextView.frame = CGRectMake(
                    cell.contentTextView.x,
                    cell.contentTextView.y,
                    contentWidth,
                    textHeight
                );
            }
            // TOCK(content);
            if (cell.profileImage.image != messageAtRowIndex.author.profileImage) {
                cell.profileImage.image = messageAtRowIndex.author.profileImage;
            }
            if (cell.profileImage.gestureRecognizers.count == 0) {
                cell.profileImage.userInteractionEnabled = YES;
                UITapGestureRecognizer *profileTap = [[UITapGestureRecognizer alloc]
                    initWithTarget:self action:@selector(profileImageTapped:)];
                profileTap.numberOfTapsRequired = 1;
                [cell.profileImage addGestureRecognizer:profileTap];
            }
            if ((self.replyingToMessage
                     && [self.replyingToMessage.snowflake
                         isEqualToString:messageAtRowIndex.snowflake])
                || (self.editingMessage
                    && [self.editingMessage.snowflake
                        isEqualToString:messageAtRowIndex.snowflake])) {
                cell.contentView.backgroundColor = replyHighlightColor;
            } else if (messageAtRowIndex.pingingUser) {
                cell.contentView.backgroundColor = pingColor;
            } else {
                cell.contentView.backgroundColor = normalColor;
            }

            CGFloat imageViewOffset;
            if (layout.grouped) {
                imageViewOffset = MAX(textHeight, 18) + 4;
            } else {
                CGFloat authorHeight = layout.showsAuthorName ? [UIFont boldSystemFontOfSize:15].lineHeight : 0;
                imageViewOffset = MAX(
                    authorHeight
                        + (messageAtRowIndex.attachmentCount ? (hasVisibleContent ? textHeight : 0) : MAX(textHeight, 18))
                        + 10
                        + (layout.hasReference ? 16 : 0),
                    authorHeight + (hasVisibleContent ? [UIFont systemFontOfSize:14].lineHeight : 0) + 10
                );
            }

            for (id attachment in messageAtRowIndex.attachments) {
                @autoreleasepool {
                    if ([attachment isKindOfClass:[UILazyImage class]]) {
                        UILazyImageView *imageView = [UILazyImageView new];
                        UILazyImage *lazyImage     = attachment;
                        CGFloat aspectRatio        = lazyImage.image.size.width / lazyImage.image.size.height;
                        int newWidth  = messageAtRowIndex.isSticker ? 160 : (int)(200 * aspectRatio);
                        int newHeight = messageAtRowIndex.isSticker ? 160 : 200;
                        if (newWidth > self.chatTableView.width - 66) {
                            newWidth  = self.chatTableView.width - 66;
                            newHeight = newWidth / aspectRatio;
                        }
                        imageView.frame = CGRectMake(
                            55, imageViewOffset, newWidth, newHeight
                        );
                        imageView.image    = lazyImage.image;
                        imageView.imageURL = lazyImage.imageURL;
                        imageViewOffset += newHeight;

                        imageView.contentMode = UIViewContentModeScaleAspectFit;

                        UITapGestureRecognizer *singleTap =
                            [[UITapGestureRecognizer alloc]
                                initWithTarget:self
                                        action:@selector(tappedImage:)];
                        singleTap.numberOfTapsRequired   = 1;
                        imageView.userInteractionEnabled = YES;

                        [imageView addGestureRecognizer:singleTap];

                        [cell addSubview:imageView];
                    } else if ([attachment
                                   isKindOfClass:[DCChatVideoAttachment class]]) {
                        ////NSLog(@"add video!");
                        DCChatVideoAttachment *video = attachment;

                        NSArray *existingRecognizers = [NSArray arrayWithArray:video.gestureRecognizers];
                        for (UIGestureRecognizer *gr in existingRecognizers) {
                            [video removeGestureRecognizer:gr];
                        }
                        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc]
                            initWithTarget:self action:@selector(tappedVideo:)];
                        singleTap.numberOfTapsRequired = 1;
                        [video addGestureRecognizer:singleTap];

                        CGFloat aspectRatio = (video.thumbnail.image && video.thumbnail.image.size.height > 0)
                            ? video.thumbnail.image.size.width / video.thumbnail.image.size.height
                            : 16.0f / 9.0f; // default widescreen aspect ratio
                        int newWidth  = 200 * aspectRatio;
                        int newHeight = 200;
                        if (newWidth > self.chatTableView.width - 66) {
                            newWidth  = self.chatTableView.width - 66;
                            newHeight = newWidth / aspectRatio;
                        }
                        [video setFrame:CGRectMake(55, imageViewOffset, newWidth, newHeight)];
                        [video prepareForDisplay];

                        imageViewOffset += newHeight;

                        [cell addSubview:video];
                    } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
                        DCGifInfo *gifInfo = (DCGifInfo *)attachment;
                        if (!gifInfo.staticThumbnail) continue;
                        if (!gifInfo.view) {
                            gifInfo.view = [[[NSBundle mainBundle]
                                loadNibNamed:@"DCChatGifAttachment"
                                       owner:nil
                                     options:nil] objectAtIndex:0];
                        }
                        DCChatGifAttachment *gif = gifInfo.view;
                        gif.staticThumbnail    = gifInfo.staticThumbnail;
                        gif.gifThumbnail.image = gifInfo.staticThumbnail;
                        gif.gifURL             = gifInfo.gifURL;
                        CGFloat aspectRatio = gifInfo.staticThumbnail.size.width / gifInfo.staticThumbnail.size.height;
                        int newWidth  = (int)(200 * aspectRatio);
                        int newHeight = 200;
                        if (newWidth > self.chatTableView.width - 66) {
                            newWidth  = self.chatTableView.width - 66;
                            newHeight = newWidth / aspectRatio;
                        }
                        [gif setFrame:CGRectMake(55, imageViewOffset, newWidth, newHeight)];
                        [gif prepareForDisplay];
                        imageViewOffset += newHeight;
                        [cell addSubview:gif];
                    } else if ([attachment isKindOfClass:[QLPreviewController class]]) {
                        ////NSLog(@"Add QuickLook!");
                        QLPreviewController *preview = attachment;

                        imageViewOffset += 210;

                        [cell addSubview:preview.view];
                    } else if ([attachment isKindOfClass:[NSArray class]]) {
                        NSArray *dimensions = attachment;
                        if (dimensions.count == 2) {
                            int width  = [dimensions[0] intValue];
                            int height = [dimensions[1] intValue];
                            if (width <= 0 || height <= 0) {
                                continue;
                            }
                            CGFloat aspectRatio = (CGFloat)width / height;
                            int newWidth        = 200 * aspectRatio;
                            int newHeight       = 200;
                            if (newWidth > self.chatTableView.width - 66) {
                                newWidth  = self.chatTableView.width - 66;
                                newHeight = newWidth / aspectRatio;
                            }
                            UIActivityIndicatorView *activityIndicator =
                                [[UIActivityIndicatorView alloc]
                                    initWithActivityIndicatorStyle:
                                        UIActivityIndicatorViewStyleWhite];
                            [activityIndicator setFrame:CGRectMake(
                                                            55, imageViewOffset, newWidth,
                                                            newHeight
                                                        )];
                            [activityIndicator setContentMode:UIViewContentModeScaleAspectFit];
                            imageViewOffset += newHeight + 11;

                            [cell addSubview:activityIndicator];
                            [activityIndicator startAnimating];
                        }
                    }
                }
            }
        cell.configuredLayout = layout;
        // CFAbsoluteTime cellEnd = CFAbsoluteTimeGetCurrent();
            // NSLog(@"[Cell] configuration took %.2fms", (cellEnd - cellStart) * 1000);
        }
    }
    cell.transform = CGAffineTransformMakeScale(1, -1);
    return cell;
}

- (void)attributedLabel:(DTAttributedLabel *)label didSelectLinkWithURL:(NSURL *)url {
    [[UIApplication sharedApplication] openURL:url];
}

- (UIView *)attributedTextContentView:(DTAttributedTextContentView *)attributedTextContentView 
                           viewForLink:(NSURL *)url 
                            identifier:(NSString *)identifier 
                                 frame:(CGRect)frame {
    DTLinkButton *button = [[DTLinkButton alloc] initWithFrame:frame];
    button.URL = url;
    
    if ([[url scheme] isEqualToString:@"discord-spoiler"]) {
        [button addTarget:self 
                   action:@selector(spoilerButtonTapped:) 
         forControlEvents:UIControlEventTouchUpInside];
    } else {
        [button addTarget:self 
                   action:@selector(linkButtonTapped:) 
         forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

- (UIView *)attributedTextContentView:(DTAttributedTextContentView *)attributedTextContentView
                    viewForAttachment:(DTTextAttachment *)attachment
                                frame:(CGRect)frame {
    if (![attachment isKindOfClass:[DTImageTextAttachment class]]) return nil;

    DTImageTextAttachment *imageAttachment = (DTImageTextAttachment *)attachment;
    NSURL *url = imageAttachment.contentURL;
    if (![[url scheme] isEqualToString:@"discord-emoji"]) return nil;

    DCEmoji *emoji = [DCServerCommunicator.sharedInstance emojiForSnowflake:url.host];

    CGRect emojiFrame = frame;
    emojiFrame.origin.y += 3.0f;
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:emojiFrame];
    imageView.contentMode  = UIViewContentModeScaleAspectFit;
    if (emoji.image && emoji.image.size.width > 0) {
        imageView.image = emoji.image;
    }
    return imageView;
}

- (void)emojiImageReady:(NSNotification *)notification {
    // Refresh visible cells that have attachment runs so they pick up
    // the newly loaded emoji image via viewForAttachment:frame:
    for (UITableViewCell *cell in self.chatTableView.visibleCells) {
        if (![cell isKindOfClass:[DCChatTableCell class]]) continue;
        DCChatTableCell *chatCell = (DCChatTableCell *)cell;
        if (!chatCell.contentTextView.attributedString) continue;

        __block BOOL hasAttachment = NO;
        [chatCell.contentTextView.attributedString
            enumerateAttribute:NSAttachmentAttributeName
                       inRange:NSMakeRange(0, chatCell.contentTextView.attributedString.length)
                       options:0
                    usingBlock:^(id value, NSRange range, BOOL *stop) {
                        if (value) { hasAttachment = YES; *stop = YES; }
                    }];

        if (hasAttachment) {
            [chatCell.contentTextView removeAllCustomViews];
            [chatCell.contentTextView relayoutText];
        }
    }
}

- (void)linkButtonTapped:(DTLinkButton *)button {
    NSURL *url = button.URL;
    NSString *scheme = url.scheme;
    
    if ([scheme isEqualToString:@"discord-user"]) {
        NSString *snowflake = url.host;
        DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:snowflake];
        if (user) {
            [self openUserProfile:user];
        }
    } else if ([scheme isEqualToString:@"discord-channel"]) {
        NSString *snowflake = url.host;
        DCChannel *channel = [DCServerCommunicator.sharedInstance.channels objectForKey:snowflake];
        if (channel) {
            [self navigateToChannel:channel];
        }
    } else if ([scheme isEqualToString:@"discord-role"]) {
        // Role taps — no action for now
    } else if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) {
        // Check for Discord channel deep link
        if ([[url host] isEqualToString:@"discord.com"] &&
            [[url path] hasPrefix:@"/channels/"]) {
            NSArray *components = [url.path componentsSeparatedByString:@"/"];
            // path is /channels/{guild_id}/{channel_id}
            // components: [@"", @"channels", @"{guild_id}", @"{channel_id}"]
            if (components.count >= 4) {
                NSString *channelId = components[3];
                DCChannel *channel = [DCServerCommunicator.sharedInstance.channels 
                    objectForKey:channelId];
                if (channel) {
                    [self navigateToChannel:channel];
                    return;
                }
            } else if (components.count == 3) {
                NSString *guildId = components[2];
                DCGuild *guild = nil;
                for (DCGuild *g in DCServerCommunicator.sharedInstance.guilds) {
                    if ([g.snowflake isEqualToString:guildId]) {
                        guild = g;
                        break;
                    }
                }
                if (guild) {
                    [self navigateToGuild:guild];
                    return;
                }
            }
        }
        [[UIApplication sharedApplication] openURL:url];
    } else {
        [[UIApplication sharedApplication] openURL:url];
    }
}

- (void)spoilerButtonTapped:(DTLinkButton *)button {
    // Find which cell contains this button
    UIView *view = button.superview;
    while (view && ![view isKindOfClass:[DCChatTableCell class]]) {
        view = view.superview;
    }
    if (!view) return;
    DCChatTableCell *cell = (DCChatTableCell *)view;
    
    // Get the attributed string and find the spoiler range
    NSMutableAttributedString *mutable = [cell.contentTextView.attributedString mutableCopy];
    if (!mutable) return;
    
    // Walk the attributed string looking for DTLinkAttribute matching this URL
    [mutable enumerateAttribute:DTLinkAttribute
                        inRange:NSMakeRange(0, mutable.length)
                        options:0
                     usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:[NSURL class]]) return;
        NSURL *linkURL = (NSURL *)value;
        if (![[linkURL absoluteString] isEqualToString:[button.URL absoluteString]]) return;
        
        // Apply revealed style to this range
        [[DCMarkdownParser sharedParser] applyBackgroundStyle:DCMarkdownBackgroundStyleSpoilerRevealed
                                                      toRange:range
                                                     inString:mutable
                                                overrideColor:nil];
        // Remove the link so it can't be tapped again
        [mutable removeAttribute:DTLinkAttribute range:range];
        [mutable removeAttribute:DCMarkdownSpoilerAttributeName range:range];
        
        *stop = YES;
    }];
    
    // Update the label with the revealed attributed string
    cell.contentTextView.attributedString = mutable;
    [cell.contentTextView relayoutText];
}

- (void)profileImageTapped:(UITapGestureRecognizer *)recognizer {
    UIView *view = recognizer.view.superview;
    while (view && ![view isKindOfClass:[DCChatTableCell class]]) {
        view = view.superview;
    }
    if (!view) return;

    NSIndexPath *indexPath = [self.chatTableView indexPathForCell:(DCChatTableCell *)view];
    if (!indexPath) return;

    DCMessage *message = [self.messages objectAtIndex:[self modelIndexForRow:indexPath.row]];
    if (!message.author) return;

    [self openUserProfile:message.author];
}

- (void)openUserProfile:(DCUser *)user {
    if (!user) return;
    self.selectedMessage = [[DCMessage alloc] init];
    self.selectedMessage.author = user;
    [self performSegueWithIdentifier:@"chat to contact" sender:self];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger modelIndex = [self modelIndexForRow:indexPath.row];
    DCMessageLayout *layout = [self layoutForModelIndex:modelIndex];
    if (!layout) return 0;
    return layout.height;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

- (void)actionSheet:(UIActionSheet *)popup
    clickedButtonAtIndex:(NSInteger)buttonIndex {

    if (self.longPressedIndexPath) {
        UITableViewCell *cell =
            [self.chatTableView cellForRowAtIndexPath:self.longPressedIndexPath];
        [[cell.contentView viewWithTag:9999] removeFromSuperview];
        self.longPressedIndexPath = nil;
    }

    if ([popup tag] == 1) {
        if (buttonIndex == 0) {                                         // Delete
            UIAlertView *confirmAlert = [[UIAlertView alloc]
                initWithTitle:@"Delete Message"
                      message:@"Are you sure you want to delete this message?"
                     delegate:self
            cancelButtonTitle:@"Cancel"
            otherButtonTitles:@"Delete", nil];
            [confirmAlert show];
        } else if (buttonIndex == 1) {                                  // Edit
            if (self.editingMessage
                && [self.editingMessage.snowflake
                    isEqualToString:self.selectedMessage.snowflake]) {
                self.editingMessage               = nil;
                self.inputField.text              = @"";
                self.inputFieldPlaceholder.hidden = NO;
                [self resizeInputField];
            } else {
                self.editingMessage               = self.selectedMessage;
                self.inputField.text              = self.selectedMessage.rawContent;
                self.inputFieldPlaceholder.hidden = YES;
                [self resizeInputField];
            }
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self rowForModelIndex:[self.messages indexOfObject:self.selectedMessage]]
                                                       inSection:0];
            [self.chatTableView beginUpdates];
            [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
            [self.chatTableView endUpdates];
        } else if (buttonIndex == 2) {                                  // Reply
            self.replyingToMessage = !self.replyingToMessage
                    || ![self.replyingToMessage.snowflake isEqualToString:self.selectedMessage.snowflake]
                ? self.selectedMessage
                : nil;
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self rowForModelIndex:[self.messages indexOfObject:self.selectedMessage]]
                                                       inSection:0];
            [self.chatTableView beginUpdates];
            [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
            [self.chatTableView endUpdates];
        } else if (buttonIndex == 3) {                                  // Copy Message
            [[UIPasteboard generalPasteboard] setString:self.selectedMessage.rawContent];
        } else if (buttonIndex == 4) {                                  // Copy Message ID
            [[UIPasteboard generalPasteboard] setString:self.selectedMessage.snowflake];
        }

    } else if ([popup tag] == 2) {                                      // Image source picker
        UIImagePickerController *picker = UIImagePickerController.new;
        picker.mediaTypes = [UIImagePickerController
            availableMediaTypesForSourceType:
                UIImagePickerControllerSourceTypeCamera];
        picker.delegate = (id)self;

        if (buttonIndex == 0) {
            if ([UIImagePickerController
                    isSourceTypeAvailable:
                        UIImagePickerControllerSourceTypeCamera]) {
                picker.sourceType = UIImagePickerControllerSourceTypeCamera;
            } else {
                return;
            }
        } else if (buttonIndex == 1) {
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        } else {
            return;
        }
        [picker viewWillAppear:YES];
        [self presentViewController:picker animated:YES completion:nil];
        [picker viewWillAppear:YES];

    } else if ([popup tag] == 3) {
        int addbut = self.replyingToMessage
                && [self.replyingToMessage.snowflake isEqualToString:self.selectedMessage.snowflake]
            ? 1
            : 0;
        if (buttonIndex == 0) {                                         // Reply / Cancel Reply
            self.replyingToMessage = !self.replyingToMessage
                    || ![self.replyingToMessage.snowflake isEqualToString:self.selectedMessage.snowflake]
                ? self.selectedMessage
                : nil;
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self rowForModelIndex:[self.messages indexOfObject:self.selectedMessage]]
                                                       inSection:0];
            [self.chatTableView beginUpdates];
            [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
            [self.chatTableView endUpdates];
        } else if (buttonIndex == addbut) {                             // Toggle Ping (only when addbut == 1)
            self.disablePing = !self.disablePing;
        } else if (buttonIndex == 1 + addbut) {                        // Mention
            self.inputField.text = [NSString
                stringWithFormat:@"%@<@%@> ", self.inputField.text,
                                 self.selectedMessage.author.snowflake];
        } else if (buttonIndex == 2 + addbut) {                        // Copy Message
            [[UIPasteboard generalPasteboard] setString:self.selectedMessage.rawContent];
        } else if (buttonIndex == 3 + addbut) {                        // Copy Message ID
            [[UIPasteboard generalPasteboard] setString:self.selectedMessage.snowflake];
        }
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.chatTableView) {
        return;
    }

    // Newest is at offset 0 in the flipped table.
    self.viewingPresentTime = (scrollView.contentOffset.y <= 10);

    if (self.messages.count == 0) {
        return;
    }

    if (!self.loadingOlderMessages
        && self.currentWindow.hasMoreBefore
        && scrollView.contentOffset.y >=
            scrollView.contentSize.height - 2 * scrollView.bounds.size.height) {

        self.loadingOlderMessages = YES;
        [self getMessages:kProximityLoadBurst
            beforeMessage:self.messages.firstObject];
    }

    if (!self.loadingNewerMessages
        && self.currentWindow.hasMoreAfter
        && scrollView.contentOffset.y <=
            2 * scrollView.bounds.size.height) {

        self.loadingNewerMessages = YES;
        [self getNewerMessages:kProximityLoadBurst
                  afterMessage:self.messages.lastObject];
    }
}

- (void)evictOldestDownToCeiling {
    NSInteger evictCount = (NSInteger)self.messages.count - kChatWindowCeiling;
    if (evictCount <= 0) return;

    BOOL inSync = ([self.chatTableView numberOfRowsInSection:0] == (NSInteger)self.messages.count);

    NSMutableArray *evictPaths = nil;
    if (inSync) {
        NSInteger totalRows = (NSInteger)self.messages.count;
        evictPaths = [NSMutableArray arrayWithCapacity:evictCount];
        for (NSInteger m = 0; m < evictCount; m++) {
            // oldest model indices map to the HIGHEST rows in the flipped table
            [evictPaths addObject:[NSIndexPath indexPathForRow:(totalRows - 1 - m) inSection:0]];
        }
    }

    NSRange headRange = NSMakeRange(0, evictCount);
    for (DCMessage *m in [self.messages subarrayWithRange:headRange]) {
        for (id att in m.attachments) {
            if ([att isKindOfClass:[UILazyImage class]]) ((UILazyImage *)att).image = nil;
        }
    }
    [self.messages removeObjectsInRange:headRange];
    self.currentWindow.hasMoreBefore = YES;

    if (inSync) {
        [UIView setAnimationsEnabled:NO];
        [self.chatTableView beginUpdates];
        [self.chatTableView deleteRowsAtIndexPaths:evictPaths
                                  withRowAnimation:UITableViewRowAnimationNone];
        [self.chatTableView endUpdates];
        [UIView setAnimationsEnabled:YES];
        // content-bottom removal — viewport unaffected, no offset correction
    } else {
        [self.chatTableView reloadData];
    }
}

- (NSArray *)deduplicateAgainstWindow:(NSArray *)incoming {
    if (incoming.count == 0) return incoming;
    NSMutableSet *have = [NSMutableSet setWithCapacity:self.messages.count];
    for (DCMessage *m in self.messages) {
        if (m.snowflake) [have addObject:m.snowflake];
    }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:incoming.count];
    for (DCMessage *m in incoming) {
        if (m.snowflake && ![have containsObject:m.snowflake]) [out addObject:m];
    }
    if (out.count != incoming.count) {
        NSLog(@"%s: dropped %lu duplicate(s) of %lu incoming",
              __PRETTY_FUNCTION__,
              (unsigned long)(incoming.count - out.count),
              (unsigned long)incoming.count);
    }
    return out;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return [self.messages count];
}

- (void)resizeInputField {
    static const CGFloat kMaxLines_iPhone  = 5.0f;
    static const CGFloat kMaxLines_iPad    = 10.0f;
    static const CGFloat kSingleLineHeight = 34.0f;

    CGFloat lineHeight     = self.inputField.font.lineHeight;
    CGFloat maxLines       = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
                                 ? kMaxLines_iPad : kMaxLines_iPhone;
    CGFloat maxInputHeight = kSingleLineHeight + ((maxLines - 1) * lineHeight);

    CGFloat desiredHeight = ceilf([self.inputField sizeThatFits:
        CGSizeMake(self.inputField.frame.size.width, MAXFLOAT)].height);

    BOOL needsScroll = (desiredHeight > maxInputHeight);
    self.inputField.scrollEnabled = needsScroll;

    CGFloat newInputHeight   = MAX(MIN(desiredHeight, maxInputHeight), _baseInputHeight);
    CGFloat newToolbarHeight = _baseToolbarHeight + (newInputHeight - _baseInputHeight);
    CGFloat growth           = newToolbarHeight - _baseToolbarHeight;

    // Reset to single line
    if (desiredHeight <= kSingleLineHeight) {
        self.inputField.scrollEnabled = NO;

        CGRect bgFrame      = self.messageFieldBG.frame;
        bgFrame.size.height = _baseMsgFieldBGHeight;
        self.messageFieldBG.frame = bgFrame;

        CGRect inputFrame      = self.inputField.frame;
        inputFrame.size.height = _baseInputHeight;
        inputFrame.origin.y    = _baseInputOriginY;
        self.inputField.frame  = inputFrame;

        CGRect toolbarFrame      = self.toolbar.frame;
        toolbarFrame.size.height = _baseToolbarHeight;
        toolbarFrame.origin.y    = self.view.bounds.size.height
                                   - self.keyboardHeight - _baseToolbarHeight;
        self.toolbar.frame = toolbarFrame;

        CGFloat typingOffset = (self.typingUsers.count > 0) ? 20.0f : 0.0f;
        [self.chatTableView setHeight:self.view.bounds.size.height
                                      - self.keyboardHeight
                                      - _baseToolbarHeight
                                      - typingOffset];
        if (self.typingUsers.count > 0) {
            [self.typingIndicatorView setY:self.view.bounds.size.height
                                           - self.keyboardHeight
                                           - _baseToolbarHeight - 20.0f];
        }
        return;
    }

    CGRect bgFrame      = self.messageFieldBG.frame;
    bgFrame.size.height = _baseMsgFieldBGHeight + growth;
    self.messageFieldBG.frame = bgFrame;

    CGRect inputFrame      = self.inputField.frame;
    inputFrame.size.height = newInputHeight;
    CGFloat bgMidY         = bgFrame.origin.y + bgFrame.size.height / 2.0f;
    inputFrame.origin.y    = bgMidY - newInputHeight / 2.0f;
    self.inputField.frame  = inputFrame;

    if (needsScroll) {
        [self.inputField scrollRangeToVisible:NSMakeRange(self.inputField.text.length, 0)];
    }

    CGRect toolbarFrame      = self.toolbar.frame;
    toolbarFrame.size.height = newToolbarHeight;
    toolbarFrame.origin.y    = self.view.bounds.size.height
                               - self.keyboardHeight - newToolbarHeight;
    self.toolbar.frame = toolbarFrame;

    CGFloat typingOffset = (self.typingUsers.count > 0) ? 20.0f : 0.0f;
    [self.chatTableView setHeight:self.view.bounds.size.height
                                  - self.keyboardHeight
                                  - newToolbarHeight
                                  - typingOffset];
    if (self.typingUsers.count > 0) {
        [self.typingIndicatorView setY:self.view.bounds.size.height
                                       - self.keyboardHeight
                                       - newToolbarHeight - 20.0f];
    }
}

- (void)keyboardWillShow:(NSNotification *)notification {
    // thx to Pierre Legrain
    // http://pyl.io/2015/08/17/animating-in-sync-with-ios-keyboard/
    CGRect keyboardFrame = [[notification.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    // Convert to view coordinates — critical for iPad landscape
    CGRect keyboardFrameInView = [self.view convertRect:keyboardFrame fromView:nil];
    // Only the portion that actually overlaps the view bottom
    self.keyboardHeight = MAX(0, self.view.bounds.size.height - keyboardFrameInView.origin.y);
    float keyboardAnimationDuration = [[notification.userInfo
        objectForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
    int keyboardAnimationCurve      = [[notification.userInfo
        objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue];

    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:keyboardAnimationDuration];
    [UIView setAnimationCurve:keyboardAnimationCurve];
    [UIView setAnimationBeginsFromCurrentState:YES];
    [self.chatTableView
        setHeight:self.view.height - self.keyboardHeight - self.toolbar.height - (self.typingUsers.count > 0 ? 20 : 0)];
    if (self.typingUsers.count > 0) {
        [self.typingIndicatorView setY:self.view.height - self.keyboardHeight - self.toolbar.height - 20];
    }
    [self.toolbar setY:self.view.height - self.keyboardHeight - self.toolbar.height];
    [UIView commitAnimations];

    if (self.viewingPresentTime) {
        [self.chatTableView setContentOffset:CGPointZero animated:NO];
    }
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.keyboardHeight             = 0;
    float keyboardAnimationDuration = [[notification.userInfo
        objectForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
    int keyboardAnimationCurve      = [[notification.userInfo
        objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue];

    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:keyboardAnimationDuration];
    [UIView setAnimationCurve:keyboardAnimationCurve];
    [UIView setAnimationBeginsFromCurrentState:YES];
    [self.chatTableView setHeight:self.view.height - self.toolbar.height - (self.typingUsers.count > 0 ? 20 : 0)];
    if (self.typingUsers.count > 0) {
        [self.typingIndicatorView setY:self.view.height - self.toolbar.height - 20];
    }
    [self.toolbar setY:self.view.height - self.toolbar.height];
    [UIView commitAnimations];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (!self.touchHighlightIndexPath) return;
    UITableViewCell *cell =
        [self.chatTableView cellForRowAtIndexPath:self.touchHighlightIndexPath];
    [[cell.contentView viewWithTag:9999] removeFromSuperview];
    self.touchHighlightIndexPath = nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v) {
        if (v == self.toolbar) return NO;
        v = v.superview;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]
            && [otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
        return YES;
    }
    if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]
            && [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
    }
    return NO;
}

- (void)dismissKeyboard:(UITapGestureRecognizer *)sender {
    [self.view endEditing:YES];

    NSDictionary *userInfo = @{
        UIKeyboardAnimationDurationUserInfoKey : @(0.25),
        UIKeyboardAnimationCurveUserInfoKey : @(UIViewAnimationCurveEaseInOut),
        UIKeyboardFrameBeginUserInfoKey : [NSValue valueWithCGRect:CGRectZero],
        UIKeyboardFrameEndUserInfoKey : [NSValue valueWithCGRect:CGRectZero],
    };

    [[NSNotificationCenter defaultCenter]
        postNotificationName:UIKeyboardWillHideNotification
                      object:nil
                    userInfo:userInfo];
}

- (IBAction)sendMessage:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.inputField.text isEqual:@""]) {
            NSString *msg = [DCTools parseMessage:self.inputField.text
                                        withGuild:DCServerCommunicator.sharedInstance.selectedChannel.parentGuild];
            if (self.editingMessage) {
                [DCServerCommunicator.sharedInstance.selectedChannel
                    editMessage:self.editingMessage
                    withContent:msg];
            } else {
                [DCServerCommunicator.sharedInstance.selectedChannel
                           sendMessage:msg
                    referencingMessage:self.replyingToMessage ? self.replyingToMessage : nil
                           disablePing:self.disablePing];
            }
            if (self.replyingToMessage || self.editingMessage) {
                DCMessage *target = self.replyingToMessage ?: self.editingMessage;
                NSUInteger idx = [self.messages indexOfObject:target];

                /*
                 * Clear these before reloading so the cell is configured
                 * without its reply/editing state.
                 */
                self.replyingToMessage = nil;
                self.editingMessage = nil;

                if (idx != NSNotFound && idx < self.messages.count) {
                    NSInteger row = [self rowForModelIndex:idx];

                    if (row >= 0 && row < [self.chatTableView numberOfRowsInSection:0]) {
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row
                                                                    inSection:0];

                        [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ]
                                                  withRowAnimation:UITableViewRowAnimationNone];
                    }
                }
            }
            self.disablePing = NO;
            [self.inputField setText:@""];
            self.inputField.scrollEnabled = NO;
            [self resizeInputField];
            self.inputFieldPlaceholder.hidden = NO;
            lastTimeInterval = 0;
        } else {
            [self.inputField resignFirstResponder];
        }

        [self.chatTableView setContentOffset:CGPointZero animated:YES];
    });
}

- (void)tappedReferencedMessage:(UIButton *)sender {
    assertMainThread();
    [self.inputField resignFirstResponder];
    CGPoint buttonPosition = [sender convertPoint:CGPointZero toView:self.chatTableView];
    NSIndexPath *indexPath = [self.chatTableView indexPathForRowAtPoint:buttonPosition];
    if (!indexPath) {
        DBGLOG(@"Tapped referenced message, but indexPath is nil!");
        return;
    }
    DCMessage *messageAtRowIndex = [self.messages objectAtIndex:[self modelIndexForRow:indexPath.row]];
    if (!messageAtRowIndex.referencedMessage) {
        DBGLOG(@"Tapped referenced message, but referencedMessage is nil!");
        return;
    }
    // scroll to referenced message
    NSUInteger referencedMessageIndex = [self.messages indexOfObjectPassingTest:^BOOL(DCMessage *obj, NSUInteger idx, BOOL *stop) {
        return [obj.snowflake isEqualToString:messageAtRowIndex.referencedMessage.snowflake];
    }];
    if (referencedMessageIndex == NSNotFound) {
        DBGLOG(@"Referenced message not found in messages array!");
        return;
    }
    [self.chatTableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[self rowForModelIndex:referencedMessageIndex]
                                                                  inSection:0]
                              atScrollPosition:UITableViewScrollPositionMiddle
                                              animated:YES];
}

- (void)tappedImage:(UITapGestureRecognizer *)sender {
    assertMainThread();
    [self.inputField resignFirstResponder];
    self.selectedImageURL = ((UILazyImageView *)sender.view).imageURL;
    SDWebImageManager *manager = [SDWebImageManager sharedManager];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication setNetworkActivityIndicatorVisible:YES];
    });
    [manager downloadImageWithURL:((UILazyImageView *)sender.view).imageURL
                          options:0
                         progress:nil
                        completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [UIApplication.sharedApplication setNetworkActivityIndicatorVisible:NO];
                                if (image) {
                                    self.selectedImage = image;
                                    [self performSegueWithIdentifier:@"Chat to Gallery" sender:self];
                                }
                            });
                        }];
}

- (void)tappedVideo:(UITapGestureRecognizer *)sender {
    assertMainThread();
    [self.inputField resignFirstResponder];
    DBGLOG(@"Tapped video!");
    dispatch_async(dispatch_get_main_queue(), ^{
        DCChatVideoAttachment *video = (DCChatVideoAttachment *)sender.view;

        // YouTube (or any embed with a linkURL): open in browser / YouTube app
        if (video.linkURL) {
            [[UIApplication sharedApplication] openURL:video.linkURL];
            return;
        }

        // All other video embeds — play inline
        NSURL *url = video.videoURL;
        MPMoviePlayerViewController *player = [[MPMoviePlayerViewController alloc] initWithContentURL:url];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(moviePlaybackDidFinish:)
                                                     name:MPMoviePlayerPlaybackDidFinishNotification
                                                   object:player.moviePlayer];
        player.moviePlayer.repeatMode = MPMovieRepeatModeOne;
        UIWindow *backgroundWindow    = [UIApplication sharedApplication].keyWindow;
        player.view.frame             = backgroundWindow.frame;
        [self presentMoviePlayerViewControllerAnimated:player];
        [player.moviePlayer play];
    });
}

- (void)moviePlaybackDidFinish:(NSNotification *)notification {
    NSNumber *reason = notification.userInfo[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];

    if ([reason intValue] == MPMovieFinishReasonPlaybackError) {
        NSError *error = notification.userInfo[@"error"];
        NSLog(@"Playback error occurred: %@", error);
    } else if ([reason intValue] == MPMovieFinishReasonUserExited) {
        DBGLOG(@"User exited playback");
    } else if ([reason intValue] == MPMovieFinishReasonPlaybackEnded) {
        DBGLOG(@"Playback ended normally");
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"Chat to Gallery"]) {
        DCImageViewController *imageViewController =
            [segue destinationViewController];
        if ([imageViewController isKindOfClass:[DCImageViewController class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [imageViewController.imageView setImage:self.selectedImage];
            });
            imageViewController.fullResURL = self.selectedImageURL;
        }
    } else if ([segue.identifier isEqualToString:@"Chat to Right Sidebar"]) {
        DCCInfoViewController *rightSidebar = [segue destinationViewController];

        if ([rightSidebar isKindOfClass:[DCCInfoViewController class]]) {
            [rightSidebar.navigationItem setTitle:self.navigationItem.title];
        }
    }

    if ([segue.destinationViewController isKindOfClass:[DCContactViewController class]]) {
        [((DCContactViewController *)segue.destinationViewController)
            setSelectedUser:self.selectedMessage.author];
    } else if ([segue.destinationViewController isKindOfClass:[ODCContactViewController class]]) {
        [((ODCContactViewController *)segue.destinationViewController)
            setSelectedUser:self.selectedMessage.author];
    }
}

- (IBAction)openSidebar:(id)sender {
    [self.slideMenuController showLeftMenu:YES];
}

- (IBAction)clickMemberButton:(id)sender {
    [self.slideMenuController showRightMenu:YES];
}

- (IBAction)chooseImage:(id)sender {
    [self.inputField resignFirstResponder];
        
    // Dismiss existing popover if already showing
    if (self.imagePopoverController.popoverVisible) {
        [self.imagePopoverController dismissPopoverAnimated:YES];
        self.imagePopoverController = nil;
        return;
    }

    if ([UIDevice currentDevice].userInterfaceIdiom
        == UIUserInterfaceIdiomPad) {
        // iPad-specific implementation using UIPopoverController
        if ([UIImagePickerController
                isSourceTypeAvailable:
                    UIImagePickerControllerSourceTypePhotoLibrary]) {
            UIImagePickerController *picker = UIImagePickerController.new;
            picker.sourceType               = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.delegate                 = self;

            // Initialize UIPopoverController
            UIPopoverController *popoverController =
                [[UIPopoverController alloc]
                    initWithContentViewController:picker];
            self.imagePopoverController = popoverController;

            if ([sender isKindOfClass:[UIButton class]]) {
                // Use the button's view for popover presentation
                UIButton *button = (UIButton *)sender;
                [popoverController
                    presentPopoverFromRect:button.bounds
                                    inView:button
                  permittedArrowDirections:UIPopoverArrowDirectionAny
                                  animated:YES];
            }
        }
    } else {
        if ([UIImagePickerController
                isSourceTypeAvailable:
                    UIImagePickerControllerSourceTypeCamera]) {
            UIActionSheet *imageSourceActionSheet =
                [[UIActionSheet alloc] initWithTitle:nil
                                            delegate:self
                                   cancelButtonTitle:@"Cancel"
                              destructiveButtonTitle:nil
                                   otherButtonTitles:@"Take Photo or Video",
                                                     @"Choose Existing", nil];
            [imageSourceActionSheet setTag:2];
            [imageSourceActionSheet showFromRect:self.toolbar.frame inView:self.view animated:YES];
        } else {
            // Camera is not supported, use photo library
            UIImagePickerController *picker = UIImagePickerController.new;
            picker.sourceType               = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.delegate                 = self;

            [self presentViewController:picker animated:YES completion:nil];
        }
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    [self.imagePopoverController dismissPopoverAnimated:YES];
    self.imagePopoverController = nil;

    NSString *mediaType = [info objectForKey:UIImagePickerControllerMediaType];

    if ([mediaType isEqualToString:@"public.movie"]) { // Check if it's a video
        NSURL *videoURL     = [info objectForKey:UIImagePickerControllerMediaURL];
        NSString *extension = [videoURL pathExtension];

        NSString *mimeType;
        if ([extension caseInsensitiveCompare:@"mov"] == NSOrderedSame) {
            mimeType = @"video/mov";
        } else if ([extension caseInsensitiveCompare:@"mp4"] == NSOrderedSame) {
            mimeType = @"video/mp4";
        } else {
            ////NSLog(@"Unsupported video format: %@", extension);
            return;
        }

        ////NSLog(@"MIME type %@", mimeType);

        // Use the sendVideo:mimeType: function to send the video
        [DCServerCommunicator.sharedInstance.selectedChannel
            sendVideo:videoURL
             mimeType:mimeType];

    } else if ([mediaType
                   isEqualToString:@"public.image"]) { // Check if it's an image
        UIImage *originalImage =
            [info objectForKey:UIImagePickerControllerEditedImage];
        if (!originalImage) {
            originalImage =
                [info objectForKey:UIImagePickerControllerOriginalImage];
        }
        if (!originalImage) {
            originalImage = [info objectForKey:UIImagePickerControllerCropRect];
        }

        // Determine the MIME type for the image based on the data
        NSString *mimeType = @"image/jpeg";

        NSString *extension =
            [info[UIImagePickerControllerReferenceURL] pathExtension];
        if ([extension caseInsensitiveCompare:@"png"] == NSOrderedSame) {
            mimeType = @"image/png";
        } else if ([extension caseInsensitiveCompare:@"gif"] == NSOrderedSame) {
            mimeType = @"image/gif";
        }
        if ([mimeType isEqualToString:@"image/gif"]) {
            ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
            [library assetForURL:
                         [info objectForKey:UIImagePickerControllerReferenceURL]
                     resultBlock:^(ALAsset *asset) {
                         ALAssetRepresentation *representation =
                             [asset defaultRepresentation];

                         Byte *buffer =
                             (Byte *)malloc((NSUInteger)representation.size);
                         NSUInteger buffered = [representation
                               getBytes:buffer
                             fromOffset:0
                                 length:(NSUInteger)representation.size
                                  error:nil];
                         NSData *data        = [NSData dataWithBytesNoCopy:buffer
                                                             length:buffered
                                                       freeWhenDone:YES];

                         [DCServerCommunicator.sharedInstance.selectedChannel
                             sendData:data
                             mimeType:mimeType];
                     }
                    failureBlock:^(NSError *error){
                        ////NSLog(@"couldn't get asset: %@", error);

                    }];

        } else {
            [DCServerCommunicator.sharedInstance.selectedChannel
                sendImage:originalImage
                 mimeType:mimeType];
        }
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 1) {
        [DCServerCommunicator.sharedInstance.selectedChannel deleteMessage:self.selectedMessage];
    }
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    CGFloat typingOffset = (self.typingUsers.count > 0) ? 20.0f : 0.0f;
    self.chatTableView.frame = CGRectMake(
        0, 0,
        self.view.bounds.size.width,
        self.view.bounds.size.height - self.keyboardHeight - self.toolbar.height - typingOffset
    );
    self.toolbar.frame = CGRectMake(
        0,
        self.view.bounds.size.height - self.keyboardHeight - self.toolbar.height,
        self.view.bounds.size.width,
        self.toolbar.height
    );
    [[DCCacheManager sharedInstance] invalidateAllMessages];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.chatTableView reloadData];
    });
}

- (void)navigateToChannel:(DCChannel *)channel {
    if (!channel) return;
    
    DCServerCommunicator.sharedInstance.selectedChannel = channel;
    
    // Update DCMenuViewController state without seguing
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CHANNEL_CONTEXT_CHANGED"
                      object:nil
                    userInfo:@{@"channelId": channel.snowflake}];
    
    // Swap chat in place
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NUKE CHAT DATA" object:nil];
    self.navigationItem.title = channel.type == 0 
        ? [@"#" stringByAppendingString:channel.name] 
        : channel.name;
    self.viewingPresentTime = YES;
    [self handleChannelLoadCold:channel];
}

- (void)navigateToGuild:(DCGuild *)guild {
    if (!guild) return;
    
    // Tell DCMenuViewController to switch to this guild
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"NAVIGATE_TO_GUILD"
                      object:nil
                    userInfo:@{@"guildId": guild.snowflake}];
    
    // Pop back to menu
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewDidUnload {
    [super viewDidUnload];

    // Invalidate all pending typing timers before clearing —
    // they hold a reference to self as target and will fire into
    // freed memory if not cancelled
    for (NSTimer *timer in self.typingUsers.allValues) {
        [timer invalidate];
    }
    [self.typingUsers removeAllObjects];

    // Remove programmatically created views from hierarchy
    [self.typingIndicatorView removeFromSuperview];
    self.typingIndicatorView = nil;
    self.typingLabel         = nil;

    // Nil weak IBOutlets — non-ARC __unsafe_unretained outlets are
    // never zeroed automatically on view unload
    self.chatTableView          = nil;
    self.toolbar                = nil;
    self.toolbarBG              = nil;
    self.inputField             = nil;
    self.inputFieldPlaceholder  = nil;
    self.inputView              = nil;
    self.messageFieldBG         = nil;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (![self isMovingFromParentViewController]) {
        return;
    }

    DCServerCommunicator.sharedInstance.selectedChannel = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:@"ChannelSelectionCleared" object:nil];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];

    [[DCCacheManager sharedInstance] handleMemoryWarning];
    for (DCMessage *message in self.messages) {
        message.attributedContent = nil;
    }
    NSLog(@"[DCChatViewController] Memory warning! Freed attributed content");
}

- (IBAction)dismissModalPVTONLY:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
