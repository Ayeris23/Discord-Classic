//
//  DCChatGifAttachment.m
//  Discord Classic
//
//  Created by Ayeris on 3/12/26.
//  Copyright (c) 2026 bag.xml. All rights reserved.
//

#import "DCChatGifAttachment.h"
#import "DCResourceManager.h"
#import "DCChatMediaManager.h"
#import <ImageIO/ImageIO.h>
#import <MediaPlayer/MediaPlayer.h>
#import <SDWebImage/SDWebImageDownloader.h>
#include <math.h>

static __weak DCChatGifAttachment *DCActiveGifAttachment = nil;

static BOOL DCGifMediaErrorMayBeExpiredSignature(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    return error.code == 401 || error.code == 403 || error.code == 404;
}

static dispatch_queue_t DCGifDecodeQueue(void) {
    static dispatch_queue_t queue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("dis.cord.Discord.gif-decode", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSTimeInterval DCGifFrameDuration(CGImageSourceRef source, size_t index) {
    NSTimeInterval duration = 0.1;
    CFDictionaryRef propertiesRef = CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
    if (!propertiesRef) return duration;

    NSDictionary *properties = (__bridge NSDictionary *)propertiesRef;
    NSDictionary *gifProperties = [properties objectForKey:(NSString *)kCGImagePropertyGIFDictionary];
    NSNumber *delay = [gifProperties objectForKey:(NSString *)kCGImagePropertyGIFUnclampedDelayTime];
    if (!delay || [delay doubleValue] <= 0.0) {
        delay = [gifProperties objectForKey:(NSString *)kCGImagePropertyGIFDelayTime];
    }
    if (delay && [delay doubleValue] > 0.0) {
        duration = [delay doubleValue];
    }
    if (duration < 0.011) {
        duration = 0.1;
    }

    CFRelease(propertiesRef);
    return duration;
}

static UIImage *DCGifCreateBudgetedAnimation(NSData *data,
                                               CGSize displaySize,
                                               CGFloat screenScale,
                                               NSUInteger memoryBudget,
                                               NSUInteger frameLimit,
                                               BOOL (^shouldCancel)(void),
                                               NSUInteger *sourceFrameCountOut,
                                               NSUInteger *decodedFrameCountOut,
                                               NSUInteger *decodedCostOut) {
    if (!data.length) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    size_t sourceCount = CGImageSourceGetCount(source);
    if (sourceFrameCountOut) *sourceFrameCountOut = sourceCount;
    if (sourceCount == 0) {
        CFRelease(source);
        return nil;
    }

    NSUInteger safeFrameLimit = MAX((NSUInteger)1, frameLimit);
    NSUInteger frameStep = MAX((NSUInteger)1,
                               (NSUInteger)ceil((double)sourceCount / (double)safeFrameLimit));
    NSUInteger outputFrameCount = (sourceCount + frameStep - 1) / frameStep;

    CGFloat desiredPixelWidth = MAX(1.0f, displaySize.width * screenScale);
    CGFloat desiredPixelHeight = MAX(1.0f, displaySize.height * screenScale);
    CGFloat desiredArea = desiredPixelWidth * desiredPixelHeight;
    CGFloat allowedArea = desiredArea;
    if (memoryBudget > 0 && outputFrameCount > 0) {
        allowedArea = (CGFloat)memoryBudget / (4.0f * (CGFloat)outputFrameCount);
    }

    CGFloat scaleFactor = 1.0f;
    if (allowedArea > 0.0f && desiredArea > allowedArea) {
        scaleFactor = sqrtf(allowedArea / desiredArea);
    }

    CGFloat maxPixelDimension = MAX(desiredPixelWidth, desiredPixelHeight) * scaleFactor;
    maxPixelDimension = MAX(32.0f, floorf(maxPixelDimension));

    NSDictionary *thumbnailOptions = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize : @((NSUInteger)maxPixelDimension)
    };

    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:outputFrameCount];
    NSTimeInterval totalDuration = 0.0;
    NSUInteger decodedCost = 0;

    for (size_t index = 0; index < sourceCount; index++) {
        if (shouldCancel && shouldCancel()) {
            CFRelease(source);
            return nil;
        }

        totalDuration += DCGifFrameDuration(source, index);
        if ((index % frameStep) != 0) continue;

        CGImageRef frameRef = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            (__bridge CFDictionaryRef)thumbnailOptions);
        if (!frameRef) continue;

        size_t bytesPerRow = CGImageGetBytesPerRow(frameRef);
        size_t height = CGImageGetHeight(frameRef);
        if (bytesPerRow > 0 && height > 0) {
            NSUInteger frameCost = (NSUInteger)(bytesPerRow * height);
            if (NSUIntegerMax - decodedCost < frameCost) {
                decodedCost = NSUIntegerMax;
            } else {
                decodedCost += frameCost;
            }
        }

        UIImage *frame = [UIImage imageWithCGImage:frameRef
                                             scale:screenScale
                                       orientation:UIImageOrientationUp];
        CGImageRelease(frameRef);
        if (frame) {
            [frames addObject:frame];
        }
    }

    CFRelease(source);

    if (decodedFrameCountOut) *decodedFrameCountOut = frames.count;
    if (decodedCostOut) *decodedCostOut = decodedCost;
    if (frames.count == 0) return nil;
    if (frames.count == 1) return [frames objectAtIndex:0];
    if (totalDuration <= 0.0) totalDuration = 0.1 * frames.count;

    return [UIImage animatedImageWithImages:frames duration:totalDuration];
}

