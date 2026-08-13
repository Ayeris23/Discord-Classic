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
#include <math.h>
#include <objc/NSObjCRuntime.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>

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
#import "DCResourceManager.h"
#import "DCChatMediaManager.h"
#import "DTLinkButton.h"
#import "DCMarkdownParser.h"
#import "NSString+Emojize.h"
#import "DTCoreTextConstants.h"
#import "DTCoreTextLayouter.h"
#import "DTCoreTextLayoutFrame.h"
#import "DTImageTextAttachment.h"
#import "DCMessageStore.h"
#import "DCChannelWindow.h"
#import "DCMessageLayoutBuilder.h"

@interface DCChatReferencePresentation : NSObject
@property (nonatomic, copy) NSString *sourceText;
@property (nonatomic, retain) NSAttributedString *attributedText;
@end

@implementation DCChatReferencePresentation
@end

@interface DCChatViewController ()
@property (nonatomic, readonly) NSMutableArray *messages;
@property (strong, nonatomic) DCMessageLayoutBuilder *messageLayoutBuilder;
@property (nonatomic, strong) DCChannelWindow *currentWindow;
@property (assign, nonatomic) NSUInteger numberOfMessagesLoaded;
@property (strong, nonatomic) UIImage *selectedImage;
@property (assign, nonatomic) BOOL oldMode;
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
@property (nonatomic, assign) BOOL restoringWindowPosition;
@property (nonatomic, assign) CFAbsoluteTime lastScrollPerfEventTime;
@property (nonatomic, assign) NSInteger deferredWindowTrimDirection;
/*
 * UIScrollView cancels native deceleration when contentOffset is corrected after
 * inserting newer rows. Preserve the user's forward-to-present momentum with
 * a tiny display-link decelerator once that hand-off becomes necessary.
 */
@property (nonatomic, retain) CADisplayLink *forwardMomentumDisplayLink;
@property (nonatomic, assign) CGFloat forwardMomentumVelocityY;
@property (nonatomic, assign) CFTimeInterval forwardMomentumLastTimestamp;
@property (nonatomic, assign) CGFloat sampledScrollVelocityY;
@property (nonatomic, assign) CGFloat lastVelocitySampleOffsetY;
@property (nonatomic, assign) CFAbsoluteTime lastVelocitySampleTime;
@property (nonatomic, assign) BOOL chatMediaHydrationDeferred;
// Presentation-only reply data is cached separately from canonical message state.
@property (nonatomic, retain) NSCache *referencePresentationCache;
@property (nonatomic, retain) DCMarkdownParser *referenceRunwayParser;
@property (nonatomic, retain) NSArray *referenceRunwayShadows;
@property (nonatomic, assign) BOOL presentationRunwayPrewarmPending;
@property (nonatomic, assign) BOOL forwardMomentumBlockedOnData;
// Runway timing distinguishes late requests from slow row production.
@property (nonatomic, assign) CFAbsoluteTime olderRunwayRequestStartTime;
@property (nonatomic, assign) CFAbsoluteTime newerRunwayRequestStartTime;
@property (nonatomic, assign) CFAbsoluteTime lastOlderRunwayStarvationLog;
@property (nonatomic, assign) CFAbsoluteTime lastNewerRunwayStarvationLog;
@property (nonatomic, assign) NSInteger olderRunwayRequestedCount;
@property (nonatomic, assign) NSInteger newerRunwayRequestedCount;
- (void)stopForwardMomentumContinuation;
- (void)startForwardMomentumContinuationWithVelocity:(CGFloat)velocityY;
- (void)forwardMomentumTick:(CADisplayLink *)displayLink;
- (CGFloat)effectiveRunwayVelocityY;
- (void)maintainMessageRunwayForVelocity:(CGFloat)velocityY reason:(NSString *)reason;
- (void)schedulePresentationRunwayForVelocity:(CGFloat)velocityY;
- (BOOL)chatIsActivelyScrolling;
- (void)updateChatMediaResidencyForCell:(DCChatTableCell *)cell
                              allowLoading:(BOOL)allowLoading;
- (NSString *)referencePreviewTextForMessage:(DCMessage *)message;
- (NSUInteger)prewarmReferencePresentationsForMessages:(NSArray *)messages;
- (dispatch_queue_t)get_chat_presentation_queue;
@end

// dynamic message box vars
CGFloat _baseToolbarHeight;
CGFloat _baseInputHeight;
CGFloat _baseMsgFieldBGHeight;
CGFloat _baseInputOriginY;

// Message residency is determined by the device memory class.
static NSInteger DCChatWindowCeiling(void) {
    return [DCResourceManager sharedManager].chatMessageSoftLimit;
}

static NSInteger DCChatWindowHardCeiling(void) {
    return [DCResourceManager sharedManager].chatMessageHardLimit;
}

// Allow temporary extra runway during high-speed scrolling, then trim back to policy limits.
static NSInteger DCChatActiveWindowHardCeiling(void) {
    if ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB) {
        return 72;
    }
    return DCChatWindowHardCeiling();
}

static NSInteger DCChatWindowTrimBatch(void) {
    return [DCResourceManager sharedManager].chatMessageTrimBatch;
}

typedef NS_ENUM(NSInteger, DCWindowTrimDirection) {
    DCWindowTrimDirectionNone = 0,
    DCWindowTrimDirectionRemoveNewest = 1,
    DCWindowTrimDirectionRemoveOldest = 2
};
static char kDCChatTextDrawStartKey;

/*
 * Pixel availability is not layout availability.  If Discord supplied stable
 * media dimensions, the row geometry is authoritative before the thumbnail
 * arrives and the width-aware layout cache is safe to use.
 */
static BOOL DCMessageHasUnknownAttachmentGeometry(DCMessage *message) {
    for (id attachment in message.attachments) {
        if ([attachment isKindOfClass:[NSArray class]]) {
            NSArray *dimensions = attachment;
            if (dimensions.count != 2 ||
                [dimensions[0] floatValue] <= 0 ||
                [dimensions[1] floatValue] <= 0) {
                return YES;
            }
        } else if ([attachment isKindOfClass:[UILazyImage class]]) {
            UILazyImage *image = attachment;
            if ((image.naturalSize.width <= 0 || image.naturalSize.height <= 0) &&
                (!image.image || image.image.size.width <= 0 || image.image.size.height <= 0)) {
                return YES;
            }
        } else if ([attachment isKindOfClass:[DCChatVideoAttachment class]]) {
            DCChatVideoAttachment *video = attachment;
            if ((video.naturalSize.width <= 0 || video.naturalSize.height <= 0) &&
                (!video.thumbnailImage ||
                 video.thumbnailImage.size.width <= 0 ||
                 video.thumbnailImage.size.height <= 0)) {
                return YES;
            }
        } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
            DCGifInfo *gif = attachment;
            if ((gif.naturalSize.width <= 0 || gif.naturalSize.height <= 0) &&
                (!gif.staticThumbnail ||
                 gif.staticThumbnail.size.width <= 0 ||
                 gif.staticThumbnail.size.height <= 0)) {
                return YES;
            }
        }
    }
    return NO;
}

static int DCInitialMessageLoadCount(void) {
    // Initial load count is based on display size; pagination is memory-class based.
    return ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 24 : 12;
}

static int DCProximityMessageLoadCount(void) {
    // Use smaller pagination batches on 256 MB devices.
    if ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB) {
        return 6;
    }
    return ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? 24 : 12;
}

/*
 * Forward pagination should be driven by how much of the newly appended page
 * the user has actually consumed, not by a large pixel threshold. A 12-row
 * phone page therefore re-fetches only after the user reaches roughly the
 * newest half of that page.
 */
static NSInteger DCNewerPaginationTriggerRow(void) {
    // Keep more than one small page of look-ahead without consuming too much of the resident window.
    if ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB) {
        return 8;
    }
    return MAX(3, DCProximityMessageLoadCount() / 2);
}

// Runway distance includes both deceleration travel and expected row-production latency.
static CGFloat DCProjectedMomentumTravel(CGFloat velocityY) {
    const double ratePerMillisecond = 0.998;
    double speed = fabs((double)velocityY);
    if (speed < 30.0) return 0.0f;
    return (CGFloat)((speed / 1000.0) / (1.0 - ratePerMillisecond));
}

static CGFloat DCMessageRunwaySupplyLatencySeconds(void) {
    switch ([DCResourceManager sharedManager].memoryClass) {
        case DCDeviceMemoryClass256MB: return 0.45f;
        case DCDeviceMemoryClass512MB: return 0.25f;
        case DCDeviceMemoryClass1GB: return 0.15f;
        case DCDeviceMemoryClass2GBPlus: return 0.10f;
        case DCDeviceMemoryClassUnknown:
        default: return 0.35f;
    }
}

static CGFloat DCMessageRunwayCapScreens(void) {
    switch ([DCResourceManager sharedManager].memoryClass) {
        case DCDeviceMemoryClass256MB: return 10.0f;
        case DCDeviceMemoryClass512MB: return 12.0f;
        case DCDeviceMemoryClass1GB: return 14.0f;
        case DCDeviceMemoryClass2GBPlus: return 16.0f;
        case DCDeviceMemoryClassUnknown:
        default: return 10.0f;
    }
}

static int DCRunwayMessageLoadCount(CGFloat velocityY) {
    CGFloat speed = fabs(velocityY);
    DCDeviceMemoryClass memoryClass = [DCResourceManager sharedManager].memoryClass;

    if (memoryClass == DCDeviceMemoryClass256MB) {
        return speed >= 3000.0f ? 12 : 6;
    }

    int normal = DCProximityMessageLoadCount();
    if (memoryClass == DCDeviceMemoryClass1GB ||
        memoryClass == DCDeviceMemoryClass2GBPlus) {
        return speed >= 4500.0f ? MAX(normal, 24) : normal;
    }

    if (memoryClass == DCDeviceMemoryClass512MB && speed >= 4000.0f) {
        return MAX(normal, 12);
    }
    return normal;
}

static CGFloat DCMessageRunwayTargetPoints(CGFloat velocityY, CGFloat viewportHeight) {
    if (viewportHeight <= 0.0f) return 0.0f;

    CGFloat speed = fabs(velocityY);
    CGFloat projected = DCProjectedMomentumTravel(velocityY);
    CGFloat latencyReserve = speed * DCMessageRunwaySupplyLatencySeconds();
    CGFloat baseScreens =
        ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB)
            ? 1.75f : 1.50f;

    CGFloat target = MAX(2.0f * viewportHeight,
                         projected + latencyReserve +
                             baseScreens * viewportHeight);
    return MIN(target, DCMessageRunwayCapScreens() * viewportHeight);
}

static CGFloat DCPresentationRunwayTargetPoints(CGFloat velocityY, CGFloat viewportHeight) {
    if (viewportHeight <= 0.0f) return 0.0f;
    CGFloat projected = DCProjectedMomentumTravel(velocityY);
    CGFloat target = MAX(2.0f * viewportHeight,
                         viewportHeight + projected * 0.70f);
    CGFloat capScreens = ([DCResourceManager sharedManager].memoryClass ==
                          DCDeviceMemoryClass256MB) ? 5.0f : 6.0f;
    return MIN(target, capScreens * viewportHeight);
}



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
        if ([DCTools isOriginalIPad]) {
            // Keep exact layout off-main and low priority on the most constrained device.
            dispatch_set_target_queue(
                chat_messages_queue,
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
        }
    }
    return chat_messages_queue;
}

static dispatch_queue_t chat_presentation_queue;
- (dispatch_queue_t)get_chat_presentation_queue {
    if (chat_presentation_queue == nil) {
        chat_presentation_queue = dispatch_queue_create(
            [@"Discord::Chat::PresentationRunway" UTF8String],
            DISPATCH_QUEUE_SERIAL
        );
        /* Presentation work is deliberately speculative. Always let UIKit,
         * gateway commit, and message conversion win scheduler contention. */
        dispatch_set_target_queue(
            chat_presentation_queue,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    }
    return chat_presentation_queue;
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
    [self.referencePresentationCache removeAllObjects];
    self.presentationRunwayPrewarmPending = NO;
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

    [self activateSelectedChannel];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    /*
     * Warm the COMPLETE currently-loaded window, not just the rows UIKit has
     * already asked to display.  beginUpdates/deleteRows on iOS 6 may query
     * heights for many offscreen rows; without this, those queries become
     * synchronous DTCoreText work later while the user is scrolling.
     */
    NSArray *initialLayoutSnapshot = [self.messages copy];
    CGFloat initialLayoutWidth = self.chatTableView.bounds.size.width;
    if (initialLayoutSnapshot.count && initialLayoutWidth > 0.0f) {
        DCMessageLayoutBuilder *initialLayoutBuilder = self.messageLayoutBuilder;
        dispatch_async([self get_chat_messages_queue], ^{
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            [initialLayoutBuilder
                prewarmLayoutCacheForMessages:initialLayoutSnapshot
                              previousMessage:nil
                                  nextMessage:nil
                                   tableWidth:initialLayoutWidth];
            NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - start;
            if (elapsed >= 0.008) {
                NSLog(@"[ChatPerf] current window layout prewarm %lu msgs %.3fs",
                      (unsigned long)initialLayoutSnapshot.count, elapsed);
            }
        });
    }

    /*
     * Regex compilation and NSDataDetector setup are one-time costs that showed
     * up as 100ms-class first-message hitches.  Move them away from channel
     * publication/scroll interaction without changing parser semantics.
     */
    static dispatch_once_t parserPrewarmOnce;
    dispatch_once(&parserPrewarmOnce, ^{
        if ([DCTools isOriginalIPad]) {
            // Initialize parser matchers lazily on the most constrained device.
            NSLog(@"[ChatPerf] Markdown/Emojize prewarm skipped on iPad1,1");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            [[DCMarkdownParser sharedParser] prewarmReusableMatchers];
            [NSString prewarmEmojizeLookup];
            NSLog(@"[ChatPerf] Markdown/Emojize prewarm %.3fs",
                  CFAbsoluteTimeGetCurrent() - start);
        });
    });

    /*
     * Returning from the gallery/movie controller can detach every chat media
     * view from UIWindow, which intentionally releases its decoded thumbnail.
     * A stationary table will not generate scroll callbacks, so explicitly
     * re-run residency after UIKit has reattached the visible cells.
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateVisibleChatMediaResidency];
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.referencePresentationCache = [[NSCache alloc] init];
    self.referencePresentationCache.countLimit =
        ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB)
            ? 64 : 160;

    /*
     * Give speculative reply parsing its own parser instance. The visible-cell
     * fallback still uses DCMarkdownParser's shared compact parser, so a slow
     * runway parse can never hold a parser lock that blocks the main thread.
     * Configure all UIKit font/color objects here on main; the low-priority
     * presentation queue only performs CoreText/regex attributed-string work.
     */
    UIColor *runwayReferenceColor =
        [UIColor colorWithRed:128/255.0f green:128/255.0f blue:128/255.0f alpha:1.0f];
    DCMarkdownParser *runwayParser = [[DCMarkdownParser alloc] init];
    runwayParser.defaultFont    = [UIFont systemFontOfSize:10.0f];
    runwayParser.boldFont       = [UIFont boldSystemFontOfSize:10.0f];
    runwayParser.italicFont     = [UIFont italicSystemFontOfSize:10.0f];
    runwayParser.boldItalicFont = [UIFont fontWithName:@"Helvetica-BoldOblique" size:10.0f];
    runwayParser.codeFont       = [UIFont fontWithName:@"Courier" size:10.0f];
    runwayParser.underlineFont  = [UIFont systemFontOfSize:10.0f];
    runwayParser.h1Font         = [UIFont boldSystemFontOfSize:10.0f];
    runwayParser.h2Font         = [UIFont boldSystemFontOfSize:10.0f];
    runwayParser.h3Font         = [UIFont boldSystemFontOfSize:10.0f];
    runwayParser.subtextFont    = [UIFont systemFontOfSize:10.0f];
    runwayParser.defaultColor       = runwayReferenceColor;
    runwayParser.linkColor          = runwayReferenceColor;
    runwayParser.mentionColor       = runwayReferenceColor;
    runwayParser.codeTextColor      = runwayReferenceColor;
    runwayParser.spoilerHiddenColor = runwayReferenceColor;
    runwayParser.blockquoteColor    = runwayReferenceColor;
    runwayParser.subtextColor       = runwayReferenceColor;
    runwayParser.strikethroughColor = runwayReferenceColor;
    runwayParser.minimumLineHeight = 0.0f;
    self.referenceRunwayParser = runwayParser;
    self.referenceRunwayShadows = @[ @{
        @"Offset": [NSValue valueWithCGSize:CGSizeMake(0, 1)],
        @"Blur":   @(0.0f),
        @"Color":  [UIColor blackColor]
    } ];

    self.presentationRunwayPrewarmPending = NO;
    self.forwardMomentumBlockedOnData = NO;
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
                                           selector:@selector(handleChatMediaPurgeVisible)
                                               name:DCChatMediaPurgeVisibleNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleChatMediaRehydrateVisible)
                                               name:DCChatMediaRehydrateVisibleNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleGuildMemberListUpdated:)
                                               name:@"GuildMemberListUpdated"
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
    DCChannelWindow *window = self.currentWindow;

    if (!window) {
        return;
    }

    /*
     * Reaching row zero only means reaching the newest loaded message.
     * It represents the real present only when the window contains the
     * live tail.
     */
    window.atPresentTime =
        viewingPresentTime && !window.hasMoreAfter;
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
    [self invalidateAllTypingTimers];

    [self syncWindowForSelectedChannel];
    @autoreleasepool {
        self.selectedMessage = nil;
        self.selectedImage = nil;
        if (!self.typingUsers) {
            self.typingUsers =
                [NSMutableDictionary dictionary];
        }
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
}

