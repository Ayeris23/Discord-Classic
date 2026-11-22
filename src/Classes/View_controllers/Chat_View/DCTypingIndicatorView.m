//
//  DCTypingIndicatorView.m
//  Discord Classic
//

#import "DCTypingIndicatorView.h"
#import "DCInterfaceStyle.h"
#import "DCServerCommunicator.h"
#import "DCChannel.h"
#import "DCGuild.h"
#import "DCUser.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat DCTypingBannerHeight = 20.0f;
static const CGFloat DCTypingBannerShadowHeight = 3.0f;
static const NSTimeInterval DCTypingTimeout = 10.0;

@interface DCTypingIndicatorView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *edgeShadowView;
@property (nonatomic, strong) CAGradientLayer *edgeShadowGradient;
@property (nonatomic, strong) NSMutableDictionary *typingTimers;
@property (nonatomic, copy) NSString *channelID;
@property (nonatomic, assign, readwrite, getter=isPresented) BOOL presented;
@property (nonatomic, assign) CGFloat composerTop;
- (void)typingTimerFired:(NSTimer *)timer;
- (void)updateTypingUsers;
@end

@implementation DCTypingIndicatorView

+ (CGFloat)bannerHeight {
    return DCTypingBannerHeight;
}

- (id)initWithFrame:(CGRect)frame tableView:(UITableView *)tableView {
    frame.size.height = DCTypingBannerHeight;
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.chatTableView = tableView;
    self.typingTimers = [NSMutableDictionary dictionary];
    self.composerTop = CGRectGetMinY(frame);
    self.hidden = YES;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.backgroundColor = [UIColor colorWithPatternImage:
                            [DCInterfaceStyle notificationBackgroundImage]];
    self.clipsToBounds = NO;

    UIView *edgeShadow = [[UIView alloc] initWithFrame:CGRectMake(
        0.0f, -DCTypingBannerShadowHeight, frame.size.width,
        DCTypingBannerShadowHeight)];
    edgeShadow.backgroundColor = [UIColor clearColor];
    edgeShadow.userInteractionEnabled = NO;
    edgeShadow.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor,
                        (id)[UIColor colorWithWhite:0.0f alpha:0.15f].CGColor];
    gradient.startPoint = CGPointMake(0.5f, 0.0f);
    gradient.endPoint = CGPointMake(0.5f, 1.0f);
    gradient.frame = edgeShadow.bounds;
    [edgeShadow.layer addSublayer:gradient];
    [self addSubview:edgeShadow];
    self.edgeShadowView = edgeShadow;
    self.edgeShadowGradient = gradient;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(
        12.0f, 0.0f, frame.size.width - 24.0f, DCTypingBannerHeight)];
    label.font = [UIFont boldSystemFontOfSize:12.0f];
    label.textColor = [UIColor colorWithRed:168.0f / 255.0f
                                      green:168.0f / 255.0f
                                       blue:168.0f / 255.0f alpha:1.0f];
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0.0f, 1.0f);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.backgroundColor = [UIColor clearColor];
    [self addSubview:label];
    self.titleLabel = label;

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect shadowFrame = CGRectMake(0.0f, -DCTypingBannerShadowHeight,
                                    self.bounds.size.width, DCTypingBannerShadowHeight);
    if (!CGRectEqualToRect(self.edgeShadowView.frame, shadowFrame)) {
        self.edgeShadowView.frame = shadowFrame;
    }
    if (!CGRectEqualToRect(self.edgeShadowGradient.frame, self.edgeShadowView.bounds)) {
        self.edgeShadowGradient.frame = self.edgeShadowView.bounds;
    }
}

- (void)userStartedTypingWithID:(NSString *)userID inChannel:(DCChannel *)channel {
    NSAssert([NSThread isMainThread], @"Typing indicator must run on main thread");
    if (!userID.length || !channel.snowflake.length) return;

    if (self.channelID && ![self.channelID isEqualToString:channel.snowflake]) {
        [self resetForChannelChange];
    }
    self.channelID = channel.snowflake;

    NSTimer *oldTimer = [self.typingTimers objectForKey:userID];
    NSTimer *newTimer = [NSTimer scheduledTimerWithTimeInterval:DCTypingTimeout
                                                        target:self
                                                      selector:@selector(typingTimerFired:)
                                                      userInfo:userID
                                                       repeats:NO];
    [self.typingTimers setObject:newTimer forKey:userID];
    [oldTimer invalidate];
    [self updateTypingUsers];
}