@interface DCChatGifAttachment ()
@property (strong, nonatomic) UILabel *gifBadge;
@property (strong, nonatomic) UIView *playbackOverlay;
@property (strong, nonatomic) UIActivityIndicatorView *playbackSpinner;
@property (strong, nonatomic) UIImage *staticThumbnail;
@property (strong, nonatomic) id<SDWebImageOperation> gifLoadOperation;
@property (strong, nonatomic) MPMoviePlayerController *moviePlayer;
@property (assign, nonatomic) BOOL gifLoading;
@property (assign, nonatomic) BOOL gifPlaying;
@property (assign) NSUInteger playbackGeneration;
@property (assign, nonatomic) BOOL movieSignatureRetryUsed;
- (void)dc_startImagePlayback;
- (void)dc_loadImagePlaybackForURL:(NSURL *)configuredURL
                         generation:(NSUInteger)generation
                allowSignatureRetry:(BOOL)allowSignatureRetry;
- (void)dc_beginResolvedVideoPlaybackForURL:(NSURL *)playbackURL
                                  generation:(NSUInteger)generation;
- (void)dc_startVideoPlayback;
- (void)dc_claimPlaybackSlot;
- (void)dc_updateGifChrome;
- (void)dc_memoryWarning:(NSNotification *)notification;
- (void)dc_movieLoadStateDidChange:(NSNotification *)notification;
- (void)dc_moviePlaybackStateDidChange:(NSNotification *)notification;
- (void)dc_moviePlaybackDidFinish:(NSNotification *)notification;
@end

@implementation DCChatGifAttachment

- (void)dc_commonGifInit {
    if (self.gifBadge) return;

    self.backgroundColor = [UIColor blackColor];
    self.contentMode = UIViewContentModeScaleAspectFit;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = YES;

    UIView *overlay = [[UIView alloc] initWithFrame:self.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.4f];
    overlay.userInteractionEnabled = NO;
    overlay.hidden = YES;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                               UIViewAutoresizingFlexibleHeight;
    [self addSubview:overlay];
    self.playbackOverlay = overlay;

    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spinner.hidesWhenStopped = YES;
    spinner.userInteractionEnabled = NO;
    [self addSubview:spinner];
    self.playbackSpinner = spinner;

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
    badge.backgroundColor = [UIColor colorWithWhite:0.45f alpha:1.0f];
    badge.textColor = [UIColor whiteColor];
    badge.font = [UIFont boldSystemFontOfSize:14.0f];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.text = @"GIF";
    badge.userInteractionEnabled = NO;
    [self addSubview:badge];
    self.gifBadge = badge;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(dc_memoryWarning:)
               name:UIApplicationDidReceiveMemoryWarningNotification
             object:nil];
}