- (void)handleAsyncReload {
    if (!self.chatTableView) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [[DCCacheManager sharedInstance] invalidateAllMessages];
            [self.chatTableView reloadData];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateVisibleChatMediaResidency];
        });
    });
}

- (void)handleReady {
    assertMainThread();

    self.reconcileGeneration++;
    self.reconcilingChannelID = nil;

    [self activateSelectedChannel];
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

    if (window.hasMoreAfter) {
        return;
    }

    if ([DCTools isOriginalIPad] &&
        self.chatTableView.contentOffset.y > 10.0f) {
        // Defer live-tail reconciliation while the user is visibly reading history.
        window.hasMoreAfter = YES;
        window.atPresentTime = NO;
        self.viewingPresentTime = NO;
        NSLog(@"[ChatPerf] A4 skipped forward reconcile away from live edge");
        return;
    }

    if ([self.reconcilingChannelID isEqualToString:channelID]) {
        return;
    }

    NSUInteger generation = ++self.reconcileGeneration;
    self.reconcilingChannelID = channelID;

    DCMessage *anchor = window.messages.lastObject;
    DCMessage *anchorPrevious = window.messages.count > 1
        ? window.messages[window.messages.count - 2] : nil;
    CGFloat preparedTableWidth = self.chatTableView.bounds.size.width;
    DCMessageLayoutBuilder *layoutBuilder = self.messageLayoutBuilder;

    dispatch_async([self get_chat_messages_queue], ^{
        DCMessageDelta *delta =
            [[DCMessageStore sharedInstance]
                reconcileForwardForChannel:channel
                              afterMessage:anchor];

        if (delta) {
            CFAbsoluteTime prewarmStart = CFAbsoluteTimeGetCurrent();
            if (delta.requiresFullReload) {
                [layoutBuilder
                    prewarmLayoutCacheForMessages:delta.replacementMessages
                                  previousMessage:nil
                                      nextMessage:nil
                                       tableWidth:preparedTableWidth];
            } else {
                [layoutBuilder
                    prewarmLayoutCacheForMessages:delta.candidateMessages
                                  previousMessage:anchor
                                      nextMessage:nil
                                       tableWidth:preparedTableWidth];
                if (anchor && delta.candidateMessages.count) {
                    [layoutBuilder
                        prewarmLayoutCacheForMessage:anchor
                                     previousMessage:anchorPrevious
                                         nextMessage:delta.candidateMessages.firstObject
                                          tableWidth:preparedTableWidth];
                }
            }
            NSLog(@"[ChatPerf] forward reconcile layout prewarm %.3fs",
                  CFAbsoluteTimeGetCurrent() - prewarmStart);
        }

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
            BOOL followLiveTail =
                !window.hasMoreAfter &&
                self.chatTableView.contentOffset.y <= 10.0f;

            // Defer live reconciliation while the user is reading history.
            if ([DCTools isOriginalIPad] &&
                !followLiveTail &&
                (delta.requiresFullReload || delta.candidateMessages.count > 0)) {
                window.hasMoreAfter = YES;
                window.atPresentTime = NO;
                [self saveScrollPositionForWindow:window];
                [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:window];
                NSLog(@"[ChatPerf] A4 deferred forward reconcile while reading history");
                return;
            }

            CGPoint previousOffset =
                self.chatTableView.contentOffset;
            if (DCServerCommunicator.sharedInstance.selectedChannel != channel) return;

            if (delta.requiresFullReload) {
                if (!followLiveTail) {
                    /*
                     * More than one reconciliation page exists, but the user is reading
                     * older content. Do not replace their window with the latest page.
                     *
                     * Convert this into a historical window instead. Normal forward
                     * pagination can now bridge the gap when the user scrolls toward
                     * row zero.
                     */
                    window.hasMoreAfter = YES;
                    window.atPresentTime = NO;

                    [self saveScrollPositionForWindow:window];
                    [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:window];
                    return;
                }

                /*
                 * The user was already following the live edge, so replacing the window
                 * with the newest page is appropriate.
                 */
                self.restoringWindowPosition = YES;

                NSArray *replacementMessages = delta.replacementMessages;
                if ([DCTools isOriginalIPad] &&
                    replacementMessages.count > (NSUInteger)DCChatWindowCeiling()) {
                    replacementMessages = [replacementMessages subarrayWithRange:
                        NSMakeRange(replacementMessages.count - DCChatWindowCeiling(),
                                    DCChatWindowCeiling())];
                }

                [self.messages removeAllObjects];
                [self.messages addObjectsFromArray:replacementMessages];

                window.hasMoreAfter = NO;
                window.atPresentTime = YES;

                [self.chatTableView reloadData];
                [self.chatTableView layoutIfNeeded];

                if (self.messages.count > 0) {
                    [self.chatTableView
                        setContentOffset:CGPointZero
                                animated:NO];
                }

                self.restoringWindowPosition = NO;

                [self saveScrollPositionForWindow:window];
                [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:window];
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

            if ([DCTools isOriginalIPad] && followLiveTail &&
                self.messages.count + toInsert.count > (NSUInteger)DCChatWindowCeiling()) {
                /*
                 * At the live edge continuity behind the viewport is not useful
                 * enough to justify a giant insert+evict cycle.  Keep only the
                 * newest complete 36-message window in one model swap.
                 */
                NSMutableArray *merged = [NSMutableArray arrayWithArray:self.messages];
                [merged addObjectsFromArray:toInsert];
                NSRange keepRange = NSMakeRange(merged.count - DCChatWindowCeiling(),
                                                DCChatWindowCeiling());
                NSArray *kept = [merged subarrayWithRange:keepRange];

                self.restoringWindowPosition = YES;
                [self.messages removeAllObjects];
                [self.messages addObjectsFromArray:kept];
                window.hasMoreAfter = NO;
                window.atPresentTime = YES;
                [self.chatTableView reloadData];
                [self.chatTableView setContentOffset:CGPointZero animated:NO];
                self.restoringWindowPosition = NO;

                NSLog(@"[ChatPerf] A4 compacted forward reconcile to %lu complete messages",
                      (unsigned long)self.messages.count);
                [self saveScrollPositionForWindow:window];
                [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:window];
                return;
            }

            NSMutableArray *indexPaths = NSMutableArray.new;
            NSUInteger insertCount = toInsert.count;
            for (NSUInteger i = 0; i < insertCount; i++) {
                [indexPaths addObject:[NSIndexPath indexPathForRow:i inSection:0]];
                [self.messages addObject:toInsert[i]];
            }
            /*
             * Suppress scroll-position saving and pagination while UIKit performs the
             * intermediate offset changes caused by inserting rows at row zero.
             */
            self.restoringWindowPosition = YES;

            [UIView setAnimationsEnabled:NO];

            [self.chatTableView beginUpdates];
            [self.chatTableView
                insertRowsAtIndexPaths:indexPaths
                      withRowAnimation:UITableViewRowAnimationNone];
            [self.chatTableView endUpdates];

            [UIView setAnimationsEnabled:YES];

            /*
             * The message that was previously newest is now after the inserted block.
             * Reload it because its grouping relationship may have changed.
             */
            if (insertCount < self.messages.count) {
                NSIndexPath *previousNewestPath =
                    [NSIndexPath indexPathForRow:insertCount
                                     inSection:0];

                [self.chatTableView
                    reloadRowsAtIndexPaths:@[ previousNewestPath ]
                          withRowAnimation:UITableViewRowAnimationNone];
            }

            [self.chatTableView layoutIfNeeded];

            if (followLiveTail) {
                /*
                 * The user was at the live edge, so keep following it.
                 */
                [self.chatTableView
                    setContentOffset:CGPointZero
                            animated:YES];

                window.atPresentTime = YES;
            } else {
                /*
                 * Existing rows were pushed farther into the table by the new rows at
                 * row zero. Add their total height to the old offset so the same old
                 * messages remain visible.
                 */
                CGFloat insertedHeight = 0.0f;

                for (NSUInteger row = 0; row < insertCount; row++) {
                    NSIndexPath *path =
                        [NSIndexPath indexPathForRow:row
                                         inSection:0];

                    insertedHeight +=
                        [self.chatTableView
                            rectForRowAtIndexPath:path].size.height;
                }

                CGFloat targetOffsetY =
                    previousOffset.y + insertedHeight;

                targetOffsetY =
                    [self clampedOffsetY:targetOffsetY];

                [self.chatTableView
                    setContentOffset:
                        CGPointMake(previousOffset.x, targetOffsetY)
                            animated:NO];

                window.atPresentTime = NO;
            }

            window.hasMoreAfter = NO;

            self.restoringWindowPosition = NO;

            [self saveScrollPositionForWindow:window];
            [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:window];
        });
    });
}

- (void)activateSelectedChannel {
    NSAssert([NSThread isMainThread], @"Must activate channel on main thread");

    DCChannel *channel =
        DCServerCommunicator.sharedInstance.selectedChannel;

    if (!channel.snowflake.length || !self.chatTableView) {
        return;
    }

    // A non-nil saved chat ID is the entire cold-launch "screen" state.
    // Persist it immediately so an actual crash still reopens this channel.
    [[DCCacheManager sharedInstance]
        saveLastActiveChatChannelID:channel.snowflake];

    DCChannelWindow *previousWindow = _currentWindow;

    if (previousWindow) {
        [self saveScrollPositionForWindow:previousWindow];
        [[DCMessageStore sharedInstance] checkpointWindow:previousWindow];
    }

    [self syncWindowForSelectedChannel];
    [self removeDuplicateMessagesFromWindow:self.currentWindow];

    BOOL changedWindow = previousWindow != self.currentWindow;

    /*
     * reloadData can synchronously generate scroll callbacks. Suppress
     * viewport bookkeeping and pagination until restoration is finished.
     */
    self.restoringWindowPosition = YES;

    // Immediately display cached content.  At the normal live-tail position,
    // do not force UITableView to synchronously lay out the entire visible pass
    // before UIKit's first frame.  A historical saved offset still takes the
    // precise synchronous path so restoration does not visibly jump.
    [self.chatTableView reloadData];

    BOOL needsPreciseSavedOffset =
        self.messages.count > 0 &&
        self.currentWindow.hasSavedContentOffset &&
        fabs(self.currentWindow.savedContentOffsetY +
             self.chatTableView.contentInset.top) > 8.0f;

    if (needsPreciseSavedOffset) {
        [self.chatTableView layoutIfNeeded];
        [self restoreScrollPositionForCurrentWindow];
    } else if (self.messages.count > 0) {
        [self.chatTableView setContentOffset:
            CGPointMake(self.chatTableView.contentOffset.x,
                        -self.chatTableView.contentInset.top)
                                  animated:NO];
    }

    self.restoringWindowPosition = NO;

    /* reloadData does not imply a subsequent scroll event.  Rehydrate once the
     * new/returning channel's visible cells have settled into final geometry. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateVisibleChatMediaResidency];
    });

    if (!changedWindow) {
        // Returning from a profile/modal while still viewing the same channel.
        if (self.currentWindow.atPresentTime &&
            !self.currentWindow.hasMoreAfter) {
            [self handleForwardReconcile];
        }
        return;
    }

    self.deferredWindowTrimDirection = DCWindowTrimDirectionNone;

    // Invalidate controller-global pagination requests from the old channel.
    self.olderLoadGeneration++;
    self.newerLoadGeneration++;
    self.loadingOlderMessages = NO;
    self.loadingNewerMessages = NO;
    self.olderRunwayRequestStartTime = 0.0;
    self.newerRunwayRequestStartTime = 0.0;
    self.olderRunwayRequestedCount = 0;
    self.newerRunwayRequestedCount = 0;

    if (self.messages.count == 0) {
        [self handleChannelLoadCold:channel];
        return;
    }

    if (self.currentWindow.hasMoreAfter) {
        self.currentWindow.atPresentTime = NO;
        return;
    }

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
            continue;
        }
        if (authorMatches) {
            message.author.profileImage = user.profileImage;
            message.author.rawProfileImage = user.rawProfileImage;

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
            message.referencedMessage.author.profileImage = user.profileImage;

            message.referencedMessage.author.rawProfileImage = user.rawProfileImage;

            cell.referencedProfileImage.image = user.profileImage;
        }
    }
}

- (BOOL)chatMediaSubviewShouldBeResident:(UIView *)subview {
    if (!subview || !self.chatTableView) return NO;

    /*
     * A single Discord message can contain enough attachments to make one cell
     * several screens tall.  UITableView considers that cell visible even when
     * most attachment subviews are nowhere near the viewport, so "visible cell"
     * alone is not a safe thumbnail-residency test.
     *
     * Keep a small 96pt runway to avoid churning an image exactly at the edge,
     * but never hydrate every attachment in a giant cell at once.
     */
    CGRect mediaRect = [subview convertRect:subview.bounds toView:self.chatTableView];
    CGRect residencyRect = self.chatTableView.bounds;
    residencyRect.origin.y -= 96.0f;
    residencyRect.size.height += 192.0f;
    return CGRectIntersectsRect(mediaRect, residencyRect);
}

- (CGFloat)chatMediaHydrationDeferVelocityThreshold {
    // Defer new media hydration only during fast motion, with thresholds scaled by memory class.
    switch ([DCResourceManager sharedManager].memoryClass) {
        case DCDeviceMemoryClass256MB: return 1000.0f;
        case DCDeviceMemoryClass512MB: return 1400.0f;
        case DCDeviceMemoryClass1GB: return 1800.0f;
        case DCDeviceMemoryClass2GBPlus: return 2400.0f;
        case DCDeviceMemoryClassUnknown:
        default: return 1000.0f;
    }
}

- (CGFloat)chatMediaHydrationResumeVelocityThreshold {
    /*
     * Hysteresis: once a real fling has deferred new disk/network hydration,
     * don't bounce back and forth around the entry threshold.  Resume only
     * after motion has clearly settled into a slower browse.
     */
    switch ([DCResourceManager sharedManager].memoryClass) {
        case DCDeviceMemoryClass256MB: return 400.0f;
        case DCDeviceMemoryClass512MB: return 550.0f;
        case DCDeviceMemoryClass1GB: return 700.0f;
        case DCDeviceMemoryClass2GBPlus: return 900.0f;
        case DCDeviceMemoryClassUnknown:
        default: return 400.0f;
    }
}

- (BOOL)shouldDeferChatMediaHydration {
    if (!self.chatTableView) return NO;

    BOOL moving = self.chatTableView.dragging ||
                  self.chatTableView.tracking ||
                  self.chatTableView.decelerating ||
                  self.forwardMomentumDisplayLink != nil;
    if (!moving) {
        if (self.chatMediaHydrationDeferred) {
            self.chatMediaHydrationDeferred = NO;
            NSLog(@"[MediaPerf] hydration resumed at rest");
        }
        return NO;
    }

    CGFloat velocity = fabs(self.sampledScrollVelocityY);
    if (self.chatTableView.dragging || self.chatTableView.tracking) {
        CGPoint panVelocity =
            [self.chatTableView.panGestureRecognizer
                velocityInView:self.chatTableView];
        velocity = MAX(velocity, fabs(panVelocity.y));
    }
    if (self.forwardMomentumDisplayLink) {
        velocity = MAX(velocity, fabs(self.forwardMomentumVelocityY));
    }

    CGFloat deferThreshold = [self chatMediaHydrationDeferVelocityThreshold];
    CGFloat resumeThreshold = [self chatMediaHydrationResumeVelocityThreshold];
    BOOL defer = self.chatMediaHydrationDeferred
        ? (velocity > resumeThreshold)
        : (velocity >= deferThreshold);
    if (defer != self.chatMediaHydrationDeferred) {
        self.chatMediaHydrationDeferred = defer;
        NSLog(@"[MediaPerf] hydration %@ velocity %.0f thresholds %.0f/%.0f",
              defer ? @"deferred" : @"resumed",
              velocity,
              deferThreshold,
              resumeThreshold);
    }
    return defer;
}