- (void)userStoppedTypingWithID:(NSString *)userID {
    NSAssert([NSThread isMainThread], @"Typing indicator must run on main thread");
    NSTimer *timer = [self.typingTimers objectForKey:userID];
    if (!timer) return;
    [self.typingTimers removeObjectForKey:userID];
    [self updateTypingUsers];
    [timer invalidate];
}

- (void)typingTimerFired:(NSTimer *)timer {
    NSString *userID = timer.userInfo;
    if (![userID isKindOfClass:[NSString class]]) return;
    if ([self.typingTimers objectForKey:userID] != timer) return;
    [self.typingTimers removeObjectForKey:userID];
    [self updateTypingUsers];
}

- (void)invalidateTypingTimers {
    NSArray *timers = [self.typingTimers.allValues copy];
    [self.typingTimers removeAllObjects];
    for (NSTimer *timer in timers) [timer invalidate];
}

- (void)resetForChannelChange {
    NSAssert([NSThread isMainThread], @"Typing indicator must run on main thread");
    [self invalidateTypingTimers];
    self.channelID = nil;
    self.presented = NO;
    [self.layer removeAllAnimations];
    self.hidden = YES;
    [self positionAboveComposerAtY:self.composerTop];

    UITableView *table = self.chatTableView;
    if (table.contentInset.top > 0.0f) {
        UIEdgeInsets insets = table.contentInset;
        BOOL atLiveEdge = fabs(table.contentOffset.y + insets.top) <= 10.0f;
        insets.top = 0.0f;
        table.contentInset = insets;
        if (atLiveEdge) {
            [table setContentOffset:CGPointMake(table.contentOffset.x, 0.0f)
                           animated:NO];
        }
    }
}

- (void)positionAboveComposerAtY:(CGFloat)composerTop {
    self.composerTop = composerTop;
    CGRect frame = self.frame;
    frame.origin.y = composerTop - (self.presented ? DCTypingBannerHeight : 0.0f);
    if (fabs(frame.origin.y - self.frame.origin.y) > 0.5f) self.frame = frame;
}

- (void)updateTypingUsers {
    BOOL shouldShow = self.typingTimers.count > 0;
    if (shouldShow) {
        NSMutableArray *names = [NSMutableArray array];
        DCChannel *channel = DCServerCommunicator.sharedInstance.selectedChannel;
        if (![channel.snowflake isEqualToString:self.channelID]) {
            [self resetForChannelChange];
            return;
        }
        DCGuild *guild = channel.parentGuild;
        NSArray *userIDs = [[self.typingTimers allKeys]
                            sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *userID in userIDs) {
            DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:userID];
            if (!user) {
                for (DCUser *recipient in channel.recipients) {
                    if ([recipient.snowflake isEqualToString:userID]) {
                        user = recipient;
                        break;
                    }
                }
            }
            if (user) {
                NSString *name = nil;
                @synchronized (user) {
                    name = [user displayNameInGuild:guild];
                }
                if (name.length) [names addObject:name];
            }
        }

        NSString *title = nil;
        if (names.count == 1) {
            title = [NSString stringWithFormat:@"%@ is typing...", names[0]];
        } else if (names.count == 2) {
            title = [NSString stringWithFormat:@"%@ and %@ are typing...",
                     names[0], names[1]];
        } else if (names.count == 3) {
            title = [NSString stringWithFormat:@"%@, %@, and %@ are typing...",
                     names[0], names[1], names[2]];
        } else {
            title = @"Several users are typing...";
        }
        if (![self.titleLabel.text isEqualToString:title]) {
            self.titleLabel.text = title;
        }
    }

    if (shouldShow == self.presented) return;
    UITableView *table = self.chatTableView;
    if (!table) return;

    UIEdgeInsets oldInsets = table.contentInset;
    BOOL followLiveTail = [self.delegate typingIndicatorShouldFollowLiveTail:self];
    self.presented = shouldShow;
    [self.layer removeAllAnimations];
    if (shouldShow) {
        if (self.hidden) {
            CGRect startFrame = self.frame;
            startFrame.origin.y = self.composerTop;
            self.frame = startFrame;
        }
        self.hidden = NO;
    }

    UIEdgeInsets newInsets = oldInsets;
    newInsets.top = shouldShow ? DCTypingBannerHeight : 0.0f;
    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         table.contentInset = newInsets;
                         if (followLiveTail) {
                             [table setContentOffset:CGPointMake(table.contentOffset.x,
                                                                -newInsets.top)
                                          animated:NO];
                         }
                         [self positionAboveComposerAtY:self.composerTop];
                     }
                     completion:^(BOOL finished) {
                         if (!self.presented) self.hidden = YES;
                     }];
}

- (void)dealloc {
    [self invalidateTypingTimers];
}

@end