- (id)init {
    self = [super init];
    if (self) {
        [self dc_commonGifInit];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self dc_commonGifInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self dc_commonGifInit];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.playbackOverlay.frame = self.bounds;
    self.playbackSpinner.center =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));

    CGFloat badgeWidth = 38.0f;
    CGFloat badgeHeight = 20.0f;
    CGFloat inset = 8.0f;
    self.gifBadge.frame = CGRectMake(MAX(0.0f, self.bounds.size.width - badgeWidth - inset),
                                     inset,
                                     badgeWidth,
                                     badgeHeight);
    self.moviePlayer.view.frame = self.bounds;

    [self bringSubviewToFront:self.playbackOverlay];
    [self bringSubviewToFront:self.playbackSpinner];
    [self bringSubviewToFront:self.gifBadge];
}

- (void)setImage:(UIImage *)image {
    [super setImage:image];
    if (!self.gifPlaying && image.images.count <= 1) {
        self.staticThumbnail = image;
    }
    [self dc_updateGifChrome];
}

- (void)setGifURL:(NSURL *)gifURL {
    if ((_gifURL == gifURL) || [_gifURL isEqual:gifURL]) return;

    [self stopPlayback];
    _gifURL = gifURL;
}

- (void)setVideoBacked:(BOOL)videoBacked {
    if (_videoBacked == videoBacked) return;

    [self stopPlayback];
    _videoBacked = videoBacked;
}

- (void)setImageURL:(NSURL *)imageURL {
    if ((self.imageURL == imageURL) || [self.imageURL isEqual:imageURL]) return;

    [self stopPlayback];
    self.staticThumbnail = nil;
    [super setImageURL:imageURL];
    [self dc_updateGifChrome];
}

- (void)dc_claimPlaybackSlot {
    DCChatGifAttachment *active = DCActiveGifAttachment;
    if (active && active != self) {
        [active stopPlayback];
    }
    DCActiveGifAttachment = self;
}

- (void)dc_updateGifChrome {
    if (self.gifLoading) {
        self.playbackOverlay.hidden = NO;
        self.playbackSpinner.hidden = NO;
        [self.playbackSpinner startAnimating];
        self.gifBadge.hidden = YES;
        return;
    }

    self.playbackOverlay.hidden = YES;
    [self.playbackSpinner stopAnimating];
    self.gifBadge.hidden = self.gifPlaying;
}

- (void)prepareForDisplay {
    [self prepareForDisplayAllowLoading:YES];
}

- (void)prepareForDisplayAllowLoading:(BOOL)allowLoading {
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self prepareChatThumbnailForDisplaySize:self.bounds.size
                                allowLoading:allowLoading];
    [self dc_updateGifChrome];
}

- (void)handleTap {
    if (self.gifLoading || !self.gifURL) return;

    if (self.gifPlaying) {
        [self stopPlayback];
        return;
    }

    if (self.videoBacked) {
        [self dc_startVideoPlayback];
        return;
    }

    [self dc_startImagePlayback];
}

- (void)dc_startImagePlayback {
    [self dc_claimPlaybackSlot];

    NSUInteger generation = self.playbackGeneration + 1;
    self.playbackGeneration = generation;
    self.gifLoading = YES;
    [self dc_updateGifChrome];

    [self dc_loadImagePlaybackForURL:self.gifURL
                          generation:generation
                 allowSignatureRetry:YES];
}