- (void)updateChatMediaResidencyForCell:(DCChatTableCell *)cell
                              allowLoading:(BOOL)allowLoading {
    if (!cell || !self.chatTableView) return;

    for (UIView *subview in [NSArray arrayWithArray:cell.subviews]) {
        BOOL shouldBeResident = [self chatMediaSubviewShouldBeResident:subview];
        if ([subview isKindOfClass:[UILazyImageView class]]) {
            if (shouldBeResident) {
                [(UILazyImageView *)subview
                    prepareChatThumbnailForDisplaySize:subview.bounds.size
                                         allowLoading:allowLoading];
            } else {
                [(UILazyImageView *)subview releaseChatThumbnailForResidency];
            }
        } else if ([subview isKindOfClass:[DCChatVideoAttachment class]]) {
            if (shouldBeResident) {
                [(DCChatVideoAttachment *)subview
                    prepareForDisplayAllowLoading:allowLoading];
            } else {
                [(DCChatVideoAttachment *)subview releaseThumbnailForResidency];
            }
        } else if ([subview isKindOfClass:[DCChatGifAttachment class]]) {
            if (shouldBeResident) {
                [(DCChatGifAttachment *)subview
                    prepareForDisplayAllowLoading:allowLoading];
            } else {
                [(DCChatGifAttachment *)subview releaseThumbnailForResidency];
            }
        }
    }
}

- (void)updateVisibleChatMediaResidencyAllowLoading:(BOOL)allowLoading {
    if (!self.chatTableView) return;
    for (DCChatTableCell *cell in [self.chatTableView visibleCells]) {
        [self updateChatMediaResidencyForCell:cell allowLoading:allowLoading];
    }
}

- (void)updateVisibleChatMediaResidency {
    BOOL allowLoading = ![self shouldDeferChatMediaHydration];
    [self updateVisibleChatMediaResidencyAllowLoading:allowLoading];
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)tableCell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView != self.chatTableView ||
        ![tableCell isKindOfClass:[DCChatTableCell class]]) {
        return;
    }

    /*
     * A reload/API reconcile can construct a cell before its final table-space
     * geometry is valid.  willDisplayCell is the authoritative stationary
     * presentation hook, so thumbnails no longer depend on the next finger
     * movement to be rehydrated.
     */
    BOOL allowLoading = ![self shouldDeferChatMediaHydration];
    [self updateChatMediaResidencyForCell:(DCChatTableCell *)tableCell
                             allowLoading:allowLoading];
}

- (void)handleChatMediaPurgeVisible {
    assertMainThread();
    for (DCChatTableCell *cell in [self.chatTableView visibleCells]) {
        for (UIView *subview in [NSArray arrayWithArray:cell.subviews]) {
            if ([subview isKindOfClass:[UILazyImageView class]]) {
                [(UILazyImageView *)subview releaseChatThumbnailForResidency];
            } else if ([subview isKindOfClass:[DCChatVideoAttachment class]]) {
                [(DCChatVideoAttachment *)subview releaseThumbnailForResidency];
            } else if ([subview isKindOfClass:[DCChatGifAttachment class]]) {
                [(DCChatGifAttachment *)subview releaseThumbnailForResidency];
            }
        }
    }
}

- (void)handleChatMediaRehydrateVisible {
    assertMainThread();
    [self updateVisibleChatMediaResidency];
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

    BOOL mediaOnly = [[notification.userInfo objectForKey:@"mediaOnly"] boolValue];
    NSIndexPath *indexPath =
        [NSIndexPath indexPathForRow:[self rowForModelIndex:index] inSection:0];

    if (mediaOnly) {
        /*
         * A thumbnail becoming available does not change Markdown, grouping,
         * or row geometry.  Keep the prewarmed DTCoreText frame/layout cache.
         * Offscreen rows need no work at all: their model already owns the
         * loaded media and will consume it when they eventually become visible.
         */
        if (![[self.chatTableView indexPathsForVisibleRows] containsObject:indexPath]) {
            return;
        }

        DCChatTableCell *visibleCell =
            (DCChatTableCell *)[self.chatTableView cellForRowAtIndexPath:indexPath];

        /*
         * Force attachment subviews to rebuild (spinner -> image/video/GIF)
         * while leaving the global DCMessageLayout cache intact.
         */
        visibleCell.configuredLayout = nil;

        CFAbsoluteTime mediaRefreshStart = CFAbsoluteTimeGetCurrent();
        [self.chatTableView beginUpdates];
        [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ]
                                  withRowAnimation:UITableViewRowAnimationNone];
        [self.chatTableView endUpdates];
        NSTimeInterval mediaRefreshTime =
            CFAbsoluteTimeGetCurrent() - mediaRefreshStart;

        if (mediaRefreshTime >= 0.008) {
            NSLog(@"[MediaPerf] visible row refresh %@ %.1fms",
                  message.snowflake ?: @"?",
                  mediaRefreshTime * 1000.0);
        }
        return;
    }

    [[DCCacheManager sharedInstance] invalidateSnowflake:message.snowflake];
    [self.chatTableView beginUpdates];
    [self.chatTableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
    [self.chatTableView endUpdates];
}

- (void)handleMessageCreate:(NSNotification *)notification {
    assertMainThread();

    NSDictionary *payload = notification.userInfo;

    NSString *channelID = payload[@"channel_id"];
    NSString *messageID = payload[@"id"];

    if (![channelID isEqualToString:
            self.currentWindow.channelSnowflake]) {
        return;
    }

    if (!messageID.length) {
        NSLog(@"%s: MESSAGE_CREATE had no message ID",
              __PRETTY_FUNCTION__);
        return;
    }

    NSInteger existingIndex =
        [self modelIndexForMessageSnowflake:messageID];

    if (existingIndex != NSNotFound) {
        /*
         * REST reconciliation or forward pagination already inserted this
         * message. MESSAGE_UPDATE owns genuine content changes, so replaying
         * MESSAGE_CREATE should not append another model object.
         */
        NSLog(@"%s: Ignoring duplicate MESSAGE_CREATE %@",
              __PRETTY_FUNCTION__,
              messageID);
        return;
    }

    /*
     * If this window is already historical, the Gateway message cannot be
     * inserted safely because newer messages are missing.  Bail out before
     * conversion; the old ordering paid the full parser/media/model cost and
     * then discarded the result below.
     */
    if (self.currentWindow.hasMoreAfter) {
        NSAssert(!self.currentWindow.atPresentTime,
                 @"A present-time window cannot also have newer messages missing");
        return;
    }

    // Historical windows defer incoming row insertion until the user returns toward present.
    if ([DCTools isOriginalIPad] &&
        self.chatTableView.contentOffset.y > 10.0f) {
        self.currentWindow.hasMoreAfter = YES;
        self.currentWindow.atPresentTime = NO;
        self.viewingPresentTime = NO;
        NSLog(@"[ChatPerf] A4 deferred live MESSAGE_CREATE %@ while reading history",
              messageID);
        [self saveScrollPositionForWindow:self.currentWindow];
        [[DCMessageStore sharedInstance]
            scheduleCheckpointForWindow:self.currentWindow];
        return;
    }

    DCMessage *newMessage =
        [DCTools convertJsonMessage:payload
                  deferLegacyLayout:[DCTools isOriginalIPad]];

    if (!newMessage || !newMessage.snowflake.length) {
        return;
    }

    if (!newMessage.author.profileImage) {
        [DCTools getUserAvatar:newMessage.author];
    }

    /*
     * Capture viewport state before changing the model or table.
     *
     * Offset zero represents the live edge only because hasMoreAfter is
     * already known to be false above.
     */
    BOOL followLiveTail =
        self.chatTableView.contentOffset.y <= 10.0f;

    CGPoint previousOffset =
        self.chatTableView.contentOffset;

    CGFloat previousContentHeight =
        self.chatTableView.contentSize.height;

    NSInteger rowCount =
        [self.chatTableView numberOfRowsInSection:0];

    NSUInteger oldCount =
        self.messages.count;

    NSUInteger newModelIndex =
        self.messages.count;

    [self.messages addObject:newMessage];

    NSInteger newRow =
        [self rowForModelIndex:newModelIndex];

    NSAssert(newRow == 0,
             @"Newest model object must map to row zero");

    /*
     * Suppress scroll-position caching and pagination while UIKit performs
     * intermediate offset changes during the insertion.
     */
    self.restoringWindowPosition = YES;

    if (rowCount != (NSInteger)oldCount) {
        NSLog(@"%s: Row count mismatch! Expected %ld but got %ld",
              __PRETTY_FUNCTION__,
              (long)oldCount,
              (long)rowCount);

        /*
         * Reload synchronously so the final content size and offset can be
         * corrected in this same operation.
         */
        [[DCCacheManager sharedInstance] invalidateAllMessages];

        [self.chatTableView reloadData];
    } else {
        NSIndexPath *newIndexPath =
            [NSIndexPath indexPathForRow:0
                             inSection:0];

        [UIView setAnimationsEnabled:NO];

        [self.chatTableView beginUpdates];
        [self.chatTableView
            insertRowsAtIndexPaths:@[ newIndexPath ]
                  withRowAnimation:
                      UITableViewRowAnimationNone];
        [self.chatTableView endUpdates];

        /*
         * The previously newest message moved from row 0 to row 1.
         * Its grouping relationship may have changed because of the new
         * message, so reload it.
         */
        if (self.messages.count >= 2) {
            NSIndexPath *previousNewestPath =
                [NSIndexPath indexPathForRow:1
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
    }

    /*
     * Force UITableView to calculate the new content size and any row-height
     * changes caused by message grouping.
     */
    [self.chatTableView layoutIfNeeded];

    if (followLiveTail) {
        /*
         * The user was following the live edge, so keep the new message
         * visible.
         */
        [self.chatTableView
            setContentOffset:CGPointZero
                    animated:NO];

        self.currentWindow.atPresentTime = YES;

        /*
         * Trimming the oldest edge is safe while following live messages.
         */
        [self evictOldestDownToCeiling];
    } else {
        /*
         * Inserting row zero pushes all existing content by the change in
         * total content height. Apply that same delta to the offset so the
         * previously visible messages remain stationary.
         *
         * Using total content-height delta also accounts for row 1 changing
         * height after its grouping relationship is recalculated.
         */
        CGFloat contentHeightDelta =
            self.chatTableView.contentSize.height -
            previousContentHeight;

        CGFloat targetOffsetY =
            previousOffset.y + contentHeightDelta;

        targetOffsetY =
            [self clampedOffsetY:targetOffsetY];

        [self.chatTableView
            setContentOffset:
                CGPointMake(previousOffset.x,
                            targetOffsetY)
                animated:NO];

        self.currentWindow.atPresentTime = NO;
    }

    self.currentWindow.hasMoreAfter = NO;

    self.restoringWindowPosition = NO;

    [self saveScrollPositionForWindow:self.currentWindow];
    [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:self.currentWindow];
}

- (void)handleGuildMemberListUpdated:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleGuildMemberListUpdated:notification];
        });
        return;
    }

    if (!self.chatTableView || !self.currentWindow || self.messages.count == 0) {
        return;
    }

    /*
     * IMPORTANT:
     *
     * GUILD_MEMBERS_CHUNK is requested for authors as history is paged in.
     * The old implementation treated every resulting member-list update as a
     * structural chat change: it invalidated EVERY message layout and called
     * reloadData, which discards prewarmed layouts and forces
     * iOS 6 to rebuild visible cells/heights while the user was scrolling.
     *
     * A member-list update changes identity chrome (nickname/avatar/member
     * metadata), not Markdown text, attachment geometry, grouping, or row
     * height.  Keep all width-aware text/layout caches intact and update only
     * the currently visible labels.  Offscreen cells will naturally pick up
     * the canonical user's latest display name when they are reused later.
     */
    CFAbsoluteTime refreshStart = CFAbsoluteTimeGetCurrent();
    NSUInteger refreshed = 0;

    DCGuild *guild =
        DCServerCommunicator.sharedInstance.selectedChannel.parentGuild;

    NSArray *visiblePaths = [self.chatTableView indexPathsForVisibleRows];
    for (NSIndexPath *indexPath in visiblePaths) {
        NSInteger modelIndex = [self modelIndexForRow:indexPath.row];
        if (modelIndex < 0 || modelIndex >= (NSInteger)self.messages.count) {
            continue;
        }

        DCMessage *message = self.messages[modelIndex];
        DCChatTableCell *cell =
            (DCChatTableCell *)[self.chatTableView cellForRowAtIndexPath:indexPath];
        if (!cell) continue;

        DCMessageLayout *layout = cell.configuredLayout;
        if (!layout) {
            /* This should normally already be present for a visible cell.  If
             * not, use the normal cache-backed lookup without invalidating it. */
            layout = [self layoutForModelIndex:modelIndex];
        }

        if (!layout.grouped && message.author) {
            NSString *displayName = [message.author displayNameInGuild:guild] ?: @"";
            CGSize timestampSize = [message.prettyTimestamp sizeWithFont:cell.timestampLabel.font];
            CGSize nameSize = [displayName sizeWithFont:cell.authorLabel.font];

            CGFloat authorOriginX = cell.authorLabel.x;
            CGFloat gap = 8.0f;
            CGFloat rightPadding = 8.0f;
            CGFloat maxRightEdge = self.chatTableView.width - rightPadding;
            CGFloat naturalTimestampX = authorOriginX + nameSize.width + gap;
            CGFloat maxTimestampX = maxRightEdge - timestampSize.width;
            CGFloat actualTimestampX = MIN(naturalTimestampX, maxTimestampX);
            CGFloat actualNameWidth = MAX(0.0f, actualTimestampX - authorOriginX - gap);

            cell.authorLabel.text = displayName;
            cell.authorLabel.frame = CGRectMake(authorOriginX,
                                                 cell.authorLabel.y,
                                                 actualNameWidth,
                                                 cell.authorLabel.height);
            cell.timestampLabel.frame = CGRectMake(actualTimestampX,
                                                    cell.timestampLabel.y,
                                                    timestampSize.width,
                                                    cell.timestampLabel.height);
        }

        if (layout.hasReference &&
            message.referencedMessage &&
            message.referencedMessage.author) {
            DCMessage *reference = message.referencedMessage;
            NSString *referenceAuthorName =
                [reference.author displayNameInGuild:guild] ?: @"";

            CGSize nameSize =
                [referenceAuthorName sizeWithFont:[UIFont boldSystemFontOfSize:10.0f]];
            CGFloat referenceAuthorWidth = 80.0f + nameSize.width;
            CGFloat maximumAuthorWidth =
                MAX(80.0f, self.chatTableView.width - 80.0f);
            referenceAuthorWidth = MIN(referenceAuthorWidth, maximumAuthorWidth);

            reference.authorNameWidth = referenceAuthorWidth;
            cell.referencedAuthorLabel.text = referenceAuthorName;

            CGFloat referenceWidth =
                MAX(0.0f, self.chatTableView.width - referenceAuthorWidth);
            cell.referencedMessage.frame =
                CGRectMake(referenceAuthorWidth,
                           cell.referencedMessage.y,
                           referenceWidth,
                           cell.referencedMessage.height);
        }

        refreshed++;
    }

    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - refreshStart;
    if (elapsed >= 0.004) {
        NSLog(@"[ChatPerf] member identity refresh %lu visible cells %.1fms (layouts preserved)",
              (unsigned long)refreshed,
              elapsed * 1000.0);
    }
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

    // MESSAGE_UPDATE is partial. Keep a complete server-shaped payload for the
    // next disk checkpoint by overlaying changed top-level fields on the last
    // full payload.
    NSMutableDictionary *mergedSource = [NSMutableDictionary dictionary];
    if ([compareMessage.sourceJSON isKindOfClass:[NSDictionary class]]) {
        [mergedSource addEntriesFromDictionary:compareMessage.sourceJSON];
    }
    if ([notification.userInfo isKindOfClass:[NSDictionary class]]) {
        [mergedSource addEntriesFromDictionary:notification.userInfo];
    }
    if (mergedSource.count) {
        newMessage.sourceJSON = [NSDictionary dictionaryWithDictionary:mergedSource];
    }

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

    newMessage.referencedMessage = compareMessage.referencedMessage;
    newMessage.referencedMessageState = compareMessage.referencedMessageState;

    NSInteger rowCount = [self.chatTableView numberOfRowsInSection:0];
    NSUInteger idx     = [self.messages indexOfObject:compareMessage];
    if (rowCount != self.messages.count) {
        NSLog(@"%s: Row count mismatch! Expected %ld but got %ld", __PRETTY_FUNCTION__, (long)self.messages.count, (long)rowCount);
        [self.messages replaceObjectAtIndex:idx
                                 withObject:newMessage];
        [self handleAsyncReload];
        [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:self.currentWindow];
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
    [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:self.currentWindow];
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

    NSString *deletedID = [notification.userInfo objectForKey:@"id"];

    NSMutableArray *affectedReplies = [NSMutableArray array];

    for (DCMessage *candidate in self.messages) {
        if ([candidate.referencedMessage.snowflake isEqualToString:deletedID]) {

            candidate.referencedMessageState = DCMessageReferenceStateDeleted;

            candidate.referencedMessage.content = @"Message deleted";

            candidate.referencedMessage.author = nil;
            candidate.referencedMessage.authorNameWidth = 80.0f;

            [[DCCacheManager sharedInstance] invalidateSnowflake:candidate.snowflake];

            [affectedReplies addObject:candidate];
        }
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

    NSMutableArray *replyPaths = [NSMutableArray array];

    for (DCMessage *reply in affectedReplies) {
        NSUInteger replyIndex = [self.messages indexOfObjectIdenticalTo:reply];

        if (replyIndex == NSNotFound) {
            continue;
        }

        [replyPaths addObject:[NSIndexPath indexPathForRow:[self rowForModelIndex:replyIndex]inSection:0]];
    }

    if (replyPaths.count) {
        [self.chatTableView reloadRowsAtIndexPaths:replyPaths withRowAnimation:UITableViewRowAnimationNone];
    }
    [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:self.currentWindow];
}

- (void)handleTyping:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleTyping:notification];
        });
        return;
    }
    if (![self isViewLoaded] || self.view.window == nil || !self.typingIndicatorView) {
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

    NSTimer *existingTimer =
        [self.typingUsers objectForKey:typingUserId];

    NSTimer *replacementTimer =
        [NSTimer scheduledTimerWithTimeInterval:10.0
                                         target:self
                                       selector:@selector(typingTimerFired:)
                                       userInfo:typingUserId
                                        repeats:NO];

    /*
     * Install the replacement before invalidating the old timer. The new timer
     * now retains this controller, so invalidating the previous timer cannot
     * destroy the controller in the middle of this method.
     */
    [self.typingUsers setObject:replacementTimer
                         forKey:typingUserId];

    [existingTimer invalidate];

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
        /*
         * Update all controller-owned state while the timer still retains the
         * controller. Invalidation is deliberately the final operation.
         */
        [self.typingUsers removeObjectForKey:typingUserId];
        [self updateTypingIndicator];
        [existingTimer invalidate];
        return;
    }
    [self updateTypingIndicator];
}

- (void)invalidateAllTypingTimers {
    if (!self.typingUsers) {
        return;
    }

    /*
     * Copy first because invalidating timers can alter run-loop ownership.
     */
    NSArray *timers =
        [self.typingUsers.allValues copy];

    [self.typingUsers removeAllObjects];

    for (NSTimer *timer in timers) {
        [timer invalidate];
    }
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

- (void)applyChatTableInversion {
    if (!self.chatTableView) {
        return;
    }

    CGAffineTransform inversion =
        CGAffineTransformMakeScale(1.0f, -1.0f);

    if (!CGAffineTransformEqualToTransform(
            self.chatTableView.transform,
            inversion)) {
        self.chatTableView.transform = inversion;
    }
}

- (void)typingTimerFired:(NSTimer *)timer {
    assertMainThread();

    NSString *typingUserId = timer.userInfo;

    if (![typingUserId isKindOfClass:[NSString class]] ||
        typingUserId.length == 0) {
        return;
    }

    /*
     * A previous timer may have been replaced by a newer typing event.
     * Only remove the entry if this is still the current timer.
     */
    NSTimer *currentTimer =
        [self.typingUsers objectForKey:typingUserId];

    if (currentTimer != timer) {
        return;
    }

    [self.typingUsers removeObjectForKey:typingUserId];
    [self updateTypingIndicator];

    /*
     * This is a nonrepeating timer, so it automatically becomes invalid
     * after firing. Do not invalidate it before touching controller state.
     */
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

    if (message == nil) {
        numberOfMessages = MIN(numberOfMessages, DCInitialMessageLoadCount());
    }

    CGFloat preparedTableWidth = self.chatTableView.bounds.size.width;
    DCMessage *existingOldest = self.messages.firstObject;
    DCMessage *existingSecondOldest = self.messages.count > 1 ? self.messages[1] : nil;
    DCMessageLayoutBuilder *layoutBuilder = self.messageLayoutBuilder;

    DCChannel *channel = DCServerCommunicator.sharedInstance.selectedChannel;
    DCChannelWindow *targetWindow = self.currentWindow;
    NSString *channelId = [channel.snowflake copy];

    NSUInteger loadGeneration = ++self.olderLoadGeneration;
    self.loadingOlderMessages = YES;
    self.olderRunwayRequestStartTime = CFAbsoluteTimeGetCurrent();
    self.olderRunwayRequestedCount = numberOfMessages;

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
                self.olderRunwayRequestStartTime = 0.0;
                self.olderRunwayRequestedCount = 0;
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

        DCGuild *guild = DCServerCommunicator.sharedInstance.selectedChannel.parentGuild;
        if (guild && ![guild.name isEqualToString:@"Direct Messages"]) {
            NSMutableSet *authorIds = [NSMutableSet set];
            for (DCMessage *msg in newMessages) {
                if (msg.author.snowflake) [authorIds addObject:msg.author.snowflake];
            }
            if (authorIds.count) {
                [DCServerCommunicator.sharedInstance
                    requestMemberChunkForUserIds:authorIds.allObjects
                                         inGuild:guild.snowflake];
            }
        }

        /*
         * Do the exact DTCoreText/table-width layouts before UIKit sees the new
         * rows.  DCTools deferred its redundant screen-width measurement for
         * these REST messages, so this is the first authoritative sizing pass.
         */
        CFAbsoluteTime prewarmStart = CFAbsoluteTimeGetCurrent();
        [layoutBuilder
            prewarmLayoutCacheForMessages:newMessages
                          previousMessage:nil
                              nextMessage:existingOldest
                               tableWidth:preparedTableWidth];
        if (existingOldest && newMessages.count) {
            [layoutBuilder
                prewarmLayoutCacheForMessage:existingOldest
                             previousMessage:newMessages.lastObject
                                 nextMessage:existingSecondOldest
                                  tableWidth:preparedTableWidth];
        }
        NSLog(@"[ChatPerf] older batch layout prewarm %lu msgs at %.0fpt: %.3fs",
              (unsigned long)newMessages.count,
              preparedTableWidth,
              CFAbsoluteTimeGetCurrent() - prewarmStart);
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
                self.olderRunwayRequestStartTime = 0.0;
                self.olderRunwayRequestedCount = 0;
                return;
            }

            NSArray *deduped = [self deduplicateAgainstWindow:newMessages];

            if (deduped.count == 0) {
                self.loadingOlderMessages = NO;
                self.olderRunwayRequestStartTime = 0.0;
                self.olderRunwayRequestedCount = 0;
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

                CFAbsoluteTime tableMutationStart = CFAbsoluteTimeGetCurrent();
                [self.chatTableView beginUpdates];
                [self.chatTableView insertRowsAtIndexPaths:indexPaths
                                          withRowAnimation:
                                              UITableViewRowAnimationNone];
                [self.chatTableView endUpdates];
                NSTimeInterval tableMutationTime = CFAbsoluteTimeGetCurrent() - tableMutationStart;
                if (tableMutationTime >= 0.008) {
                    NSLog(@"[ChatPerf] table older insert %lu rows %.1fms",
                          (unsigned long)indexPaths.count,
                          tableMutationTime * 1000.0);
                }

                [UIView setAnimationsEnabled:YES];
            }

            /*
             * A nil anchor represents the initial/latest-message load.
             */
            if (message == nil) {
                self.chatTableView.contentOffset = CGPointZero;
            } else {
                NSInteger evictCount =
                    (NSInteger)self.messages.count - DCChatWindowCeiling();

                if (evictCount > 0) {
                    BOOL activelyScrolling = [self chatIsActivelyScrolling];

                    if (activelyScrolling &&
                        self.messages.count <= DCChatActiveWindowHardCeiling()) {
                        /*
                         * Do not synchronously delete the opposite edge while
                         * the finger/deceleration is active.  iOS 6's variable-
                         * height delete bookkeeping was costing 20-84ms and
                         * forcing offscreen height queries.  Keep a bounded
                         * temporary overage and trim once scrolling becomes idle.
                         */
                        self.deferredWindowTrimDirection =
                            DCWindowTrimDirectionRemoveNewest;
                    } else {
                        [self trimNewestDownToCeilingNow];
                    }
                }
            }

            if (!(self.deferredWindowTrimDirection != DCWindowTrimDirectionNone &&
                  self.messages.count > DCChatWindowCeiling())) {
                [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:targetWindow];
            }
            self.loadingOlderMessages = NO;
            self.olderRunwayRequestStartTime = 0.0;
            self.olderRunwayRequestedCount = 0;
            CGFloat runwayVelocity = [self effectiveRunwayVelocityY];
            if (fabs(runwayVelocity) >= 700.0f) {
                [self maintainMessageRunwayForVelocity:runwayVelocity reason:@"after older insert"];
                [self schedulePresentationRunwayForVelocity:runwayVelocity];
            }
        });

    });
}

- (void)getNewerMessages:(int)numberOfMessages afterMessage:(DCMessage *)message {
    NSAssert([NSThread isMainThread],
             @"getNewerMessages:afterMessage: must be called on the main thread");

    CGFloat preparedTableWidth = self.chatTableView.bounds.size.width;
    DCMessage *existingNewest = self.messages.lastObject;
    DCMessage *existingSecondNewest = self.messages.count > 1
        ? self.messages[self.messages.count - 2] : nil;
    DCMessageLayoutBuilder *layoutBuilder = self.messageLayoutBuilder;

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
    self.newerRunwayRequestStartTime = CFAbsoluteTimeGetCurrent();
    self.newerRunwayRequestedCount = numberOfMessages;

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
                self.newerRunwayRequestStartTime = 0.0;
                self.newerRunwayRequestedCount = 0;
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

        DCGuild *guild = DCServerCommunicator.sharedInstance.selectedChannel.parentGuild;
        if (guild && ![guild.name isEqualToString:@"Direct Messages"]) {
            NSMutableSet *authorIds = [NSMutableSet set];
            for (DCMessage *msg in newMessages) {
                if (msg.author.snowflake) [authorIds addObject:msg.author.snowflake];
            }
            if (authorIds.count) {
                [DCServerCommunicator.sharedInstance
                    requestMemberChunkForUserIds:authorIds.allObjects
                                         inGuild:guild.snowflake];
            }
        }

        /*
         * The old/new page boundary only needs a UITableView row reload when
         * adding the new successor actually changes the existing newest row's
         * grouping geometry.  A conservative cache miss still reloads it.
         */
        DCMessageLayout *oldBoundaryLayout = nil;
        if (existingNewest) {
            oldBoundaryLayout = [[DCCacheManager sharedInstance]
                layoutForSnowflake:existingNewest.snowflake
                       tableWidth:preparedTableWidth
                previousSnowflake:existingSecondNewest.snowflake
                    nextSnowflake:nil
                  editedTimestamp:existingNewest.editedTimestamp];
        }

        CFAbsoluteTime prewarmStart = CFAbsoluteTimeGetCurrent();
        [layoutBuilder
            prewarmLayoutCacheForMessages:newMessages
                          previousMessage:existingNewest
                              nextMessage:nil
                               tableWidth:preparedTableWidth];
        if (existingNewest && newMessages.count) {
            [layoutBuilder
                prewarmLayoutCacheForMessage:existingNewest
                             previousMessage:existingSecondNewest
                                 nextMessage:newMessages.firstObject
                                  tableWidth:preparedTableWidth];
        }

        BOOL boundaryNeedsReload = YES;
        if (oldBoundaryLayout && existingNewest && newMessages.count) {
            DCMessageLayout *newBoundaryLayout = [[DCCacheManager sharedInstance]
                layoutForSnowflake:existingNewest.snowflake
                       tableWidth:preparedTableWidth
                previousSnowflake:existingSecondNewest.snowflake
                    nextSnowflake:((DCMessage *)newMessages.firstObject).snowflake
                  editedTimestamp:existingNewest.editedTimestamp];
            if (newBoundaryLayout) {
                boundaryNeedsReload =
                    oldBoundaryLayout.grouped != newBoundaryLayout.grouped ||
                    oldBoundaryLayout.followedByGrouped != newBoundaryLayout.followedByGrouped ||
                    oldBoundaryLayout.hasReference != newBoundaryLayout.hasReference ||
                    fabs(oldBoundaryLayout.height - newBoundaryLayout.height) > 0.5f ||
                    ![oldBoundaryLayout.reuseIdentifier
                        isEqualToString:newBoundaryLayout.reuseIdentifier];
            }
        }

        NSLog(@"[ChatPerf] newer batch layout prewarm %lu msgs at %.0fpt: %.3fs",
              (unsigned long)newMessages.count,
              preparedTableWidth,
              CFAbsoluteTimeGetCurrent() - prewarmStart);
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
                self.newerRunwayRequestStartTime = 0.0;
                self.newerRunwayRequestedCount = 0;
                return;
            }

            NSArray *deduped =
                [self deduplicateAgainstWindow:newMessages];

            if (deduped.count == 0) {
                [self updatePresentTimeFromTablePosition];

                self.loadingNewerMessages = NO;
                self.newerRunwayRequestStartTime = 0.0;
                self.newerRunwayRequestedCount = 0;
                return;
            }

            NSUInteger oldCount = self.messages.count;

            NSInteger rowCount =
                [self.chatTableView numberOfRowsInSection:0];

            BOOL didReload =
                rowCount != (NSInteger)oldCount;

            /*
             * Capture an actual visible message as the viewport anchor before
             * changing row topology. Summing inserted row heights is fragile
             * on iOS 6 because begin/endUpdates and opposite-edge deletion can
             * clamp contentOffset.
             */
            NSString *viewportAnchorSnowflake = nil;
            CGFloat viewportAnchorY = 0.0f;
            NSArray *visibleBeforeNewerInsert =
                [self.chatTableView indexPathsForVisibleRows];
            NSIndexPath *anchorPathBeforeNewerInsert = nil;
            for (NSIndexPath *path in visibleBeforeNewerInsert) {
                if (!anchorPathBeforeNewerInsert ||
                    path.row < anchorPathBeforeNewerInsert.row) {
                    anchorPathBeforeNewerInsert = path;
                }
            }
            if (anchorPathBeforeNewerInsert &&
                anchorPathBeforeNewerInsert.row < (NSInteger)oldCount) {
                NSInteger anchorModelIndex =
                    [self modelIndexForRow:anchorPathBeforeNewerInsert.row];
                if (anchorModelIndex >= 0 &&
                    anchorModelIndex < (NSInteger)self.messages.count) {
                    DCMessage *anchorMessage = self.messages[anchorModelIndex];
                    viewportAnchorSnowflake = [anchorMessage.snowflake copy];
                    CGRect anchorRect =
                        [self.chatTableView rectForRowAtIndexPath:anchorPathBeforeNewerInsert];
                    viewportAnchorY =
                        anchorRect.origin.y - self.chatTableView.contentOffset.y;
                }
            }

            /*
             * Setting contentOffset after the insert is required to preserve
             * the exact variable-height anchor, but on iOS 6 it cancels
             * UIScrollView's native deceleration. Capture the live velocity so
             * that motion can continue through the display-link path after
             * the complete table mutation/trim is finished.
             */
            CGFloat forwardMomentumVelocity = self.sampledScrollVelocityY;
            if (self.lastVelocitySampleTime > 0.0) {
                NSTimeInterval velocityAge =
                    CFAbsoluteTimeGetCurrent() - self.lastVelocitySampleTime;
                if (velocityAge > 0.0 && velocityAge < 2.0) {
                    forwardMomentumVelocity *=
                        (CGFloat)pow(0.998, velocityAge * 1000.0);
                }
            }
            BOOL shouldTakeOverForwardMomentum =
                self.chatTableView.decelerating &&
                forwardMomentumVelocity < -80.0f &&
                !self.forwardMomentumDisplayLink;

            BOOL wasRestoringWindowPosition = self.restoringWindowPosition;
            self.restoringWindowPosition = YES;

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

                CFAbsoluteTime tableMutationStart = CFAbsoluteTimeGetCurrent();
                [self.chatTableView beginUpdates];
                [self.chatTableView
                    insertRowsAtIndexPaths:indexPaths
                          withRowAnimation:
                              UITableViewRowAnimationNone];
                [self.chatTableView endUpdates];
                NSTimeInterval tableMutationTime = CFAbsoluteTimeGetCurrent() - tableMutationStart;
                if (tableMutationTime >= 0.008) {
                    NSLog(@"[ChatPerf] table newer insert %lu rows %.1fms",
                          (unsigned long)indexPaths.count,
                          tableMutationTime * 1000.0);
                }

                /*
                 * The previously newest visible message is now immediately
                 * after the inserted block—not necessarily row 1 when more
                 * than one message was inserted.
                 */
                NSUInteger previousNewestRow = deduped.count;

                if (boundaryNeedsReload &&
                    oldCount > 0 &&
                    previousNewestRow < self.messages.count) {
                    NSIndexPath *previousNewestPath =
                        [NSIndexPath
                            indexPathForRow:previousNewestRow
                                 inSection:0];

                    CFAbsoluteTime boundaryReloadStart = CFAbsoluteTimeGetCurrent();
                    [self.chatTableView beginUpdates];
                    [self.chatTableView
                        reloadRowsAtIndexPaths:
                            @[ previousNewestPath ]
                              withRowAnimation:
                                  UITableViewRowAnimationNone];
                    [self.chatTableView endUpdates];
                    NSTimeInterval boundaryReloadTime = CFAbsoluteTimeGetCurrent() - boundaryReloadStart;
                    if (boundaryReloadTime >= 0.008) {
                        NSLog(@"[ChatPerf] table newer boundary reload %.1fms",
                              boundaryReloadTime * 1000.0);
                    }
                }

                [UIView setAnimationsEnabled:YES];

                /*
                 * Preserve the same visible message at the same screen Y.
                 * This includes exact variable row heights and any grouping
                 * height change at the old/new page boundary.
                 */
                [self.chatTableView layoutIfNeeded];

                BOOL restoredAnchor = NO;
                if (viewportAnchorSnowflake.length) {
                    NSInteger newAnchorModelIndex =
                        [self modelIndexForMessageSnowflake:viewportAnchorSnowflake];
                    if (newAnchorModelIndex != NSNotFound) {
                        NSInteger newAnchorRow =
                            [self rowForModelIndex:newAnchorModelIndex];
                        if (newAnchorRow >= 0 &&
                            newAnchorRow < [self.chatTableView numberOfRowsInSection:0]) {
                            NSIndexPath *newAnchorPath =
                                [NSIndexPath indexPathForRow:newAnchorRow inSection:0];
                            CGRect newAnchorRect =
                                [self.chatTableView rectForRowAtIndexPath:newAnchorPath];
                            CGFloat targetOffsetY =
                                newAnchorRect.origin.y - viewportAnchorY;
                            targetOffsetY = [self clampedOffsetY:targetOffsetY];
                            [self.chatTableView
                                setContentOffset:CGPointMake(self.chatTableView.contentOffset.x,
                                                             targetOffsetY)
                                       animated:NO];
                            restoredAnchor = YES;
                        }
                    }
                }

                if (!restoredAnchor) {
                    CGFloat addedHeight = 0.0f;
                    for (NSUInteger row = 0; row < deduped.count; row++) {
                        NSIndexPath *indexPath =
                            [NSIndexPath indexPathForRow:row inSection:0];
                        addedHeight +=
                            [self.chatTableView rectForRowAtIndexPath:indexPath].size.height;
                    }
                    CGPoint offset = self.chatTableView.contentOffset;
                    offset.y = [self clampedOffsetY:offset.y + addedHeight];
                    self.chatTableView.contentOffset = offset;
                }
            }

            /*
             * Trim the opposite edge only when the table and model were in
             * sync for the incremental insertion. Preserve the existing
             * reload fallback behavior otherwise.
             */
            if (!didReload) {
                [self evictOldestDownToCeiling];
            }
            [self updatePresentTimeFromTablePosition];
            if (!(self.deferredWindowTrimDirection != DCWindowTrimDirectionNone &&
                  self.messages.count > DCChatWindowCeiling())) {
                [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:targetWindow];
            }

            self.restoringWindowPosition = wasRestoringWindowPosition;
            self.loadingNewerMessages = NO;
            self.newerRunwayRequestStartTime = 0.0;
            self.newerRunwayRequestedCount = 0;

            CGFloat runwayVelocity = [self effectiveRunwayVelocityY];
            if (fabs(runwayVelocity) >= 700.0f) {
                [self maintainMessageRunwayForVelocity:runwayVelocity reason:@"after newer insert"];
                [self schedulePresentationRunwayForVelocity:runwayVelocity];
            }

            if (shouldTakeOverForwardMomentum) {
                [self startForwardMomentumContinuationWithVelocity:
                    forwardMomentumVelocity];
            }
        });

    });
}