- (void)dc_loadImagePlaybackForURL:(NSURL *)configuredURL
                         generation:(NSUInteger)generation
                allowSignatureRetry:(BOOL)allowSignatureRetry {
    if (!configuredURL) return;

    __weak DCChatGifAttachment *weakSelf = self;
    [[DCChatMediaManager sharedManager]
        resolveMediaURL:configuredURL
             completion:^(NSURL *representedURL, NSError *resolutionError) {
        DCChatGifAttachment *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.playbackGeneration != generation ||
            ![strongSelf.gifURL isEqual:configuredURL]) return;

        if (resolutionError &&
            [[DCChatMediaManager sharedManager] mediaURLNeedsRefresh:representedURL]) {
            strongSelf.gifLoading = NO;
            if (DCActiveGifAttachment == strongSelf) DCActiveGifAttachment = nil;
            NSLog(@"[GIF] signature resolution failed %@: %@", configuredURL, resolutionError);
            [strongSelf dc_updateGifChrome];
            return;
        }

        CGSize displaySize = strongSelf.bounds.size;
        CGFloat screenScale = [UIScreen mainScreen].scale;
        DCResourceManager *resources = [DCResourceManager sharedManager];
        NSUInteger memoryBudget = resources.chatAnimatedGIFMemoryBudget;
        NSUInteger frameLimit = resources.chatAnimatedGIFFrameLimit;
        uint64_t residentBytes = [resources currentResidentMemoryBytes];
        NSLog(@"[GIFBudget] start budget %.1f MB/%lu frames resident %.1f MB %@",
              (double)memoryBudget / (1024.0 * 1024.0),
              (unsigned long)frameLimit,
              (double)residentBytes / (1024.0 * 1024.0),
              representedURL);

        strongSelf.gifLoadOperation = [[SDWebImageDownloader sharedDownloader]
            downloadImageWithURL:representedURL
                         options:(SDWebImageDownloaderAvoidDecode |
                                  SDWebImageDownloaderUseNSURLCache)
                        progress:nil
                       completed:^(UIImage *image,
                                   NSData *data,
                                   NSError *error,
                                   BOOL finished) {
            if (!finished) return;

            DCChatGifAttachment *liveSelf = weakSelf;
            if (!liveSelf || liveSelf.playbackGeneration != generation ||
                ![liveSelf.gifURL isEqual:configuredURL]) return;

            if ((error || !data.length) && allowSignatureRetry &&
                DCGifMediaErrorMayBeExpiredSignature(error)) {
                liveSelf.gifLoadOperation = nil;
                [[DCChatMediaManager sharedManager]
                    refreshMediaURL:configuredURL
                         completion:^(NSURL *retryURL, NSError *refreshError) {
                    DCChatGifAttachment *retrySelf = weakSelf;
                    if (!retrySelf || retrySelf.playbackGeneration != generation ||
                        ![retrySelf.gifURL isEqual:configuredURL]) return;
                    if (refreshError &&
                        [[DCChatMediaManager sharedManager] mediaURLNeedsRefresh:retryURL]) {
                        retrySelf.gifLoading = NO;
                        if (DCActiveGifAttachment == retrySelf) DCActiveGifAttachment = nil;
                        NSLog(@"[GIF] signature refresh failed %@: %@",
                              configuredURL, refreshError);
                        [retrySelf dc_updateGifChrome];
                        return;
                    }
                    [retrySelf dc_loadImagePlaybackForURL:configuredURL
                                               generation:generation
                                      allowSignatureRetry:NO];
                }];
                return;
            }

            if (error || !data.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    DCChatGifAttachment *failureSelf = weakSelf;
                    if (!failureSelf || failureSelf.playbackGeneration != generation ||
                        ![failureSelf.gifURL isEqual:configuredURL]) return;
                    failureSelf.gifLoadOperation = nil;
                    failureSelf.gifLoading = NO;
                    if (error) NSLog(@"[GIF] playback failed %@: %@", representedURL, error);
                    if (DCActiveGifAttachment == failureSelf) DCActiveGifAttachment = nil;
                    [failureSelf dc_updateGifChrome];
                });
                return;
            }

            dispatch_async(DCGifDecodeQueue(), ^{
                @autoreleasepool {
                    __block NSUInteger sourceFrameCount = 0;
                    __block NSUInteger decodedFrameCount = 0;
                    __block NSUInteger decodedCost = 0;

                    UIImage *animation = DCGifCreateBudgetedAnimation(
                        data,
                        displaySize,
                        screenScale,
                        memoryBudget,
                        frameLimit,
                        ^BOOL{
                            DCChatGifAttachment *decodeSelf = weakSelf;
                            return !decodeSelf ||
                                   decodeSelf.playbackGeneration != generation ||
                                   ![decodeSelf.gifURL isEqual:configuredURL];
                        },
                        &sourceFrameCount,
                        &decodedFrameCount,
                        &decodedCost);

                    dispatch_async(dispatch_get_main_queue(), ^{
                        DCChatGifAttachment *displaySelf = weakSelf;
                        if (!displaySelf || displaySelf.playbackGeneration != generation ||
                            ![displaySelf.gifURL isEqual:configuredURL]) return;

                        displaySelf.gifLoadOperation = nil;
                        displaySelf.gifLoading = NO;

                        if (animation && displaySelf.window) {
                            if (animation.images.count > 1) {
                                displaySelf.gifPlaying = YES;
                                [displaySelf setImage:animation];
                                NSLog(@"[GIFBudget] decoded %lu/%lu frames %.1f MB %@",
                                      (unsigned long)decodedFrameCount,
                                      (unsigned long)sourceFrameCount,
                                      (double)decodedCost / (1024.0 * 1024.0),
                                      representedURL);
                            } else {
                                NSLog(@"[GIF] playback URL returned a non-animated image: %@",
                                      representedURL);
                                if (!displaySelf.staticThumbnail) [displaySelf setImage:animation];
                                if (DCActiveGifAttachment == displaySelf) DCActiveGifAttachment = nil;
                            }
                        } else if (DCActiveGifAttachment == displaySelf) {
                            DCActiveGifAttachment = nil;
                        }
                        [displaySelf dc_updateGifChrome];
                    });
                }
            });
        }];
    }];
}