- (NSInteger)modelIndexForRow:(NSInteger)row {
    return (NSInteger)self.messages.count - 1 - row;
}

- (NSInteger)modelIndexForMessageSnowflake:(NSString *)snowflake {
    if (!snowflake.length) {
        return NSNotFound;
    }

    for (NSInteger index = 0;
         index < (NSInteger)self.messages.count;
         index++) {

        DCMessage *message = self.messages[index];

        if ([message.snowflake isEqualToString:snowflake]) {
            return index;
        }
    }

    return NSNotFound;
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

    BOOL hasUnknownGeometry = DCMessageHasUnknownAttachmentGeometry(message);

    if (!hasUnknownGeometry) {
        DCMessageLayout *cached = [[DCCacheManager sharedInstance]
            layoutForSnowflake:message.snowflake
                     tableWidth:tableWidth
              previousSnowflake:previousMessage.snowflake
                  nextSnowflake:nextMessage.snowflake
                editedTimestamp:message.editedTimestamp];
        if (cached) return cached;
    }

    /*
     * A cache miss here is synchronous UIKit-critical work.  Time it directly
     * to distinguish row-height misses from DTCoreText drawing and from
     * table insertion hitches.
     */
    CFAbsoluteTime layoutMissStart = CFAbsoluteTimeGetCurrent();
    DCMessageLayout *layout = [self.messageLayoutBuilder layoutForMessage:message
                                                            previousMessage:previousMessage
                                                                 nextMessage:nextMessage
                                                                  tableWidth:tableWidth];
    NSTimeInterval layoutMissTime = CFAbsoluteTimeGetCurrent() - layoutMissStart;

    if (layoutMissTime >= 0.004) {
        NSLog(@"[ChatPerf] layout MISS %@ %.1fms at %.0fpt attachments %lu unknownGeometry %d",
              message.snowflake ?: @"?",
              layoutMissTime * 1000.0,
              tableWidth,
              (unsigned long)message.attachments.count,
              hasUnknownGeometry);
    }

    if (!hasUnknownGeometry) {
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

- (void)ensureAvatarForUser:(DCUser *)user {
    if (!user || !user.snowflake.length) {
        return;
    }

    if (!user.profileImage) {
        [DCTools getUserAvatar:user];
    }
}

- (NSString *)referencePreviewTextForMessage:(DCMessage *)message {
    if (!message || message.messageType != DCMessageTypeReply) {
        return nil;
    }

    if (message.referencedMessageState == DCMessageReferenceStateDeleted) {
        return @"Message deleted";
    }

    DCMessage *reference = message.referencedMessage;
    BOOL resolved = reference && reference.author &&
        (message.referencedMessageState == DCMessageReferenceStateResolved ||
         message.referencedMessageState == DCMessageReferenceStateNone);

    if (!resolved) {
        return @"Unable to load message";
    }

    return reference.content.length ? reference.content : @"Unable to load message";
}

- (NSUInteger)prewarmReferencePresentationsForMessages:(NSArray *)messages {
    if (!messages.count || !self.referencePresentationCache ||
        !self.referenceRunwayParser) {
        return 0;
    }

    NSUInteger warmed = 0;
    for (DCMessage *message in messages) {
        @autoreleasepool {
            if (message.messageType != DCMessageTypeReply ||
                !message.snowflake.length) {
                continue;
            }

            NSString *sourceText = [self referencePreviewTextForMessage:message];
            if (!sourceText) continue;

            /*
             * Mention/custom-emoji parsing consults (and for uncached emoji can
             * mutate) DCServerCommunicator's canonical graph. Keep that work on
             * the visible main-thread fallback rather than speculating off-main.
             * Ordinary prose, links, and formatting remain eligible for runway
             * parsing and cover the expensive compact-parser cases without
             * weakening the graph's main-thread ownership rule.
             */
            if ([sourceText rangeOfString:@"<"].location != NSNotFound ||
                [sourceText rangeOfString:@"@"].location != NSNotFound) {
                continue;
            }

            DCChatReferencePresentation *cached =
                [self.referencePresentationCache objectForKey:message.snowflake];
            if (cached && [cached.sourceText isEqualToString:sourceText] &&
                cached.attributedText) {
                continue;
            }

            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            NSAttributedString *parsed =
                [self.referenceRunwayParser attributedStringFromMarkdown:sourceText];
            NSMutableAttributedString *attributed = [parsed mutableCopy];
            if (attributed.length && self.referenceRunwayShadows) {
                [attributed addAttribute:DTShadowsAttribute
                                   value:self.referenceRunwayShadows
                                   range:NSMakeRange(0, attributed.length)];
            }

            if (attributed) {
                DCChatReferencePresentation *presentation =
                    [[DCChatReferencePresentation alloc] init];
                presentation.sourceText = sourceText;
                presentation.attributedText = [attributed copy];
                [self.referencePresentationCache setObject:presentation
                                                    forKey:message.snowflake];
                warmed++;
            }

            NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - start;
            if (elapsed >= 0.020) {
                NSLog(@"[ChatRunway] reference prewarm %@ %.1fms len %lu",
                      message.snowflake,
                      elapsed * 1000.0,
                      (unsigned long)sourceText.length);
            }
        }
    }
    return warmed;
}

- (CGFloat)effectiveRunwayVelocityY {
    if (self.forwardMomentumDisplayLink) {
        return self.forwardMomentumVelocityY;
    }
    return self.sampledScrollVelocityY;
}

- (void)maintainMessageRunwayForVelocity:(CGFloat)velocityY reason:(NSString *)reason {
    if (!self.chatTableView || self.messages.count == 0 ||
        fabs(velocityY) < 700.0f) {
        return;
    }

    CGFloat viewportHeight = self.chatTableView.bounds.size.height;
    if (viewportHeight <= 0.0f) return;

    CGFloat minimumOffsetY = -self.chatTableView.contentInset.top;
    CGFloat maximumOffsetY = MAX(
        minimumOffsetY,
        self.chatTableView.contentSize.height - viewportHeight +
            self.chatTableView.contentInset.bottom);
    CGFloat currentY = self.chatTableView.contentOffset.y;
    CGFloat targetPoints = DCMessageRunwayTargetPoints(velocityY, viewportHeight);
    int pageCount = DCRunwayMessageLoadCount(velocityY);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CGFloat starvationThreshold = MAX(24.0f, viewportHeight * 0.08f);

    if (velocityY > 0.0f) {
        if (!self.currentWindow.hasMoreBefore) return;
        CGFloat available = MAX(0.0f, maximumOffsetY - currentY);

        if (self.loadingOlderMessages) {
            if (available <= starvationThreshold &&
                now - self.lastOlderRunwayStarvationLog >= 0.25) {
                NSTimeInterval requestAge = self.olderRunwayRequestStartTime > 0.0
                    ? now - self.olderRunwayRequestStartTime : 0.0;
                NSLog(@"[ChatRunway] STARVED older velocity %.0f available %.0f target %.0f inflight 1 requestAge %.0fms page %ld window %lu/%ld",
                      velocityY, available, targetPoints,
                      requestAge * 1000.0,
                      (long)self.olderRunwayRequestedCount,
                      (unsigned long)self.messages.count,
                      (long)([self chatIsActivelyScrolling]
                          ? DCChatActiveWindowHardCeiling()
                          : DCChatWindowHardCeiling()));
                self.lastOlderRunwayStarvationLog = now;
            }
            return;
        }

        if (available <= targetPoints) {
            NSLog(@"[ChatRunway] fetch older %@ velocity %.0f available %.0f target %.0f page %d window %lu/%ld",
                  reason ?: @"scroll", velocityY, available, targetPoints,
                  pageCount, (unsigned long)self.messages.count,
                  (long)([self chatIsActivelyScrolling]
                      ? DCChatActiveWindowHardCeiling()
                      : DCChatWindowHardCeiling()));
            [self getMessages:pageCount beforeMessage:self.messages.firstObject];
        }
    } else {
        if (!self.currentWindow.hasMoreAfter) return;
        CGFloat available = MAX(0.0f, currentY - minimumOffsetY);

        if (self.loadingNewerMessages) {
            if (available <= starvationThreshold &&
                now - self.lastNewerRunwayStarvationLog >= 0.25) {
                NSTimeInterval requestAge = self.newerRunwayRequestStartTime > 0.0
                    ? now - self.newerRunwayRequestStartTime : 0.0;
                NSLog(@"[ChatRunway] STARVED newer velocity %.0f available %.0f target %.0f inflight 1 requestAge %.0fms page %ld window %lu/%ld",
                      velocityY, available, targetPoints,
                      requestAge * 1000.0,
                      (long)self.newerRunwayRequestedCount,
                      (unsigned long)self.messages.count,
                      (long)([self chatIsActivelyScrolling]
                          ? DCChatActiveWindowHardCeiling()
                          : DCChatWindowHardCeiling()));
                self.lastNewerRunwayStarvationLog = now;
            }
            return;
        }

        if (available <= targetPoints) {
            NSLog(@"[ChatRunway] fetch newer %@ velocity %.0f available %.0f target %.0f page %d window %lu/%ld",
                  reason ?: @"scroll", velocityY, available, targetPoints,
                  pageCount, (unsigned long)self.messages.count,
                  (long)([self chatIsActivelyScrolling]
                      ? DCChatActiveWindowHardCeiling()
                      : DCChatWindowHardCeiling()));
            [self getNewerMessages:pageCount afterMessage:self.messages.lastObject];
        }
    }
}

- (void)schedulePresentationRunwayForVelocity:(CGFloat)velocityY {
    if (!self.chatTableView || self.messages.count == 0 ||
        self.presentationRunwayPrewarmPending || fabs(velocityY) < 700.0f) {
        return;
    }

    NSArray *visibleRows = [self.chatTableView indexPathsForVisibleRows];
    if (!visibleRows.count) return;

    NSInteger minimumVisibleRow = NSIntegerMax;
    NSInteger maximumVisibleRow = -1;
    for (NSIndexPath *path in visibleRows) {
        minimumVisibleRow = MIN(minimumVisibleRow, path.row);
        maximumVisibleRow = MAX(maximumVisibleRow, path.row);
    }

    NSInteger direction = velocityY > 0.0f ? 1 : -1;
    NSInteger row = direction > 0 ? maximumVisibleRow + 1 : minimumVisibleRow - 1;
    NSInteger rowCount = [self.chatTableView numberOfRowsInSection:0];
    CGFloat targetPoints = DCPresentationRunwayTargetPoints(
        velocityY, self.chatTableView.bounds.size.height);
    CGFloat accumulatedPoints = 0.0f;
    NSUInteger hardMessageCap =
        ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB)
            ? 30 : 48;

    NSMutableArray *messagesToWarm = [NSMutableArray array];
    while (row >= 0 && row < rowCount &&
           accumulatedPoints < targetPoints &&
           messagesToWarm.count < hardMessageCap) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
        CGRect rect = [self.chatTableView rectForRowAtIndexPath:path];
        accumulatedPoints += MAX(1.0f, rect.size.height);

        NSInteger modelIndex = [self modelIndexForRow:row];
        if (modelIndex >= 0 && modelIndex < (NSInteger)self.messages.count) {
            [messagesToWarm addObject:self.messages[modelIndex]];
        }
        row += direction;
    }

    if (!messagesToWarm.count) return;

    self.presentationRunwayPrewarmPending = YES;
    NSArray *snapshot = [messagesToWarm copy];
    NSString *directionName = direction > 0 ? @"older" : @"newer";
    CGFloat loggedPoints = accumulatedPoints;

    dispatch_async([self get_chat_presentation_queue], ^{
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSUInteger warmed = [self prewarmReferencePresentationsForMessages:snapshot];
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - start;
        if (warmed || elapsed >= 0.008) {
            NSLog(@"[ChatRunway] presentation %@ %lu msgs %.0fpt refs %lu %.1fms",
                  directionName,
                  (unsigned long)snapshot.count,
                  loggedPoints,
                  (unsigned long)warmed,
                  elapsed * 1000.0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.presentationRunwayPrewarmPending = NO;
        });
    });
}

- (void)tableView:(UITableView *)tableView
 didEndDisplayingCell:(UITableViewCell *)tableCell
       forRowAtIndexPath:(NSIndexPath *)indexPath {
    /*
     * iOS 6 provides an exact off-screen callback. Release view-owned pixels
     * immediately instead of waiting for reuse; iOS 5 still gets the
     * prepareForReuse/didMoveToWindow fallback in DCChatTableCell/media views.
     */
    if (![tableCell isKindOfClass:[DCChatTableCell class]]) return;
    DCChatTableCell *cell = (DCChatTableCell *)tableCell;
    for (UIView *subview in [NSArray arrayWithArray:cell.subviews]) {
        if ([subview isKindOfClass:[UILazyImageView class]]) {
            [(UILazyImageView *)subview releaseChatThumbnailForResidency];
        } else if ([subview isKindOfClass:[DCChatVideoAttachment class]]) {
            [(DCChatVideoAttachment *)subview releaseThumbnailForResidency];
        } else if ([subview isKindOfClass:[DCChatGifAttachment class]]) {
            [(DCChatGifAttachment *)subview releaseThumbnailForResidency];
        }
    }
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
        } else {
            NSInteger modelIndex = [self modelIndexForRow:indexPath.row];
            DCMessageLayout *layout = [self layoutForModelIndex:modelIndex];
            if (!layout) {
                return [tableView dequeueReusableCellWithIdentifier:@"Message Cell"];
            }
            CFAbsoluteTime cellPerfStart = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime cellPerfContentStart = 0;
            CFAbsoluteTime cellPerfContentEnd = 0;
            CFAbsoluteTime cellPerfAttachmentsStart = 0;
            CFAbsoluteTime cellPerfAttachmentsEnd = 0;
            CFAbsoluteTime cellPerfDequeueStart = 0;
            CFAbsoluteTime cellPerfDequeueEnd = 0;
            CFAbsoluteTime cellPerfAvatarStart = 0;
            CFAbsoluteTime cellPerfAvatarEnd = 0;
            CFAbsoluteTime cellPerfCleanupStart = 0;
            CFAbsoluteTime cellPerfCleanupEnd = 0;
            CFAbsoluteTime cellPerfReferenceParseStart = 0;
            CFAbsoluteTime cellPerfReferenceParseEnd = 0;
            NSTimeInterval cellPerfReferenceBindTime = 0;
            CFAbsoluteTime cellPerfHeaderStart = 0;
            CFAbsoluteTime cellPerfHeaderEnd = 0;
            CFAbsoluteTime cellPerfPostContentStart = 0;
            CFAbsoluteTime cellPerfPostContentEnd = 0;
            static UIColor *replyHighlightColor = nil;
            static UIColor *pingColor = nil;
            static UIColor *normalColor = nil;
            static UIColor *referenceColor = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                replyHighlightColor = [UIColor colorWithRed:55/255.0f green:59/255.0f blue:64/255.0f alpha:1.0f];
                pingColor           = [UIColor colorWithRed:46/255.0f green:45/255.0f blue:40/255.0f alpha:1.0f];
                normalColor         = [UIColor colorWithRed:40/255.0f green:41/255.0f blue:46/255.0f alpha:1.0f];
                referenceColor      = [UIColor colorWithRed:128/255.0f green:128/255.0f blue:128/255.0f alpha:1.0f];
            });

            cellPerfDequeueStart = CFAbsoluteTimeGetCurrent();
            cell = (DCChatTableCell *)[tableView dequeueReusableCellWithIdentifier:layout.reuseIdentifier];
            cellPerfDequeueEnd = CFAbsoluteTimeGetCurrent();

            cell.transform =
                CGAffineTransformMakeScale(1.0f, -1.0f);

            BOOL sameMessage =
                cell.messageSnowflake.length &&
                [cell.messageSnowflake
                    isEqualToString:messageAtRowIndex.snowflake];

            BOOL sameLayout =
                cell.configuredLayout == layout;

            BOOL isReplyTarget =
                self.replyingToMessage &&
                [self.replyingToMessage.snowflake isEqualToString:messageAtRowIndex.snowflake];

            BOOL isEditTarget =
                self.editingMessage &&
                [self.editingMessage.snowflake isEqualToString:messageAtRowIndex.snowflake];

            // Make the cells append avatars themselves
            cellPerfAvatarStart = CFAbsoluteTimeGetCurrent();
            [self ensureAvatarForUser:messageAtRowIndex.author];

            DCMessage *reference = messageAtRowIndex.referencedMessage;

            BOOL referenceResolved = reference && reference.author &&
                (messageAtRowIndex.referencedMessageState ==
                    DCMessageReferenceStateResolved ||
                 messageAtRowIndex.referencedMessageState ==
                    DCMessageReferenceStateNone);

            if (reference.author) {
                [self ensureAvatarForUser:reference.author];
            }
            cellPerfAvatarEnd = CFAbsoluteTimeGetCurrent();

            /*
             * Fast path:
             * If this reusable cell is already configured for this exact message and
             * layout, refresh lightweight volatile fields only and skip the expensive
             * markdown/layout/image attachment rebuild.
             */
            if (sameMessage && sameLayout && !isReplyTarget && !isEditTarget) {
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

                /*
                 * A cell may have been fully rebuilt while it was the active
                 * reply/edit target.  Once that state clears, the same-message
                 * fast path must also restore its steady-state background or it
                 * can retain the old highlight indefinitely.
                 */
                cell.contentView.backgroundColor =
                    messageAtRowIndex.pingingUser ? pingColor : normalColor;

                // Preserve the visible media view's hydrated thumbnail.
                return cell;
            }
            cell.configuredLayout = nil;
            cellPerfCleanupStart = CFAbsoluteTimeGetCurrent();
            // cleanup loop
            for (UIView *subView in cell.subviews) {
                @autoreleasepool {
                    if ([subView isKindOfClass:[UILazyImageView class]]) {
                        [(UILazyImageView *)subView releaseChatThumbnailForResidency];
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[DCChatVideoAttachment class]]) {
                        [(DCChatVideoAttachment *)subView releaseThumbnailForResidency];
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
                        [(DCChatGifAttachment *)subView releaseThumbnailForResidency];
                        [subView removeFromSuperview];
                    }
                    if ([subView isKindOfClass:[UIActivityIndicatorView class]]) {
                        [subView removeFromSuperview];
                    }
                }
            }

            [cell.contentTextView removeAllCustomViewsForLinks];
            [cell.referencedMessage removeAllCustomViewsForLinks];
            cellPerfCleanupEnd = CFAbsoluteTimeGetCurrent();

            if (layout.hasReference) {
                NSString *referenceText =
                    [self referencePreviewTextForMessage:messageAtRowIndex] ?:
                    @"Unable to load message";
                NSString *referenceAuthorName = @"";
                CGFloat referenceAuthorWidth = 80.0f;

                if (referenceResolved) {
                    referenceAuthorName = [reference.author displayNameInGuild:DCServerCommunicator.sharedInstance.selectedChannel.parentGuild] ?: @"";

                    CGSize nameSize = [referenceAuthorName sizeWithFont: [UIFont boldSystemFontOfSize:10.0f]];

                    referenceAuthorWidth = 80.0f + nameSize.width;

                    CGFloat maximumAuthorWidth = MAX(80.0f, self.chatTableView.width - 80.0f);

                    referenceAuthorWidth = MIN(referenceAuthorWidth, maximumAuthorWidth);
                }

                CFAbsoluteTime referenceBindStart = CFAbsoluteTimeGetCurrent();
                cell.referencedAuthorLabel.text = referenceAuthorName;
                cell.referencedProfileImage.image = referenceResolved ? reference.author.profileImage : nil;

                CGFloat referenceWidth = MAX(0.0f, self.chatTableView.width - referenceAuthorWidth);

                // Clear stale reply layout and set final geometry before binding new text.
                cell.referencedMessage.layoutFrame = nil;
                cell.referencedMessage.attributedString = nil;
                cell.referencedMessage.frame =
                    CGRectMake(referenceAuthorWidth,
                               cell.referencedMessage.y,
                               referenceWidth,
                               cell.referencedMessage.height);
                cellPerfReferenceBindTime +=
                    (CFAbsoluteTimeGetCurrent() - referenceBindStart);

                cellPerfReferenceParseStart = CFAbsoluteTimeGetCurrent();
                NSAttributedString *referencedContent = nil;
                DCChatReferencePresentation *cachedReference =
                    [self.referencePresentationCache objectForKey:messageAtRowIndex.snowflake];
                if (cachedReference &&
                    [cachedReference.sourceText isEqualToString:referenceText]) {
                    referencedContent = cachedReference.attributedText;
                }

                if (!referencedContent) {
                    referencedContent =
                        [[DCMarkdownParser sharedParser]
                            attributedStringFromMarkdown:referenceText
                                             maxFontSize:10.0f
                                                   color:referenceColor];
                    if (referencedContent && messageAtRowIndex.snowflake.length) {
                        DCChatReferencePresentation *presentation =
                            [[DCChatReferencePresentation alloc] init];
                        presentation.sourceText = referenceText;
                        presentation.attributedText = referencedContent;
                        [self.referencePresentationCache setObject:presentation
                                                            forKey:messageAtRowIndex.snowflake];
                    }
                }
                cellPerfReferenceParseEnd = CFAbsoluteTimeGetCurrent();

                CFAbsoluteTime referenceStringBindStart = CFAbsoluteTimeGetCurrent();
                cell.referencedMessage.attributedString = referencedContent;
                cellPerfReferenceBindTime +=
                    (CFAbsoluteTimeGetCurrent() - referenceStringBindStart);

                /*
                 * Deleted and unavailable references should not behave like
                 * navigable messages.
                 */
                if (referenceResolved && reference.snowflake.length) {

                    UIButton *referencedMessageButton = [UIButton buttonWithType: UIButtonTypeCustom];

                    referencedMessageButton.frame =
                        CGRectMake(
                            cell.referencedProfileImage.x,
                            cell.referencedMessage.y,
                            cell.referencedMessage.x +
                                cell.referencedMessage.width -
                                cell.referencedProfileImage.x,
                            cell.referencedMessage.height);

                    referencedMessageButton.exclusiveTouch = YES;

                    [referencedMessageButton addTarget:self action: @selector(tappedReferencedMessage:) forControlEvents: UIControlEventTouchUpInside];

                    [cell addSubview: referencedMessageButton];
                }
            }

            cellPerfHeaderStart = CFAbsoluteTimeGetCurrent();
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
            cellPerfHeaderEnd = CFAbsoluteTimeGetCurrent();

            float contentWidth = self.chatTableView.width - 63;

            // Set content
            cellPerfContentStart = CFAbsoluteTimeGetCurrent();

            cell.contentTextView.delegate = self;
            cell.contentTextView.userInteractionEnabled = YES;

            NSCharacterSet *invisibleChars = [NSCharacterSet characterSetWithCharactersInString:@"\u00A0\u200B\n\r\t "];
            BOOL hasVisibleContent = [[messageAtRowIndex.content stringByTrimmingCharactersInSet:invisibleChars] length] > 0 
                || messageAtRowIndex.emojis.count > 0;
            CGFloat textHeight = layout.textHeight;

            if (!hasVisibleContent) {
                // Drop the previous message's DTCoreText frame before changing
                // the string/frame.  Otherwise DTAttributedLabel eagerly
                // relayouts the NEW string using the OLD cell geometry.
                cell.contentTextView.layoutFrame = nil;
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

                // Reuse the prepared DTCoreText frame; clear stale geometry before binding it.
                cell.contentTextView.layoutFrame = nil;
                cell.contentTextView.attributedString = messageAtRowIndex.attributedContent;
                cell.contentTextView.frame = CGRectMake(
                    cell.contentTextView.x,
                    cell.contentTextView.y,
                    contentWidth,
                    textHeight
                );
                cell.contentTextView.layoutFrame = layout.textLayoutFrame;

                // Link buttons and custom emoji views still need to be built
                // from the prepared frame.  This traverses the already-laid-out
                // glyph runs; it no longer asks DTCoreText to shape/layout the
                // text again.
                [cell.contentTextView layoutSubviewsInRect:CGRectInfinite];
            }
            cellPerfContentEnd = CFAbsoluteTimeGetCurrent();
            cellPerfPostContentStart = CFAbsoluteTimeGetCurrent();
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
            cellPerfPostContentEnd = CFAbsoluteTimeGetCurrent();

            cellPerfAttachmentsStart = CFAbsoluteTimeGetCurrent();
            BOOL allowAttachmentHydration =
                ![self shouldDeferChatMediaHydration];
            for (id attachment in messageAtRowIndex.attachments) {
                @autoreleasepool {
                    if ([attachment isKindOfClass:[UILazyImage class]]) {
                        UILazyImageView *imageView = [UILazyImageView new];
                        UILazyImage *lazyImage     = attachment;
                        CGSize sourceSize = CGSizeZero;
                        if (lazyImage.naturalSize.width > 0 && lazyImage.naturalSize.height > 0) {
                            sourceSize = lazyImage.naturalSize;
                        } else if (lazyImage.image) {
                            sourceSize = lazyImage.image.size;
                        }
                        if (sourceSize.width <= 0 || sourceSize.height <= 0) continue;
                        CGFloat aspectRatio = sourceSize.width / sourceSize.height;
                        int newWidth  = messageAtRowIndex.isSticker ? 160 : (int)(200 * aspectRatio);
                        int newHeight = messageAtRowIndex.isSticker ? 160 : 200;
                        if (newWidth > self.chatTableView.width - 66) {
                            newWidth  = self.chatTableView.width - 66;
                            newHeight = newWidth / aspectRatio;
                        }
                        imageView.frame = CGRectMake(
                            55, imageViewOffset, newWidth, newHeight
                        );
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
                        if ([self chatMediaSubviewShouldBeResident:imageView]) {
                            [imageView prepareChatThumbnailForDisplaySize:
                                CGSizeMake(newWidth, newHeight)
                                                        allowLoading:
                                                            allowAttachmentHydration];
                        }
                    } else if ([attachment
                                   isKindOfClass:[DCChatVideoAttachment class]]) {
                        DCChatVideoAttachment *video = attachment;

                        NSArray *existingRecognizers = [NSArray arrayWithArray:video.gestureRecognizers];
                        for (UIGestureRecognizer *gr in existingRecognizers) {
                            [video removeGestureRecognizer:gr];
                        }
                        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc]
                            initWithTarget:self action:@selector(tappedVideo:)];
                        singleTap.numberOfTapsRequired = 1;
                        [video addGestureRecognizer:singleTap];

                        CGSize videoSize = CGSizeZero;
                        if (video.naturalSize.width > 0 && video.naturalSize.height > 0) {
                            videoSize = video.naturalSize;
                        } else if (video.thumbnailImage) {
                            videoSize = video.thumbnailImage.size;
                        } else {
                            videoSize = CGSizeMake(16, 9);
                        }
                        CGFloat aspectRatio = videoSize.width / videoSize.height;
                        int newWidth  = 200 * aspectRatio;
                        int newHeight = 200;
                        if (newWidth > self.chatTableView.width - 66) {
                            newWidth  = self.chatTableView.width - 66;
                            newHeight = newWidth / aspectRatio;
                        }
                        [video setFrame:CGRectMake(55, imageViewOffset, newWidth, newHeight)];

                        imageViewOffset += newHeight;

                        [cell addSubview:video];
                        if ([self chatMediaSubviewShouldBeResident:video]) {
                            [video prepareForDisplayAllowLoading:
                                allowAttachmentHydration];
                        }
                    } else if ([attachment isKindOfClass:[DCGifInfo class]]) {
                        DCGifInfo *gifInfo = (DCGifInfo *)attachment;
                        CGSize gifSize = CGSizeZero;
                        if (gifInfo.naturalSize.width > 0 && gifInfo.naturalSize.height > 0) {
                            gifSize = gifInfo.naturalSize;
                        } else if (gifInfo.staticThumbnail) {
                            gifSize = gifInfo.staticThumbnail.size;
                        } else {
                            continue;
                        }

                        CGFloat aspectRatio = gifSize.width / gifSize.height;
                        int newWidth  = (int)(200 * aspectRatio);
                        int newHeight = 200;
                        if (newWidth > self.chatTableView.width - 66) {
                            newWidth  = self.chatTableView.width - 66;
                            newHeight = newWidth / aspectRatio;
                        }

                        DCChatGifAttachment *gif = [[[NSBundle mainBundle]
                            loadNibNamed:@"DCChatGifAttachment"
                                   owner:nil
                                 options:nil] objectAtIndex:0];
                        gifInfo.view = gif;
                        gif.staticThumbnail = nil;
                        gif.gifURL = gifInfo.gifURL;
                        gif.thumbnailURL = gifInfo.thumbnailURL;
                        [gif setFrame:CGRectMake(55, imageViewOffset, newWidth, newHeight)];
                        imageViewOffset += newHeight;
                        [cell addSubview:gif];
                        if ([self chatMediaSubviewShouldBeResident:gif]) {
                            [gif prepareForDisplayAllowLoading:
                                allowAttachmentHydration];
                        }
                    } else if ([attachment isKindOfClass:[QLPreviewController class]]) {
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
                            activityIndicator.center = CGPointMake(
                                55.0f + (newWidth * 0.5f),
                                imageViewOffset + (newHeight * 0.5f));
                            imageViewOffset += newHeight + 11;

                            [cell addSubview:activityIndicator];
                            [activityIndicator startAnimating];
                        }
                    }
                }
            }
        cellPerfAttachmentsEnd = CFAbsoluteTimeGetCurrent();

        /*
         * Diagnostics only: a retained live message with attributed text must
         * never reach a visible row with a zero text layout. Likewise, an
         * attachmentCount with an empty attachment model would indicate that
         * media geometry was published after layout prewarm (the old video
         * race). Do not repair either condition here; preserve evidence.
         */
        if (layout.textHeight <= 0.0f &&
            (messageAtRowIndex.attributedContent.length > 0 ||
             messageAtRowIndex.content.length > 0 ||
             messageAtRowIndex.rawContent.length > 0)) {
            NSLog(@"[LayoutDiag] VISIBLE ZERO-TEXT LAYOUT %@ "
                  @"row %ld rowH %.0f raw %lu content %lu attr %lu "
                  @"attrObject %@ atts %lu/%ld frame %@",
                  messageAtRowIndex.snowflake ?: @"?",
                  (long)indexPath.row,
                  layout.height,
                  (unsigned long)messageAtRowIndex.rawContent.length,
                  (unsigned long)messageAtRowIndex.content.length,
                  (unsigned long)messageAtRowIndex.attributedContent.length,
                  messageAtRowIndex.attributedContent ? @"present" : @"nil",
                  (unsigned long)messageAtRowIndex.attachments.count,
                  (long)messageAtRowIndex.attachmentCount,
                  layout.textLayoutFrame ? @"cached" : @"missing");
        }

        if (messageAtRowIndex.attachmentCount > 0 &&
            messageAtRowIndex.attachments.count == 0) {
            NSLog(@"[LayoutDiag] VISIBLE ATTACHMENT MODEL MISMATCH %@ "
                  @"row %ld rowH %.0f attachmentCount %ld arrayCount %lu",
                  messageAtRowIndex.snowflake ?: @"?",
                  (long)indexPath.row,
                  layout.height,
                  (long)messageAtRowIndex.attachmentCount,
                  (unsigned long)messageAtRowIndex.attachments.count);
        }

        CFAbsoluteTime cellPerfEnd = CFAbsoluteTimeGetCurrent();
        NSTimeInterval cellPerfTotal = cellPerfEnd - cellPerfStart;
        if (cellPerfTotal >= 0.005) {
            NSTimeInterval contentTime =
                (cellPerfContentEnd > cellPerfContentStart)
                    ? (cellPerfContentEnd - cellPerfContentStart) : 0;
            NSTimeInterval attachmentTime =
                (cellPerfAttachmentsEnd > cellPerfAttachmentsStart)
                    ? (cellPerfAttachmentsEnd - cellPerfAttachmentsStart) : 0;
            NSTimeInterval otherTime = MAX(0, cellPerfTotal - contentTime - attachmentTime);
            NSLog(@"[ChatPerf] cell %@ total %.1fms content %.1fms attachments %.1fms "
                  @"other %.1fms textH %.0f rowH %.0f atts %lu/%ld ref %d frame %@",
                  messageAtRowIndex.snowflake ?: @"?",
                  cellPerfTotal * 1000.0,
                  contentTime * 1000.0,
                  attachmentTime * 1000.0,
                  otherTime * 1000.0,
                  layout.textHeight,
                  layout.height,
                  (unsigned long)messageAtRowIndex.attachments.count,
                  (long)messageAtRowIndex.attachmentCount,
                  layout.hasReference,
                  layout.textLayoutFrame ? @"cached" : @"missing");

            if (cellPerfTotal >= 0.020 || otherTime >= 0.020) {
                NSTimeInterval dequeueTime =
                    (cellPerfDequeueEnd > cellPerfDequeueStart)
                        ? (cellPerfDequeueEnd - cellPerfDequeueStart) : 0;
                NSTimeInterval avatarTime =
                    (cellPerfAvatarEnd > cellPerfAvatarStart)
                        ? (cellPerfAvatarEnd - cellPerfAvatarStart) : 0;
                NSTimeInterval cleanupTime =
                    (cellPerfCleanupEnd > cellPerfCleanupStart)
                        ? (cellPerfCleanupEnd - cellPerfCleanupStart) : 0;
                NSTimeInterval referenceParseTime =
                    (cellPerfReferenceParseEnd > cellPerfReferenceParseStart)
                        ? (cellPerfReferenceParseEnd - cellPerfReferenceParseStart) : 0;
                NSTimeInterval referenceBindTime = cellPerfReferenceBindTime;
                NSTimeInterval headerTime =
                    (cellPerfHeaderEnd > cellPerfHeaderStart)
                        ? (cellPerfHeaderEnd - cellPerfHeaderStart) : 0;
                NSTimeInterval postContentTime =
                    (cellPerfPostContentEnd > cellPerfPostContentStart)
                        ? (cellPerfPostContentEnd - cellPerfPostContentStart) : 0;

                NSTimeInterval accounted = dequeueTime + avatarTime + cleanupTime +
                    referenceParseTime + referenceBindTime + headerTime +
                    contentTime + postContentTime + attachmentTime;
                NSTimeInterval residual = MAX(0, cellPerfTotal - accounted);

                NSLog(@"[ChatPerf] cell detail %@ dequeue %.1f avatar %.1f cleanup %.1f "
                      @"refParse %.1f refBind %.1f header %.1f content %.1f post %.1f "
                      @"attachments %.1f residual %.1f ref %d",
                      messageAtRowIndex.snowflake ?: @"?",
                      dequeueTime * 1000.0,
                      avatarTime * 1000.0,
                      cleanupTime * 1000.0,
                      referenceParseTime * 1000.0,
                      referenceBindTime * 1000.0,
                      headerTime * 1000.0,
                      contentTime * 1000.0,
                      postContentTime * 1000.0,
                      attachmentTime * 1000.0,
                      residual * 1000.0,
                      layout.hasReference);
            }
        }

        cell.messageSnowflake =
            [messageAtRowIndex.snowflake copy];

        cell.configuredLayout = layout;
        }
    }
    cell.transform = CGAffineTransformMakeScale(1, -1);
    return cell;
}