- (void)dc_startVideoPlayback {
    [self dc_claimPlaybackSlot];

    NSUInteger generation = self.playbackGeneration + 1;
    self.playbackGeneration = generation;
    self.movieSignatureRetryUsed = NO;
    self.gifLoading = YES;
    [self dc_updateGifChrome];

    NSURL *configuredURL = self.gifURL;
    __weak DCChatGifAttachment *weakSelf = self;
    [[DCChatMediaManager sharedManager]
        resolveMediaURL:configuredURL
             completion:^(NSURL *playbackURL, NSError *resolutionError) {
        DCChatGifAttachment *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.playbackGeneration != generation ||
            ![strongSelf.gifURL isEqual:configuredURL]) return;
        if (resolutionError &&
            [[DCChatMediaManager sharedManager] mediaURLNeedsRefresh:playbackURL]) {
            strongSelf.gifLoading = NO;
            if (DCActiveGifAttachment == strongSelf) DCActiveGifAttachment = nil;
            NSLog(@"[GIF] video signature resolution failed %@: %@",
                  configuredURL, resolutionError);
            [strongSelf dc_updateGifChrome];
            return;
        }
        [strongSelf dc_beginResolvedVideoPlaybackForURL:playbackURL
                                              generation:generation];
    }];
}

- (void)dc_beginResolvedVideoPlaybackForURL:(NSURL *)playbackURL
                                  generation:(NSUInteger)generation {
    if (!playbackURL || self.playbackGeneration != generation) return;

    MPMoviePlayerController *player = [[MPMoviePlayerController alloc]
        initWithContentURL:playbackURL];
    player.useApplicationAudioSession = YES;
    player.controlStyle = MPMovieControlStyleNone;
    player.scalingMode = MPMovieScalingModeAspectFit;
    player.repeatMode = MPMovieRepeatModeOne;
    player.shouldAutoplay = YES;
    player.view.frame = self.bounds;
    player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
    player.view.userInteractionEnabled = NO;
    self.moviePlayer = player;
    [self insertSubview:player.view atIndex:0];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(dc_movieLoadStateDidChange:)
                   name:MPMoviePlayerLoadStateDidChangeNotification
                 object:player];
    [center addObserver:self
               selector:@selector(dc_moviePlaybackStateDidChange:)
                   name:MPMoviePlayerPlaybackStateDidChangeNotification
                 object:player];
    [center addObserver:self
               selector:@selector(dc_moviePlaybackDidFinish:)
                   name:MPMoviePlayerPlaybackDidFinishNotification
                 object:player];

    [player prepareToPlay];
    [player play];
    [self setNeedsLayout];
}