- (void)attributedTextContentView:(DTAttributedTextContentView *)attributedTextContentView
             willDrawLayoutFrame:(DTCoreTextLayoutFrame *)layoutFrame
                       inContext:(CGContextRef)context {
    objc_setAssociatedObject(attributedTextContentView,
                             &kDCChatTextDrawStartKey,
                             [NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent()],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)attributedTextContentView:(DTAttributedTextContentView *)attributedTextContentView
              didDrawLayoutFrame:(DTCoreTextLayoutFrame *)layoutFrame
                       inContext:(CGContextRef)context {
    NSNumber *startNumber = objc_getAssociatedObject(attributedTextContentView,
                                                      &kDCChatTextDrawStartKey);
    if (!startNumber) return;

    NSTimeInterval drawTime = CFAbsoluteTimeGetCurrent() - [startNumber doubleValue];
    if (drawTime < 0.004) return;

    UIView *view = attributedTextContentView;
    while (view && ![view isKindOfClass:[DCChatTableCell class]]) {
        view = view.superview;
    }

    DCChatTableCell *cell = (DCChatTableCell *)view;
    NSString *kind = (cell && attributedTextContentView == cell.referencedMessage)
        ? @"reference" : @"content";

    NSLog(@"[ChatPerf] text draw %@ %@ %.1fms size %.0fx%.0f lines %lu",
          cell.messageSnowflake ?: @"?",
          kind,
          drawTime * 1000.0,
          attributedTextContentView.bounds.size.width,
          attributedTextContentView.bounds.size.height,
          (unsigned long)layoutFrame.lines.count);
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

- (void)updatePresentTimeFromTablePosition {
    if (!self.currentWindow || !self.chatTableView) {
        return;
    }

    BOOL atNewestLoadedEdge =
        self.chatTableView.contentOffset.y <= 10.0f;

    self.viewingPresentTime =
        atNewestLoadedEdge &&
        !self.currentWindow.hasMoreAfter;
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

- (void)stopForwardMomentumContinuation {
    if (self.forwardMomentumDisplayLink) {
        [self.forwardMomentumDisplayLink invalidate];
        self.forwardMomentumDisplayLink = nil;
    }
    self.forwardMomentumVelocityY = 0.0f;
    self.forwardMomentumLastTimestamp = 0.0;
    self.forwardMomentumBlockedOnData = NO;
}

- (void)startForwardMomentumContinuationWithVelocity:(CGFloat)velocityY {
    /*
     * In this flipped table, returning toward the live/newer edge decreases
     * contentOffset.y. Only take over that direction. Native deceleration is
     * left completely alone for ordinary/older-history scrolling.
     */
    if (velocityY >= -80.0f) {
        return;
    }

    [self stopForwardMomentumContinuation];

    self.forwardMomentumVelocityY = velocityY;
    self.forwardMomentumLastTimestamp = 0.0;

    CADisplayLink *link =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(forwardMomentumTick:)];
    self.forwardMomentumDisplayLink = link;
    [link addToRunLoop:[NSRunLoop mainRunLoop]
               forMode:NSRunLoopCommonModes];

    NSLog(@"[ChatPerf] newer momentum takeover %.0fpt/s at offset %.0f",
          velocityY, self.chatTableView.contentOffset.y);
}

- (void)forwardMomentumTick:(CADisplayLink *)displayLink {
    if (!self.chatTableView ||
        self.chatTableView.dragging ||
        self.chatTableView.tracking) {
        [self stopForwardMomentumContinuation];
        return;
    }

    CFTimeInterval now = displayLink.timestamp;
    if (self.forwardMomentumLastTimestamp <= 0.0) {
        self.forwardMomentumLastTimestamp = now;
        return;
    }

    CFTimeInterval dt = now - self.forwardMomentumLastTimestamp;
    self.forwardMomentumLastTimestamp = now;
    if (dt <= 0.0 || dt > 0.10) {
        return;
    }

    /*
     * UIScrollViewDecelerationRateNormal is approximately 0.998 per
     * millisecond. Integrate the same exponential decay over the actual
     * display-link interval so this continues like a native fling rather
     * than a fixed-duration programmatic scroll.
     */
    const double ratePerMillisecond = 0.998;
    double milliseconds = dt * 1000.0;
    double decay = pow(ratePerMillisecond, milliseconds);
    double velocity = self.forwardMomentumVelocityY;
    double distance =
        (velocity / 1000.0) *
        ((1.0 - decay) / (1.0 - ratePerMillisecond));

    CGFloat currentY = self.chatTableView.contentOffset.y;
    CGFloat proposedY = currentY + (CGFloat)distance;
    CGFloat clampedY = [self clampedOffsetY:proposedY];

    if (fabs(clampedY - currentY) > 0.01f) {
        [self.chatTableView
            setContentOffset:CGPointMake(self.chatTableView.contentOffset.x,
                                         clampedY)
                   animated:NO];
    }

    BOOL hitNewerEdge =
        (proposedY < clampedY - 0.5f);

    if (hitNewerEdge) {
        if (!self.currentWindow.hasMoreAfter) {
            [self stopForwardMomentumContinuation];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateVisibleChatMediaResidency];
            });
            return;
        }

        // Preserve momentum while waiting for newer data rather than consuming it at the loaded edge.
        if (!self.forwardMomentumBlockedOnData) {
            NSLog(@"[ChatRunway] momentum blocked on newer data %.0fpt/s",
                  self.forwardMomentumVelocityY);
            self.forwardMomentumBlockedOnData = YES;
        }
        [self maintainMessageRunwayForVelocity:self.forwardMomentumVelocityY
                                        reason:@"blocked edge"];
        return;
    }

    if (self.forwardMomentumBlockedOnData) {
        NSLog(@"[ChatRunway] momentum resumed after data %.0fpt/s",
              self.forwardMomentumVelocityY);
        self.forwardMomentumBlockedOnData = NO;
    }

    self.forwardMomentumVelocityY = (CGFloat)(velocity * decay);

    if (fabs(self.forwardMomentumVelocityY) < 30.0f &&
        !self.loadingNewerMessages) {
        [self stopForwardMomentumContinuation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateVisibleChatMediaResidency];
            [self performDeferredWindowTrimIfNeeded];
        });
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.chatTableView) {
        return;
    }

    if (self.restoringWindowPosition) {
        [self updateVisibleChatMediaResidency];
        return;
    }

    /*
     * Keep a current velocity estimate for the one case where UITableView row
     * insertion forces replacement of native deceleration. Do not sample the
     * own display-link continuation or programmatic anchor corrections.
     */
    CFAbsoluteTime velocityNow = CFAbsoluteTimeGetCurrent();
    if (!self.forwardMomentumDisplayLink &&
        self.lastVelocitySampleTime > 0.0) {
        NSTimeInterval velocityDT =
            velocityNow - self.lastVelocitySampleTime;
        if (velocityDT >= 0.005 && velocityDT <= 0.15) {
            CGFloat velocity =
                (scrollView.contentOffset.y - self.lastVelocitySampleOffsetY) /
                velocityDT;
            if (fabs(velocity) < 12000.0f) {
                self.sampledScrollVelocityY = velocity;
            }
        }
    }
    self.lastVelocitySampleTime = velocityNow;
    self.lastVelocitySampleOffsetY = scrollView.contentOffset.y;

    // Fast scrolling may reuse resident thumbnails but must not start new media I/O.
    [self updateVisibleChatMediaResidency];

    // Save position before pagination returns or programmatic offset corrections.
    [self saveScrollPositionForWindow:self.currentWindow];

    /*
     * In the flipped table, offset zero is the newest loaded edge.
     * It is the live present only when no newer messages remain outside
     * the current window.
     */
    BOOL atNewestLoadedEdge =
        scrollView.contentOffset.y <= 10.0f;

    BOOL windowContainsLiveTail =
        !self.currentWindow.hasMoreAfter;

    self.viewingPresentTime =
        atNewestLoadedEdge && windowContainsLiveTail;

    if (self.messages.count == 0) {
        return;
    }

    BOOL userIsScrolling =
        scrollView.dragging ||
        scrollView.decelerating ||
        scrollView.tracking ||
        self.forwardMomentumDisplayLink != nil;

    if (!userIsScrolling) {
        self.lastScrollPerfEventTime = 0;
        return;
    }

    CGFloat runwayVelocity = [self effectiveRunwayVelocityY];
    [self maintainMessageRunwayForVelocity:runwayVelocity reason:@"scroll"];
    [self schedulePresentationRunwayForVelocity:runwayVelocity];

    CFAbsoluteTime scrollNow = CFAbsoluteTimeGetCurrent();
    if (self.lastScrollPerfEventTime > 0) {
        NSTimeInterval scrollGap = scrollNow - self.lastScrollPerfEventTime;
        if (scrollGap >= 0.035) {
            NSArray *visible = [self.chatTableView indexPathsForVisibleRows];
            NSIndexPath *first = visible.count ? visible[0] : nil;
            NSIndexPath *last = visible.count ? visible[visible.count - 1] : nil;
            NSLog(@"[ChatPerf] scroll gap %.1fms offset %.0f rows %@-%@ loading older:%d newer:%d",
                  scrollGap * 1000.0,
                  scrollView.contentOffset.y,
                  first ? @(first.row) : @"?",
                  last ? @(last.row) : @"?",
                  self.loadingOlderMessages,
                  self.loadingNewerMessages);
        }
    }
    self.lastScrollPerfEventTime = scrollNow;

    if (!self.loadingOlderMessages
        && self.currentWindow.hasMoreBefore
        && scrollView.contentOffset.y >=
            scrollView.contentSize.height - 2 * scrollView.bounds.size.height) {

        /* Low-speed/geometry fallback. Fast motion should already have been
         * covered several screens earlier by the momentum runway above. */
        [self getMessages:DCProximityMessageLoadCount()
            beforeMessage:self.messages.firstObject];
    }

    if (!self.loadingNewerMessages && self.currentWindow.hasMoreAfter) {
        /*
         * The old 2-screen pixel threshold could remain true after a 12-row
         * forward page was inserted—especially after trimming the opposite
         * edge—causing a rapid fetch/insert/trim loop. Trigger by visible-row
         * progress instead.
         */
        NSArray *visibleRows = [self.chatTableView indexPathsForVisibleRows];
        NSInteger nearestNewerRow = NSIntegerMax;
        for (NSIndexPath *path in visibleRows) {
            nearestNewerRow = MIN(nearestNewerRow, path.row);
        }

        NSInteger triggerRow = DCNewerPaginationTriggerRow();
        BOOL nearNewerEdge =
            (nearestNewerRow != NSIntegerMax)
                ? (nearestNewerRow <= triggerRow)
                : (scrollView.contentOffset.y <= scrollView.bounds.size.height);

        if (nearNewerEdge) {
            NSLog(@"[ChatPerf] newer pagination trigger nearestRow %ld threshold %ld page %d",
                  (long)nearestNewerRow,
                  (long)triggerRow,
                  DCProximityMessageLoadCount());
            [self getNewerMessages:DCProximityMessageLoadCount()
                      afterMessage:self.messages.lastObject];
        }
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                 withVelocity:(CGPoint)velocity
          targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (scrollView != self.chatTableView) return;

    /*
     * Seed the estimate with UIKit's release velocity. Subsequent native
     * deceleration callbacks refine it until a newer-page append occurs.
     */
    self.sampledScrollVelocityY = velocity.y;
    self.lastVelocitySampleOffsetY = scrollView.contentOffset.y;
    self.lastVelocitySampleTime = CFAbsoluteTimeGetCurrent();

    [self maintainMessageRunwayForVelocity:velocity.y reason:@"release"];
    [self schedulePresentationRunwayForVelocity:velocity.y];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                       willDecelerate:(BOOL)decelerate {
    if (scrollView != self.chatTableView) return;
    if (!decelerate) {
        self.sampledScrollVelocityY = 0.0f;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateVisibleChatMediaResidency];
            [self performDeferredWindowTrimIfNeeded];
        });
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.chatTableView) return;
    if (!self.forwardMomentumDisplayLink) {
        self.sampledScrollVelocityY = 0.0f;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateVisibleChatMediaResidency];
        [self performDeferredWindowTrimIfNeeded];
    });
}

- (CGFloat)clampedOffsetY:(CGFloat)offsetY {
    if (!self.chatTableView) {
        return 0.0f;
    }

    CGFloat minimumOffsetY =
        -self.chatTableView.contentInset.top;

    CGFloat maximumOffsetY = MAX(
        minimumOffsetY,
        self.chatTableView.contentSize.height
            - self.chatTableView.bounds.size.height
            + self.chatTableView.contentInset.bottom
    );

    return MIN(
        MAX(offsetY, minimumOffsetY),
        maximumOffsetY
    );
}

- (void)saveScrollPositionForWindow:(DCChannelWindow *)window {
    if (!window || !self.chatTableView) {
        return;
    }

    if ([self.chatTableView numberOfRowsInSection:0] == 0) {
        window.hasSavedContentOffset = NO;
        window.savedContentOffsetY = 0.0f;
        return;
    }

    window.savedContentOffsetY =
        [self clampedOffsetY:
            self.chatTableView.contentOffset.y];

    window.hasSavedContentOffset = YES;
}

- (void)restoreScrollPositionForCurrentWindow {
    if (!self.currentWindow ||
        !self.chatTableView ||
        self.messages.count == 0) {
        return;
    }

    CGFloat targetOffsetY =
        -self.chatTableView.contentInset.top;

    if (self.currentWindow.hasSavedContentOffset) {
        targetOffsetY =
            [self clampedOffsetY:
                self.currentWindow.savedContentOffsetY];
    }

    [self.chatTableView
        setContentOffset:
            CGPointMake(
                self.chatTableView.contentOffset.x,
                targetOffsetY
            )
                animated:NO];
}

- (BOOL)chatIsActivelyScrolling {
    return self.chatTableView.dragging ||
           self.chatTableView.tracking ||
           self.chatTableView.decelerating ||
           self.forwardMomentumDisplayLink != nil;
}

- (void)trimNewestDownToCeilingNow {
    NSInteger evictCount = (NSInteger)self.messages.count - DCChatWindowCeiling();
    if (evictCount <= 0) return;
    NSInteger trimBatch = DCChatWindowTrimBatch();
    if ([self chatIsActivelyScrolling] && self.olderRunwayRequestedCount > trimBatch) {
        trimBatch = self.olderRunwayRequestedCount;
    }
    evictCount = MIN(evictCount, trimBatch);

    BOOL inSync = ([self.chatTableView numberOfRowsInSection:0] == (NSInteger)self.messages.count);
    CGFloat evictedHeight = 0.0f;
    NSMutableArray *evictPaths = nil;

    if (inSync) {
        evictPaths = [NSMutableArray arrayWithCapacity:evictCount];
        for (NSInteger row = 0; row < evictCount; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
            evictedHeight += [self.chatTableView rectForRowAtIndexPath:path].size.height;
            [evictPaths addObject:path];
        }
    }

    NSRange tailRange = NSMakeRange(self.messages.count - evictCount, evictCount);
    NSArray *evictedMessages = [self.messages subarrayWithRange:tailRange];
    NSMutableArray *evictedIDs = [NSMutableArray arrayWithCapacity:evictedMessages.count];
    for (DCMessage *m in evictedMessages) {
        if (m.snowflake.length) [evictedIDs addObject:m.snowflake];
        for (id att in m.attachments) {
            if ([att isKindOfClass:[UILazyImage class]]) {
                ((UILazyImage *)att).image = nil;
            }
        }
    }
    [self.messages removeObjectsInRange:tailRange];
    [[DCCacheManager sharedInstance] invalidateSnowflakes:evictedIDs];

    self.currentWindow.hasMoreAfter = YES;
    self.currentWindow.atPresentTime = NO;

    if (inSync) {
        [UIView setAnimationsEnabled:NO];
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        [self.chatTableView beginUpdates];
        [self.chatTableView deleteRowsAtIndexPaths:evictPaths
                                  withRowAnimation:UITableViewRowAnimationNone];
        [self.chatTableView endUpdates];
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - start;
        if (elapsed >= 0.008) {
            NSLog(@"[ChatPerf] table newest trim %lu rows %.1fms",
                  (unsigned long)evictPaths.count, elapsed * 1000.0);
        }
        [UIView setAnimationsEnabled:YES];

        CGPoint offset = self.chatTableView.contentOffset;
        offset.y = MAX(0.0f, offset.y - evictedHeight);
        self.chatTableView.contentOffset = offset;
    } else {
        [self.chatTableView reloadData];
    }
}

- (void)evictOldestDownToCeiling {
    NSInteger evictCount = (NSInteger)self.messages.count - DCChatWindowCeiling();
    if (evictCount <= 0) return;

    /*
     * While bridging a historical window back toward the live tail, deleting
     * the opposite edge can make iOS 6 clamp the flipped table's contentOffset
     * and throw the viewport straight back into the newer-fetch zone. Permit
     * a bounded overage until the live tail is reached or the hard ceiling
     * requires a slide.
     */
    BOOL activeScroll = [self chatIsActivelyScrolling];
    NSInteger permittedHardCeiling = activeScroll
        ? DCChatActiveWindowHardCeiling()
        : DCChatWindowHardCeiling();
    if ((self.currentWindow.hasMoreAfter || activeScroll) &&
        self.messages.count <= permittedHardCeiling) {
        self.deferredWindowTrimDirection = DCWindowTrimDirectionRemoveOldest;
        return;
    }

    self.deferredWindowTrimDirection = DCWindowTrimDirectionNone;
    [self trimOldestDownToCeilingNow];
}

- (void)trimOldestDownToCeilingNow {
    NSInteger evictCount = (NSInteger)self.messages.count - DCChatWindowCeiling();
    if (evictCount <= 0) return;
    NSInteger trimBatch = DCChatWindowTrimBatch();
    if ([self chatIsActivelyScrolling] && self.newerRunwayRequestedCount > trimBatch) {
        trimBatch = self.newerRunwayRequestedCount;
    }
    evictCount = MIN(evictCount, trimBatch);

    BOOL inSync = ([self.chatTableView numberOfRowsInSection:0] == (NSInteger)self.messages.count);

    /*
     * Preserve a visible message across the high-row deletion. On the flipped
     * iOS 6 table, deleting the physical content-bottom can otherwise clamp
     * contentOffset and visibly jump the window toward row zero.
     */
    NSString *trimAnchorSnowflake = nil;
    CGFloat trimAnchorViewportY = 0.0f;
    if (inSync) {
        NSArray *visiblePaths = [self.chatTableView indexPathsForVisibleRows];
        NSInteger firstEvictedRow = (NSInteger)self.messages.count - evictCount;
        NSIndexPath *trimAnchorPath = nil;
        for (NSIndexPath *path in visiblePaths) {
            if (path.row >= firstEvictedRow) continue;
            if (!trimAnchorPath || path.row < trimAnchorPath.row) {
                trimAnchorPath = path;
            }
        }
        if (trimAnchorPath) {
            NSInteger anchorModelIndex = [self modelIndexForRow:trimAnchorPath.row];
            if (anchorModelIndex >= 0 &&
                anchorModelIndex < (NSInteger)self.messages.count) {
                DCMessage *anchorMessage = self.messages[anchorModelIndex];
                trimAnchorSnowflake = [anchorMessage.snowflake copy];
                CGRect anchorRect = [self.chatTableView rectForRowAtIndexPath:trimAnchorPath];
                trimAnchorViewportY =
                    anchorRect.origin.y - self.chatTableView.contentOffset.y;
            }
        }
    }

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
    NSArray *evictedMessages = [self.messages subarrayWithRange:headRange];
    NSMutableArray *evictedIDs = [NSMutableArray arrayWithCapacity:evictedMessages.count];
    for (DCMessage *m in evictedMessages) {
        if (m.snowflake.length) [evictedIDs addObject:m.snowflake];
        for (id att in m.attachments) {
            if ([att isKindOfClass:[UILazyImage class]]) ((UILazyImage *)att).image = nil;
        }
    }
    [self.messages removeObjectsInRange:headRange];
    [[DCCacheManager sharedInstance] invalidateSnowflakes:evictedIDs];
    self.currentWindow.hasMoreBefore = YES;

    if (inSync) {
        [UIView setAnimationsEnabled:NO];
        CFAbsoluteTime tableMutationStart = CFAbsoluteTimeGetCurrent();
        [self.chatTableView beginUpdates];
        [self.chatTableView deleteRowsAtIndexPaths:evictPaths
                                  withRowAnimation:UITableViewRowAnimationNone];
        [self.chatTableView endUpdates];
        NSTimeInterval tableMutationTime = CFAbsoluteTimeGetCurrent() - tableMutationStart;
        if (tableMutationTime >= 0.008) {
            NSLog(@"[ChatPerf] table tail evict %lu rows %.1fms",
                  (unsigned long)evictPaths.count,
                  tableMutationTime * 1000.0);
        }
        [UIView setAnimationsEnabled:YES];

        [self.chatTableView layoutIfNeeded];
        if (trimAnchorSnowflake.length) {
            NSInteger anchorModelIndex =
                [self modelIndexForMessageSnowflake:trimAnchorSnowflake];
            if (anchorModelIndex != NSNotFound) {
                NSInteger anchorRow = [self rowForModelIndex:anchorModelIndex];
                if (anchorRow >= 0 &&
                    anchorRow < [self.chatTableView numberOfRowsInSection:0]) {
                    NSIndexPath *anchorPath =
                        [NSIndexPath indexPathForRow:anchorRow inSection:0];
                    CGRect anchorRect =
                        [self.chatTableView rectForRowAtIndexPath:anchorPath];
                    CGFloat targetOffsetY =
                        anchorRect.origin.y - trimAnchorViewportY;
                    targetOffsetY = [self clampedOffsetY:targetOffsetY];
                    [self.chatTableView
                        setContentOffset:CGPointMake(self.chatTableView.contentOffset.x,
                                                     targetOffsetY)
                               animated:NO];
                }
            }
        }
    } else {
        [self.chatTableView reloadData];
    }
}

- (void)performDeferredWindowTrimIfNeeded {
    if (self.deferredWindowTrimDirection == DCWindowTrimDirectionNone ||
        self.messages.count <= DCChatWindowCeiling() ||
        [self chatIsActivelyScrolling]) {
        return;
    }

    DCWindowTrimDirection direction =
        (DCWindowTrimDirection)self.deferredWindowTrimDirection;

    if (direction == DCWindowTrimDirectionRemoveOldest &&
        self.currentWindow.hasMoreAfter &&
        self.messages.count <= DCChatWindowHardCeiling()) {
        /* Keep the bounded forward-pagination overage until the live edge. */
        return;
    }

    self.deferredWindowTrimDirection = DCWindowTrimDirectionNone;

    if (direction == DCWindowTrimDirectionRemoveNewest) {
        [self trimNewestDownToCeilingNow];
    } else if (direction == DCWindowTrimDirectionRemoveOldest) {
        [self trimOldestDownToCeilingNow];
    }

    if (self.messages.count > DCChatWindowCeiling()) {
        // Do not turn a large accumulated overage into one 100-220ms table
        // transaction. Trim one normal message batch per idle run-loop pass.
        self.deferredWindowTrimDirection = direction;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self performDeferredWindowTrimIfNeeded];
        });
    } else {
        [[DCMessageStore sharedInstance] scheduleCheckpointForWindow:self.currentWindow];
    }
}

- (NSArray *)deduplicateAgainstWindow:(NSArray *)incoming {
    if (incoming.count == 0) {
        return incoming;
    }

    NSMutableSet *have =
        [NSMutableSet setWithCapacity:
            self.messages.count + incoming.count];

    for (DCMessage *message in self.messages) {
        if (message.snowflake.length) {
            [have addObject:message.snowflake];
        }
    }

    NSMutableArray *out =
        [NSMutableArray arrayWithCapacity:incoming.count];

    for (DCMessage *message in incoming) {
        NSString *snowflake = message.snowflake;

        if (!snowflake.length) {
            NSLog(@"%s: Dropping incoming message without an ID",
                  __PRETTY_FUNCTION__);
            continue;
        }

        if ([have containsObject:snowflake]) {
            continue;
        }

        /*
         * Add immediately so another copy later in the same incoming batch
         * is also rejected.
         */
        [have addObject:snowflake];
        [out addObject:message];
    }

    if (out.count != incoming.count) {
        NSLog(@"%s: Dropped %lu duplicate or invalid message(s) of %lu incoming",
              __PRETTY_FUNCTION__,
              (unsigned long)(incoming.count - out.count),
              (unsigned long)incoming.count);
    }

    return out;
}

- (BOOL)removeDuplicateMessagesFromWindow:
    (DCChannelWindow *)window {

    if (!window || window.messages.count < 2) {
        return NO;
    }

    NSMutableSet *seen = [NSMutableSet set];
    NSMutableIndexSet *indexesToRemove =
        [NSMutableIndexSet indexSet];

    /*
     * Walk newest -> oldest and keep the newest object for each snowflake.
     * A later gateway copy may contain fresher user/member information than
     * the earlier REST-created object.
     */
    for (NSInteger index =
             (NSInteger)window.messages.count - 1;
         index >= 0;
         index--) {

        DCMessage *message = window.messages[index];
        NSString *snowflake = message.snowflake;

        if (!snowflake.length) {
            continue;
        }

        if ([seen containsObject:snowflake]) {
            [indexesToRemove addIndex:(NSUInteger)index];
        } else {
            [seen addObject:snowflake];
        }
    }

    if (indexesToRemove.count == 0) {
        return NO;
    }

    NSLog(@"%s: Removing %lu existing duplicate message(s)",
          __PRETTY_FUNCTION__,
          (unsigned long)indexesToRemove.count);

    [window.messages
        removeObjectsAtIndexes:indexesToRemove];

    [[DCCacheManager sharedInstance]
        invalidateAllMessages];

    return YES;
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
    if (scrollView == self.chatTableView) {
        [self stopForwardMomentumContinuation];
        self.sampledScrollVelocityY = 0.0f;
        self.lastVelocitySampleTime = 0.0;
    }

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

    if (messageAtRowIndex.referencedMessageState !=
            DCMessageReferenceStateResolved ||
        !messageAtRowIndex.referencedMessage.snowflake.length) {
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
            return;
        }


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
    self.navigationItem.title = channel.name;
    [self activateSelectedChannel];
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
    [self stopForwardMomentumContinuation];
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

    [self stopForwardMomentumContinuation];
    [self saveScrollPositionForWindow:self.currentWindow];

    BOOL leavingPermanently =
        [self isMovingFromParentViewController] ||
        [self isBeingDismissed] ||
        [self.navigationController isBeingDismissed];

    if (!leavingPermanently) {
        return;
    }

    [self invalidateAllTypingTimers];

    // Popping/dismissing the chat means the user's last active screen is now
    // the main menu. Do not clear this for temporary modal/profile transitions.
    [[DCCacheManager sharedInstance] clearLastActiveChatChannel];
    DCServerCommunicator.sharedInstance.selectedChannel = nil;

    [NSNotificationCenter.defaultCenter
        postNotificationName:@"ChannelSelectionCleared"
                      object:nil];
}

- (void)dealloc {
    [self stopForwardMomentumContinuation];

    [NSNotificationCenter.defaultCenter
        removeObserver:self];

    for (NSTimer *timer in _typingUsers.allValues) {
        [timer invalidate];
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];

    if (self.chatTableView && self.messages.count) {
        /* Preserve complete live message models across memory warnings. Layout
         * entries outside the active window and decoded image caches may still be purged. */
        NSMutableSet *preservedIDs = [NSMutableSet setWithCapacity:self.messages.count];
        for (DCMessage *message in self.messages) {
            if (message.snowflake.length) {
                [preservedIDs addObject:message.snowflake];
            }
        }

        [[DCCacheManager sharedInstance]
            handleMemoryWarningPreservingSnowflakes:preservedIDs];

        NSLog(@"[DCChatViewController] Memory warning: preserved %lu complete live chat models (window policy %ld/%ld)",
              (unsigned long)self.messages.count,
              (long)DCChatWindowCeiling(),
              (long)DCChatWindowHardCeiling());
        return;
    }

    [[DCCacheManager sharedInstance] handleMemoryWarning];
}

- (IBAction)dismissModalPVTONLY:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