- (void)dc_memoryWarning:(NSNotification *)notification {
    if (self.gifLoading || self.gifPlaying) {
        [self stopPlayback];
    }
}

- (void)dc_movieLoadStateDidChange:(NSNotification *)notification {
    MPMoviePlayerController *player = notification.object;
    if (player != self.moviePlayer) return;

    if (player.loadState & MPMovieLoadStatePlayable) {
        self.gifLoading = NO;
        self.gifPlaying = YES;
        [player play];
        [self dc_updateGifChrome];
    }
}

- (void)dc_moviePlaybackStateDidChange:(NSNotification *)notification {
    MPMoviePlayerController *player = notification.object;
    if (player != self.moviePlayer) return;

    if (player.playbackState == MPMoviePlaybackStatePlaying) {
        self.gifLoading = NO;
        self.gifPlaying = YES;
        [self dc_updateGifChrome];
    }
}

- (void)dc_moviePlaybackDidFinish:(NSNotification *)notification {
    MPMoviePlayerController *player = notification.object;
    if (player != self.moviePlayer) return;

    NSNumber *reason = [notification.userInfo objectForKey:
        MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
    if ([reason integerValue] != MPMovieFinishReasonPlaybackError) return;

    NSError *error = [notification.userInfo objectForKey:@"error"];
    if (!self.movieSignatureRetryUsed) {
        self.movieSignatureRetryUsed = YES;
        NSUInteger generation = self.playbackGeneration;
        NSURL *configuredURL = self.gifURL;
        __weak DCChatGifAttachment *weakSelf = self;
        [[DCChatMediaManager sharedManager]
            refreshMediaURL:configuredURL
                 completion:^(NSURL *retryURL, NSError *refreshError) {
            DCChatGifAttachment *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.playbackGeneration != generation ||
                strongSelf.moviePlayer != player) return;
            if (!refreshError && retryURL) {
                strongSelf.gifLoading = YES;
                strongSelf.gifPlaying = NO;
                [strongSelf dc_updateGifChrome];
                player.contentURL = retryURL;
                [player prepareToPlay];
                [player play];
                return;
            }
            NSLog(@"[GIF] video signature refresh failed %@: %@",
                  configuredURL, refreshError ?: error);
            [strongSelf stopPlayback];
        }];
        return;
    }

    NSLog(@"[GIF] video playback failed %@: %@", player.contentURL, error);
    [self stopPlayback];
}

- (void)stopPlayback {
    self.playbackGeneration++;
    self.movieSignatureRetryUsed = NO;

    [self.gifLoadOperation cancel];
    self.gifLoadOperation = nil;

    MPMoviePlayerController *player = self.moviePlayer;
    if (player) {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center removeObserver:self
                          name:MPMoviePlayerLoadStateDidChangeNotification
                        object:player];
        [center removeObserver:self
                          name:MPMoviePlayerPlaybackStateDidChangeNotification
                        object:player];
        [center removeObserver:self
                          name:MPMoviePlayerPlaybackDidFinishNotification
                        object:player];
        [player stop];
        [player.view removeFromSuperview];
        self.moviePlayer = nil;
    }

    self.gifLoading = NO;
    self.gifPlaying = NO;

    if (self.image != self.staticThumbnail) {
        [super setImage:self.staticThumbnail];
    }

    if (DCActiveGifAttachment == self) {
        DCActiveGifAttachment = nil;
    }
    [self dc_updateGifChrome];
}

- (void)releaseChatThumbnailForResidency {
    [self stopPlayback];
    self.staticThumbnail = nil;
    [super releaseChatThumbnailForResidency];
    [self dc_updateGifChrome];
}

- (void)releaseThumbnailForResidency {
    [self releaseChatThumbnailForResidency];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window && (self.gifLoading || self.gifPlaying)) {
        [self stopPlayback];
    } else {
        [self dc_updateGifChrome];
    }
}

@end
