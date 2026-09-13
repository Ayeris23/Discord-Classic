//
//  DCImageViewController.m
//  Discord Classic
//
//  Created by Trevir on 11/17/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCImageViewController.h"
#import "DCImageMessageOverlayView.h"
#import "DCTools.h"
#import "DCChatMediaManager.h"
#import "DCResourceManager.h"
#import "SDWebImageManager.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static const NSUInteger DCImageViewerMegabyte = 1024U * 1024U;

NSString * const DCImageViewerUnderlyingGeometryDidChangeNotification =
    @"DCImageViewerUnderlyingGeometryDidChangeNotification";

typedef void (^DCImageViewerDownloadCompletion)(NSString *path, NSError *error);

@interface DCImageViewerFileDownload : NSObject <NSURLConnectionDataDelegate>
@property (strong, nonatomic) NSURLConnection *connection;
@property (strong, nonatomic) NSOperationQueue *delegateQueue;
@property (strong, nonatomic) NSFileHandle *fileHandle;
@property (copy, nonatomic) NSString *filePath;
@property (copy, nonatomic) DCImageViewerDownloadCompletion completion;
@property (assign, atomic) BOOL finished;
- (id)initWithURL:(NSURL *)url
        cachePolicy:(NSURLRequestCachePolicy)cachePolicy
         completion:(DCImageViewerDownloadCompletion)completion;
- (void)cancel;
@end

@implementation DCImageViewerFileDownload

- (id)initWithURL:(NSURL *)url
        cachePolicy:(NSURLRequestCachePolicy)cachePolicy
         completion:(DCImageViewerDownloadCompletion)completion {
    self = [super init];
    if (!self) return nil;

    self.completion = completion;
    NSString *name = [[NSProcessInfo processInfo] globallyUniqueString];
    self.filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"dc-image-%@.img", name]];
    [[NSFileManager defaultManager] createFileAtPath:self.filePath contents:nil attributes:nil];
    self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.filePath];
    if (!self.fileHandle) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:cachePolicy
                                                       timeoutInterval:30.0];
    self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];

    BOOL usesLegacyRunLoop = [[[UIDevice currentDevice] systemVersion]
        compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending;
    if (usesLegacyRunLoop) {
        [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop]
                                   forMode:NSRunLoopCommonModes];
    } else {
        self.delegateQueue = [[NSOperationQueue alloc] init];
        self.delegateQueue.maxConcurrentOperationCount = 1;
        [self.connection setDelegateQueue:self.delegateQueue];
    }
    [self.connection start];
    return self;
}

- (void)dc_finishWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;

    [self.fileHandle closeFile];
    self.fileHandle = nil;
    self.connection = nil;

    NSString *path = error ? nil : [self.filePath copy];
    if (error && self.filePath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    }

    DCImageViewerDownloadCompletion completion = self.completion;
    self.completion = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(path, error);
        });
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (status >= 400) {
            NSError *error = [NSError errorWithDomain:@"DCImageViewer"
                                                 code:status
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 [NSString stringWithFormat:@"Image request returned HTTP %ld", (long)status]}];
            [connection cancel];
            [self dc_finishWithError:error];
            return;
        }
    }
    [self.fileHandle truncateFileAtOffset:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (!self.finished && data.length) {
        [self.fileHandle writeData:data];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [self dc_finishWithError:nil];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self dc_finishWithError:error];
}

- (void)cancel {
    if (self.finished) return;
    [self.connection cancel];
    self.finished = YES;
    [self.fileHandle closeFile];
    self.fileHandle = nil;
    self.connection = nil;
    self.completion = nil;
    if (self.filePath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    }
}

@end

static dispatch_queue_t DCImageViewerDecodeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.discordclassic.imageviewer.decode", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL DCImageViewerDiscordMediaHost(NSString *host) {
    NSString *lower = [host lowercaseString];
    return [lower hasSuffix:@"discordapp.net"] ||
           [lower hasSuffix:@"discordapp.com"] ||
           [lower hasSuffix:@"discord.com"];
}

/* Remove chat-thumbnail sizing while preserving Discord's opaque signed query
 * fields. Native JPEG/PNG attachments keep their original proxy format; WebP
 * remains transcoded because ImageIO on the target OS cannot decode it. */
static NSURL *DCImageViewerFullResolutionURL(NSURL *sourceURL) {
    if (!sourceURL || !DCImageViewerDiscordMediaHost(sourceURL.host)) return sourceURL;

    NSString *absolute = sourceURL.absoluteString;
    NSRange question = [absolute rangeOfString:@"?"];
    NSString *base = question.location == NSNotFound
        ? absolute
        : [absolute substringToIndex:question.location];
    NSString *query = question.location == NSNotFound
        ? @""
        : [absolute substringFromIndex:question.location + 1];

    NSString *extension = sourceURL.pathExtension.lowercaseString;
    NSSet *nativeExtensions = [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"gif", @"bmp", @"tif", @"tiff", nil];
    BOOL needsPNGTranscode = ![nativeExtensions containsObject:extension];
    NSMutableArray *parts = [NSMutableArray array];
    BOOL hasFormat = NO;

    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? part : [part substringToIndex:equals.location];
        NSString *lowerKey = key.lowercaseString;
        if ([lowerKey isEqualToString:@"width"] ||
            [lowerKey isEqualToString:@"height"] ||
            [lowerKey isEqualToString:@"size"]) {
            continue;
        }
        if ([lowerKey isEqualToString:@"format"]) {
            if (needsPNGTranscode) {
                [parts addObject:@"format=png"];
                hasFormat = YES;
            }
            continue;
        }
        [parts addObject:part];
    }

    if (needsPNGTranscode && !hasFormat) [parts addObject:@"format=png"];
    if (parts.count == 0) return [NSURL URLWithString:base];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", base,
                                 [parts componentsJoinedByString:@"&"]]];
}

static CGSize DCImageViewerPixelSizeAtPath(NSString *path) {
    if (!path.length) return CGSizeZero;
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *sourceOptions = @{(NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                                                         (__bridge CFDictionaryRef)sourceOptions);
    if (!source) return CGSizeZero;

    NSDictionary *properties = (__bridge_transfer NSDictionary *)
        CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!properties) return CGSizeZero;

    CGFloat width = [[properties objectForKey:(NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat height = [[properties objectForKey:(NSString *)kCGImagePropertyPixelHeight] doubleValue];
    NSNumber *orientation = [properties objectForKey:(NSString *)kCGImagePropertyOrientation];
    NSInteger orientationValue = orientation.integerValue;
    if (orientationValue >= 5 && orientationValue <= 8) {
        CGFloat temp = width;
        width = height;
        height = temp;
    }
    return CGSizeMake(width, height);
}

static UIImage *DCImageViewerDecodeAtPath(NSString *path, NSUInteger maxPixel) {
    if (!path.length || maxPixel == 0) return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *sourceOptions = @{(NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                                                         (__bridge CFDictionaryRef)sourceOptions);
    if (!source) return nil;

    NSDictionary *options = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
        (NSString *)kCGImageSourceShouldCache: @YES
    };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!imageRef) return nil;

    UIImage *image = [UIImage imageWithCGImage:imageRef scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    return image;
}

static NSUInteger DCImageViewerDecodedCost(UIImage *image) {
    if (!image.CGImage) return 0;
    size_t row = CGImageGetBytesPerRow(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (row && height) return (NSUInteger)(row * height);
    return (NSUInteger)(CGImageGetWidth(image.CGImage) * height * 4U);
}

static uint64_t DCImageViewerEstimatedRasterCost(CGSize pixelSize) {
    if (pixelSize.width <= 0.0f || pixelSize.height <= 0.0f) return 0;
    double bytes = (double)pixelSize.width * (double)pixelSize.height * 4.0;
    if (bytes >= (double)UINT64_MAX) return UINT64_MAX;
    return (uint64_t)ceil(bytes);
}

static NSURL *DCImageViewerURLByApplyingPixelLimit(NSURL *sourceURL,
                                                    CGSize sourcePixelSize,
                                                    NSUInteger maxPixel) {
    if (!sourceURL || maxPixel == 0 ||
        !DCImageViewerDiscordMediaHost(sourceURL.host) ||
        sourcePixelSize.width <= 0.0f || sourcePixelSize.height <= 0.0f) {
        return sourceURL;
    }

    CGFloat longSide = MAX(sourcePixelSize.width, sourcePixelSize.height);
    if (longSide <= (CGFloat)maxPixel) return sourceURL;

    CGFloat scale = (CGFloat)maxPixel / longSide;
    NSUInteger width = MAX((NSUInteger)1, (NSUInteger)floor(sourcePixelSize.width * scale));
    NSUInteger height = MAX((NSUInteger)1, (NSUInteger)floor(sourcePixelSize.height * scale));

    NSString *absolute = sourceURL.absoluteString;
    NSString *host = sourceURL.host.lowercaseString;
    if ([host isEqualToString:@"cdn.discordapp.com"] ||
        [host isEqualToString:@"cdn.discordapp.net"] ||
        [host isEqualToString:@"cdn.discord.com"]) {
        NSString *authority = [NSString stringWithFormat:@"://%@", sourceURL.host];
        NSRange authorityRange = [absolute rangeOfString:authority options:NSCaseInsensitiveSearch];
        if (authorityRange.location != NSNotFound) {
            absolute = [absolute stringByReplacingCharactersInRange:authorityRange
                                                         withString:@"://media.discordapp.net"];
        }
    }

    NSRange question = [absolute rangeOfString:@"?"];
    NSString *base = question.location == NSNotFound
        ? absolute
        : [absolute substringToIndex:question.location];
    NSString *query = question.location == NSNotFound
        ? @""
        : [absolute substringFromIndex:question.location + 1];

    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? part : [part substringToIndex:equals.location];
        NSString *lowerKey = key.lowercaseString;
        if ([lowerKey isEqualToString:@"width"] ||
            [lowerKey isEqualToString:@"height"] ||
            [lowerKey isEqualToString:@"size"]) {
            continue;
        }
        [parts addObject:part];
    }
    [parts addObject:[NSString stringWithFormat:@"width=%lu", (unsigned long)width]];
    [parts addObject:[NSString stringWithFormat:@"height=%lu", (unsigned long)height]];

    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", base,
                                 [parts componentsJoinedByString:@"&"]]];
}

static BOOL DCImageViewerErrorMayBeExpiredSignature(NSError *error) {
    return error && (error.code == 401 || error.code == 403 || error.code == 404);
}

static BOOL DCImageViewerActive = NO;

@interface DCImageViewController () <UIGestureRecognizerDelegate>
@property (strong, nonatomic) UIActivityIndicatorView *loadingSpinner;
@property (strong, nonatomic) DCImageViewerFileDownload *downloadOperation;
@property (copy, nonatomic) NSString *fullResolutionPath;
@property (assign, nonatomic) CGSize sourcePixelSize;
@property (assign, nonatomic) NSUInteger displayedMaxPixel;
@property (assign, nonatomic) NSUInteger requestedMaxPixel;
@property (assign, nonatomic) NSUInteger pendingMaxPixel;
@property (assign, nonatomic) NSUInteger decodeGeneration;
@property (assign, nonatomic) NSUInteger fullResolutionDownloadAttempts;
@property (assign, nonatomic) NSUInteger downloadPixelLimit;
@property (assign, nonatomic) BOOL resolvingFullResolutionURL;
@property (assign, nonatomic) BOOL decodeDeferredForMemoryPressure;
@property (assign, nonatomic) CFAbsoluteTime lastSignatureRefreshAttemptTime;
@property (assign, nonatomic) BOOL chatMediaPurged;
@property (strong, nonatomic) UIWindow *overlayPresentationWindow;
@property (weak, nonatomic) UIWindow *overlayPreviousKeyWindow;
@property (weak, nonatomic) UIView *overlayDimmingView;
@property (assign, nonatomic) BOOL overlayPresentationActive;
@property (assign, nonatomic) BOOL overlayDismissInProgress;
@property (assign, nonatomic) CGFloat overlayDismissVelocityY;
@property (assign, nonatomic) BOOL hasSavedSlideMenuGestureSupport;
@property (assign, nonatomic) APLSlideMenuGestureSupportType savedSlideMenuGestureSupport;
@property (strong, nonatomic) DCImageMessageOverlayView *messageOverlay;
@property (assign, nonatomic) BOOL hasSavedStatusBarState;
@property (assign, nonatomic) BOOL savedStatusBarHidden;
@property (assign, nonatomic) UIStatusBarStyle savedStatusBarStyle;
@property (assign, nonatomic) UIInterfaceOrientation overlayInitialOrientation;
@property (assign, nonatomic) BOOL overlayOrientationChanged;
@property (assign, nonatomic) BOOL overlayRotationInProgress;
- (void)dc_dismissViewerAnimated:(BOOL)animated;
- (void)dc_prepareForOverlayPresentationInWindow:(UIWindow *)window
                               previousKeyWindow:(UIWindow *)previousKeyWindow
                                     dimmingView:(UIView *)dimmingView;
- (void)dc_finishViewerDismissalCleanup;
- (void)dc_relayoutOverlayForCurrentWindowGeometry;
- (void)dc_scheduleOverlayGeometryRelayout;
- (void)dc_normalizeImageGeometryPreservingZoom;
- (void)dc_statusBarOrientationWillChange:(NSNotification *)notification;
- (void)dc_statusBarOrientationDidChange:(NSNotification *)notification;
- (void)dc_statusBarFrameDidChange:(NSNotification *)notification;
- (void)dc_restoreStatusBarState;
- (void)dc_restorePresentingOrientationForWindow:(UIWindow *)window;
- (void)dc_forceDeviceOrientationToPortraitForWindow:(UIWindow *)window completion:(void (^)(void))completion;
- (void)dc_ensureOverlayAboveHostChrome;
@end

@implementation DCImageViewController

+ (BOOL)isImageViewerActive {
    return DCImageViewerActive;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.scrollView.frame = self.view.bounds;
    self.navBar.alpha = 1.0;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIApplication *application = [UIApplication sharedApplication];
    self.savedStatusBarHidden = application.statusBarHidden;
    self.savedStatusBarStyle = application.statusBarStyle;
    self.hasSavedStatusBarState = YES;
    self.overlayInitialOrientation = application.statusBarOrientation;
    self.overlayOrientationChanged = NO;
    self.overlayRotationInProgress = NO;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(dc_statusBarOrientationWillChange:)
               name:UIApplicationWillChangeStatusBarOrientationNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(dc_statusBarOrientationDidChange:)
               name:UIApplicationDidChangeStatusBarOrientationNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(dc_statusBarFrameDidChange:)
               name:UIApplicationDidChangeStatusBarFrameNotification
             object:nil];
    if (self.slideMenuController) {
        self.savedSlideMenuGestureSupport = self.slideMenuController.gestureSupport;
        self.hasSavedSlideMenuGestureSupport = YES;
        self.slideMenuController.gestureSupport = APLSlideMenuGestureSupportNone;
    }

    self.scrollView.delegate = self;
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 4.0;
    self.scrollView.zoomScale = 1.0;
    self.scrollView.clipsToBounds = YES;
    self.scrollView.backgroundColor = [UIColor blackColor];
    // At minimum zoom the image can safely follow the scroll view's bounds
    // through UIKit's rotation animation. Once zoomed, UIScrollView owns the
    // transform and autoresizing must stay out of the way.
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight;
    self.imageView.image = self.previewImage;

    self.wantsFullScreenLayout = YES;
    if ([[UIDevice currentDevice] userInterfaceIdiom] != UIUserInterfaceIdiomPad) {
        [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackTranslucent animated:YES];
    }

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.scrollView addGestureRecognizer:doubleTap];

    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleSingleTap:)];
    singleTap.numberOfTapsRequired = 1;
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [self.scrollView addGestureRecognizer:singleTap];

    UIPanGestureRecognizer *dismissPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDismissPan:)];
    dismissPan.delegate = self;
    dismissPan.maximumNumberOfTouches = 1;
    [self.scrollView addGestureRecognizer:dismissPan];
    [self.scrollView.panGestureRecognizer requireGestureRecognizerToFail:dismissPan];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spinner.hidesWhenStopped = YES;
    spinner.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                               UIViewAutoresizingFlexibleRightMargin |
                               UIViewAutoresizingFlexibleTopMargin |
                               UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:spinner];
    self.loadingSpinner = spinner;

    self.chromeVisible = YES;

    if (self.sourceMessage) {
        DCImageMessageOverlayView *messageOverlay =
            [[DCImageMessageOverlayView alloc] initWithMessage:self.sourceMessage
                                                         frame:CGRectMake(0.0f,
                                                                          self.view.bounds.size.height - 53.0f,
                                                                          self.view.bounds.size.width,
                                                                          53.0f)];
        self.messageOverlay = messageOverlay;
        [self.view addSubview:messageOverlay];
    }

    [[DCChatMediaManager sharedManager] clearMemory];
    [[[SDWebImageManager sharedManager] imageCache] clearMemory];
    if ([DCResourceManager sharedManager].memoryClass == DCDeviceMemoryClass256MB) {
        self.chatMediaPurged = YES;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DCChatMediaPurgeVisibleNotification object:nil];
    }

    [self dc_beginFullResolutionLoad];
}

- (void)dc_prepareForOverlayPresentationInWindow:(UIWindow *)window
                               previousKeyWindow:(UIWindow *)previousKeyWindow
                                     dimmingView:(UIView *)dimmingView {
    self.overlayPresentationWindow = window;
    self.overlayPreviousKeyWindow = previousKeyWindow;
    self.overlayDimmingView = dimmingView;
    self.overlayPresentationActive = YES;
    self.overlayDismissInProgress = NO;
    DCImageViewerActive = YES;

    [self dc_ensureOverlayAboveHostChrome];

    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;
    self.scrollView.backgroundColor = [UIColor clearColor];
    self.scrollView.opaque = NO;
    self.imageView.backgroundColor = [UIColor clearColor];
    self.imageView.opaque = NO;
    [self dc_normalizeImageGeometryPreservingZoom];
}

- (void)dc_ensureOverlayAboveHostChrome {
    if (!self.overlayPresentationActive || !self.overlayPresentationWindow) return;

    UIWindow *underlyingWindow = self.overlayPreviousKeyWindow;
    if (underlyingWindow && self.overlayPresentationWindow.windowLevel <= underlyingWindow.windowLevel) {
        self.overlayPresentationWindow.windowLevel = underlyingWindow.windowLevel + 1.0f;
    }
}

- (void)dc_normalizeImageGeometryPreservingZoom {
    if (!self.scrollView || !self.imageView || self.overlayDismissInProgress) return;

    CGFloat minimumScale = self.scrollView.minimumZoomScale;
    CGFloat previousScale = MAX(minimumScale, self.scrollView.zoomScale);
    CGSize previousContentSize = self.scrollView.contentSize;
    CGRect previousBounds = self.scrollView.bounds;
    CGPoint previousCenter = CGPointMake(self.scrollView.contentOffset.x +
                                         previousBounds.size.width * 0.5f,
                                         self.scrollView.contentOffset.y +
                                         previousBounds.size.height * 0.5f);
    CGFloat normalizedX = previousContentSize.width > 0.0f
        ? previousCenter.x / previousContentSize.width : 0.5f;
    CGFloat normalizedY = previousContentSize.height > 0.0f
        ? previousCenter.y / previousContentSize.height : 0.5f;
    normalizedX = MIN(1.0f, MAX(0.0f, normalizedX));
    normalizedY = MIN(1.0f, MAX(0.0f, normalizedY));

    [self.scrollView setZoomScale:minimumScale animated:NO];
    self.imageView.transform = CGAffineTransformIdentity;
    CGSize baseSize = self.scrollView.bounds.size;
    self.imageView.frame = CGRectMake(0.0f, 0.0f, baseSize.width, baseSize.height);
    self.scrollView.contentSize = baseSize;

    CGFloat restoredScale = MIN(self.scrollView.maximumZoomScale, previousScale);
    if (restoredScale > minimumScale + 0.01f) {
        self.imageView.autoresizingMask = UIViewAutoresizingNone;
        [self.scrollView setZoomScale:restoredScale animated:NO];

        CGSize contentSize = self.scrollView.contentSize;
        CGSize boundsSize = self.scrollView.bounds.size;
        CGPoint offset = CGPointMake(normalizedX * contentSize.width - boundsSize.width * 0.5f,
                                     normalizedY * contentSize.height - boundsSize.height * 0.5f);
        CGFloat maxOffsetX = MAX(0.0f, contentSize.width - boundsSize.width);
        CGFloat maxOffsetY = MAX(0.0f, contentSize.height - boundsSize.height);
        offset.x = MIN(maxOffsetX, MAX(0.0f, offset.x));
        offset.y = MIN(maxOffsetY, MAX(0.0f, offset.y));
        self.scrollView.contentOffset = offset;
    } else {
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                          UIViewAutoresizingFlexibleHeight;
        self.scrollView.contentOffset = CGPointZero;
    }
}

- (void)dc_relayoutOverlayForCurrentWindowGeometry {
    if (!self.overlayPresentationActive || !self.overlayPresentationWindow) return;

    [self dc_ensureOverlayAboveHostChrome];

    // The viewer is the root controller of its own overlay window. UIKit owns
    // that window's rotation transform, so only settle the viewer's internal
    // geometry after the system rotation has completed.
    self.overlayDimmingView.frame = self.view.bounds;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];

    [self dc_normalizeImageGeometryPreservingZoom];
    self.loadingSpinner.center = CGPointMake(CGRectGetMidX(self.view.bounds),
                                             CGRectGetMidY(self.view.bounds));
    [self.messageOverlay layoutForSuperviewBounds:self.view.bounds];

    if (self.fullResolutionPath.length) {
        [self dc_requestDecodeForZoomScale:self.scrollView.zoomScale force:NO];
    }
}

- (void)dc_scheduleOverlayGeometryRelayout {
    if (!self.overlayPresentationActive) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(dc_relayoutOverlayForCurrentWindowGeometry)
                                               object:nil];
    [self performSelector:@selector(dc_relayoutOverlayForCurrentWindowGeometry)
               withObject:nil
               afterDelay:0.0];
}

- (void)dc_statusBarOrientationWillChange:(NSNotification *)notification {
    if (!self.overlayPresentationActive) return;

    [self dc_ensureOverlayAboveHostChrome];
    self.overlayRotationInProgress = YES;

    // At the default zoom level, let UIKit animate the image view alongside the
    // scroll view instead of holding the old portrait/landscape frame until the
    // rotation is over. Never autoresize a transformed zoom view.
    if (self.scrollView.zoomScale <= self.scrollView.minimumZoomScale + 0.01f &&
        !self.overlayDismissInProgress) {
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:NO];
        self.imageView.transform = CGAffineTransformIdentity;
        self.imageView.frame = self.scrollView.bounds;
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                          UIViewAutoresizingFlexibleHeight;
        self.scrollView.contentSize = self.scrollView.bounds.size;
    } else {
        self.imageView.autoresizingMask = UIViewAutoresizingNone;
    }
}

- (void)dc_statusBarOrientationDidChange:(NSNotification *)notification {
    if (!self.overlayPresentationActive) return;

    [self dc_ensureOverlayAboveHostChrome];
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    if (orientation != self.overlayInitialOrientation) {
        self.overlayOrientationChanged = YES;
    }

    self.overlayRotationInProgress = NO;
    [self dc_scheduleOverlayGeometryRelayout];
}

- (void)dc_statusBarFrameDidChange:(NSNotification *)notification {
    if (!self.overlayPresentationActive) return;

    [self dc_ensureOverlayAboveHostChrome];

    // On iOS 5/6 this notification can arrive while the root controller is
    // halfway through its rotation transform. Recomputing window coordinates at
    // that moment causes the overlay to snap and can briefly expose the chat
    // navbar underneath. Autoresizing handles the animated transition; settle
    // against final window geometry only after orientation completes.
    if (self.overlayRotationInProgress) return;
    [self dc_scheduleOverlayGeometryRelayout];
}

- (void)dc_restoreStatusBarState {
    if (!self.hasSavedStatusBarState) return;

    UIApplication *application = [UIApplication sharedApplication];
    [application setStatusBarStyle:self.savedStatusBarStyle animated:NO];
    [application setStatusBarHidden:self.savedStatusBarHidden withAnimation:UIStatusBarAnimationNone];
    self.hasSavedStatusBarState = NO;
}

- (void)dc_restorePresentingOrientationForWindow:(UIWindow *)window {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) return;

    if ([UIViewController respondsToSelector:@selector(attemptRotationToDeviceOrientation)]) {
        [UIViewController attemptRotationToDeviceOrientation];
    }

    UIViewController *rootViewController = window.rootViewController;
    if (rootViewController) {
        [rootViewController.view setNeedsLayout];
    }
}

- (void)dc_forceDeviceOrientationToPortraitForWindow:(UIWindow *)window completion:(void (^)(void))completion {
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad || !window) {
        if (completion) completion();
        return;
    }

    DCImageViewerActive = NO;

    UIApplication *application = [UIApplication sharedApplication];
    BOOL needsPortraitTransition = !UIInterfaceOrientationIsPortrait(application.statusBarOrientation);
    UIDevice *device = [UIDevice currentDevice];
    UIDeviceOrientation portrait = UIDeviceOrientationPortrait;
    SEL orientationSelector = NSSelectorFromString(@"setOrientation:");
    BOOL forcedDeviceOrientation = NO;

    if ([device respondsToSelector:orientationSelector]) {
        @try {
            NSMethodSignature *signature = [device methodSignatureForSelector:orientationSelector];
            if (signature) {
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                [invocation setTarget:device];
                [invocation setSelector:orientationSelector];
                [invocation setArgument:&portrait atIndex:2];
                [invocation invoke];
                forcedDeviceOrientation = YES;
            }
        }
        @catch (NSException *exception) {
            NSLog(@"[ImageViewer] private orientation setter failed: %@", exception);
        }
    }

    if (!forcedDeviceOrientation) {
        @try {
            [device setValue:[NSNumber numberWithInteger:portrait] forKey:@"orientation"];
            forcedDeviceOrientation = YES;
        }
        @catch (NSException *exception) {
            NSLog(@"[ImageViewer] orientation KVC fallback failed: %@", exception);
        }
    }

    if ([UIViewController respondsToSelector:@selector(attemptRotationToDeviceOrientation)]) {
        [UIViewController attemptRotationToDeviceOrientation];
    }

    [window.rootViewController.view setNeedsLayout];

    void (^finish)(void) = ^{
        [window.rootViewController.view setNeedsLayout];
        [window.rootViewController.view layoutIfNeeded];
        if (completion) completion();
    };

    if (needsPortraitTransition && forcedDeviceOrientation) {
        NSTimeInterval duration = [application statusBarOrientationAnimationDuration];
        if (duration <= 0.0) duration = 0.30;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), finish);
    } else {
        finish();
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self dc_ensureOverlayAboveHostChrome];
    [self.messageOverlay layoutForSuperviewBounds:self.view.bounds];
    if (self.fullResolutionPath.length) {
        [self dc_requestDecodeForZoomScale:self.scrollView.zoomScale force:NO];
    }
}

- (void)dc_beginFullResolutionLoad {
    if (!self.fullResURL || self.downloadOperation || self.resolvingFullResolutionURL ||
        self.fullResolutionPath.length) return;

    self.resolvingFullResolutionURL = YES;
    [self.loadingSpinner startAnimating];

    NSURL *configuredURL = self.fullResURL;
    __weak DCImageViewController *weakSelf = self;
    [[DCChatMediaManager sharedManager]
        resolveMediaURL:configuredURL
             completion:^(NSURL *resolvedURL, NSError *resolutionError) {
        DCImageViewController *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.fullResURL isEqual:configuredURL]) return;
        strongSelf.resolvingFullResolutionURL = NO;

        if (resolutionError &&
            [[DCChatMediaManager sharedManager] mediaURLNeedsRefresh:resolvedURL]) {
            [strongSelf.loadingSpinner stopAnimating];
            NSLog(@"[ImageViewer] signature resolution failed %@: %@",
                  configuredURL, resolutionError);
            return;
        }

        NSURL *requestURL = DCImageViewerFullResolutionURL(resolvedURL);
        requestURL = [[DCChatMediaManager sharedManager] currentMediaURLForURL:requestURL];
        NSUInteger requestedPixelLimit = strongSelf.downloadPixelLimit;
        if (requestedPixelLimit > 0) {
            requestURL = DCImageViewerURLByApplyingPixelLimit(requestURL,
                                                              strongSelf.sourcePixelSize,
                                                              requestedPixelLimit);
        }
        strongSelf.fullResolutionDownloadAttempts++;
        NSURLRequestCachePolicy cachePolicy = strongSelf.fullResolutionDownloadAttempts > 1
            ? NSURLRequestReloadIgnoringLocalCacheData
            : NSURLRequestUseProtocolCachePolicy;
        NSLog(@"[ImageViewer] source URL attempt %lu: %@",
              (unsigned long)strongSelf.fullResolutionDownloadAttempts, requestURL);
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];

        strongSelf.downloadOperation = [[DCImageViewerFileDownload alloc]
            initWithURL:requestURL
            cachePolicy:cachePolicy
             completion:^(NSString *path, NSError *error) {
            DCImageViewController *downloadSelf = weakSelf;
            if (!downloadSelf) {
                if (path.length) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                return;
            }

            downloadSelf.downloadOperation = nil;
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
            if (error || !path.length) {
                NSLog(@"[ImageViewer] download failed attempt %lu %@: %@",
                      (unsigned long)downloadSelf.fullResolutionDownloadAttempts,
                      requestURL, error);

                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                BOOL canRefresh = DCImageViewerErrorMayBeExpiredSignature(error) &&
                    (downloadSelf.lastSignatureRefreshAttemptTime <= 0.0 ||
                     now - downloadSelf.lastSignatureRefreshAttemptTime >= 5.0);
                if (canRefresh) {
                    downloadSelf.lastSignatureRefreshAttemptTime = now;
                    [[DCChatMediaManager sharedManager]
                        refreshMediaURL:configuredURL
                             completion:^(NSURL *retryURL, NSError *refreshError) {
                        DCImageViewController *retrySelf = weakSelf;
                        if (!retrySelf || ![retrySelf.fullResURL isEqual:configuredURL]) return;
                        if (!refreshError ||
                            ![[DCChatMediaManager sharedManager] mediaURLNeedsRefresh:retryURL]) {
                            [retrySelf dc_beginFullResolutionLoad];
                            return;
                        }
                        [retrySelf.loadingSpinner stopAnimating];
                        NSLog(@"[ImageViewer] signature refresh failed %@: %@",
                              configuredURL, refreshError);
                    }];
                    return;
                }

                [downloadSelf.loadingSpinner stopAnimating];
                return;
            }

            CGSize downloadedPixelSize = DCImageViewerPixelSizeAtPath(path);
            if (downloadedPixelSize.width <= 0 || downloadedPixelSize.height <= 0) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                [downloadSelf.loadingSpinner stopAnimating];
                NSLog(@"[ImageViewer] unsupported image data %@", requestURL);
                return;
            }

            DCResourceManager *resources = [DCResourceManager sharedManager];
            uint64_t localDecodeCeiling = (uint64_t)resources.imageViewerDecodedImageBudget * 2ULL;
            uint64_t downloadedRasterCost = DCImageViewerEstimatedRasterCost(downloadedPixelSize);

            if (requestedPixelLimit == 0) {
                downloadSelf.sourcePixelSize = downloadedPixelSize;
                NSUInteger safeMaxPixel = [downloadSelf
                    dc_targetMaxPixelForZoomScale:downloadSelf.scrollView.maximumZoomScale];
                CGFloat sourceLong = MAX(downloadedPixelSize.width, downloadedPixelSize.height);

                if (downloadedRasterCost > localDecodeCeiling &&
                    safeMaxPixel > 0 && sourceLong > (CGFloat)safeMaxPixel * 1.05f) {
                    if (DCImageViewerDiscordMediaHost(requestURL.host)) {
                        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                        downloadSelf.downloadPixelLimit = safeMaxPixel;
                        NSLog(@"[ImageViewer] source %.0fx%.0f estimated raster %.1fMB exceeds %.1fMB local decode ceiling; requesting %lupx proxy",
                              downloadedPixelSize.width,
                              downloadedPixelSize.height,
                              (double)downloadedRasterCost / (double)DCImageViewerMegabyte,
                              (double)localDecodeCeiling / (double)DCImageViewerMegabyte,
                              (unsigned long)safeMaxPixel);
                        [downloadSelf dc_beginFullResolutionLoad];
                        return;
                    }

                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                    [downloadSelf.loadingSpinner stopAnimating];
                    NSLog(@"[ImageViewer] source %.0fx%.0f estimated raster %.1fMB exceeds %.1fMB local decode ceiling; keeping preview",
                          downloadedPixelSize.width,
                          downloadedPixelSize.height,
                          (double)downloadedRasterCost / (double)DCImageViewerMegabyte,
                          (double)localDecodeCeiling / (double)DCImageViewerMegabyte);
                    return;
                }
            } else if (downloadedRasterCost > localDecodeCeiling) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                [downloadSelf.loadingSpinner stopAnimating];
                NSLog(@"[ImageViewer] proxy remained too large at %.0fx%.0f %.1fMB; keeping preview",
                      downloadedPixelSize.width,
                      downloadedPixelSize.height,
                      (double)downloadedRasterCost / (double)DCImageViewerMegabyte);
                return;
            }

            downloadSelf.fullResolutionPath = path;
            downloadSelf.lastSignatureRefreshAttemptTime = 0.0;
            uint64_t resident = [resources currentResidentMemoryBytes];
            if (requestedPixelLimit > 0) {
                NSLog(@"[ImageViewer] proxy %.0fx%.0f for source %.0fx%.0f resident %.1fMB budget %.1fMB",
                      downloadedPixelSize.width,
                      downloadedPixelSize.height,
                      downloadSelf.sourcePixelSize.width,
                      downloadSelf.sourcePixelSize.height,
                      (double)resident / (1024.0 * 1024.0),
                      (double)resources.imageViewerDecodedImageBudget / (1024.0 * 1024.0));
            } else {
                NSLog(@"[ImageViewer] source %.0fx%.0f resident %.1fMB budget %.1fMB",
                      downloadSelf.sourcePixelSize.width,
                      downloadSelf.sourcePixelSize.height,
                      (double)resident / (1024.0 * 1024.0),
                      (double)resources.imageViewerDecodedImageBudget / (1024.0 * 1024.0));
            }
            if (downloadSelf.decodeDeferredForMemoryPressure) {
                [downloadSelf.loadingSpinner stopAnimating];
            } else {
                [downloadSelf dc_requestDecodeForZoomScale:downloadSelf.scrollView.zoomScale force:YES];
            }
        }];
    }];
}

- (NSUInteger)dc_targetMaxPixelForZoomScale:(CGFloat)zoomScale {
    CGFloat sourceLong = MAX(self.sourcePixelSize.width, self.sourcePixelSize.height);
    CGFloat sourceShort = MIN(self.sourcePixelSize.width, self.sourcePixelSize.height);
    if (sourceLong <= 0 || sourceShort <= 0) return 0;

    CGFloat screenScale = [UIScreen mainScreen].scale;
    if (screenScale <= 0.0f) screenScale = 1.0f;
    CGFloat displayLong = MAX(self.imageView.bounds.size.width, self.imageView.bounds.size.height);
    if (displayLong <= 0.0f) displayLong = MAX(self.view.bounds.size.width, self.view.bounds.size.height);
    CGFloat requested = displayLong * screenScale * MAX(1.0f, zoomScale) * 1.10f;

    NSUInteger budget = [DCResourceManager sharedManager].imageViewerDecodedImageBudget;
    NSUInteger currentCost = self.imageView.image == self.previewImage
        ? 0 : DCImageViewerDecodedCost(self.imageView.image);
    double rasterCostBudget = (double)budget * 0.85;
    double transitionCostBudget = (double)budget * 1.25 - (double)currentCost;
    if (transitionCostBudget > 0.0) {
        rasterCostBudget = MIN(rasterCostBudget, transitionCostBudget);
    }

    double pixelBudget = MAX(1.0, rasterCostBudget) / 4.0;
    double aspect = (double)sourceShort / (double)sourceLong;
    double budgetLong = sqrt(pixelBudget / MAX(0.01, aspect));

    CGFloat target = MIN(sourceLong, MIN(requested, (CGFloat)budgetLong));
    return (NSUInteger)floor(MAX(1.0f, target));
}

- (void)dc_startDecodeForMaxPixel:(NSUInteger)targetMaxPixel {
    if (!self.fullResolutionPath.length || targetMaxPixel == 0) return;

    NSUInteger generation = self.decodeGeneration + 1;
    self.requestedMaxPixel = targetMaxPixel;
    self.decodeGeneration = generation;
    NSString *path = [self.fullResolutionPath copy];

    __weak DCImageViewController *weakSelf = self;
    dispatch_async(DCImageViewerDecodeQueue(), ^{
        @autoreleasepool {
            UIImage *decoded = DCImageViewerDecodeAtPath(path, targetMaxPixel);
            dispatch_async(dispatch_get_main_queue(), ^{
                DCImageViewController *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.decodeGeneration != generation ||
                    ![strongSelf.fullResolutionPath isEqualToString:path]) return;

                strongSelf.requestedMaxPixel = 0;
                if (!decoded) {
                    strongSelf.pendingMaxPixel = 0;
                    [strongSelf.loadingSpinner stopAnimating];
                    NSLog(@"[ImageViewer] decode failed at %lu px", (unsigned long)targetMaxPixel);
                    return;
                }

                strongSelf.imageView.image = decoded;
                strongSelf.displayedMaxPixel = MAX(CGImageGetWidth(decoded.CGImage),
                                                    CGImageGetHeight(decoded.CGImage));
                [strongSelf.loadingSpinner stopAnimating];

                NSUInteger cost = DCImageViewerDecodedCost(decoded);
                uint64_t resident = [[DCResourceManager sharedManager] currentResidentMemoryBytes];
                NSLog(@"[ImageViewer] decoded %lux%lu %.1fMB zoom %.2fx resident %.1fMB",
                      (unsigned long)CGImageGetWidth(decoded.CGImage),
                      (unsigned long)CGImageGetHeight(decoded.CGImage),
                      (double)cost / (double)DCImageViewerMegabyte,
                      strongSelf.scrollView.zoomScale,
                      (double)resident / (1024.0 * 1024.0));

                NSUInteger pendingMaxPixel = strongSelf.pendingMaxPixel;
                strongSelf.pendingMaxPixel = 0;
                if (pendingMaxPixel > strongSelf.displayedMaxPixel * 1.15) {
                    [strongSelf dc_requestDecodeForZoomScale:strongSelf.scrollView.zoomScale force:NO];
                }
            });
        }
    });
}

- (void)dc_requestDecodeForZoomScale:(CGFloat)zoomScale force:(BOOL)force {
    if (self.decodeDeferredForMemoryPressure) return;
    if (!self.fullResolutionPath.length) {
        if (!self.downloadOperation && self.fullResolutionDownloadAttempts > 0) {
            [self dc_beginFullResolutionLoad];
        }
        return;
    }
    if (self.sourcePixelSize.width <= 0) return;

    NSUInteger targetMaxPixel = [self dc_targetMaxPixelForZoomScale:zoomScale];
    if (targetMaxPixel == 0) return;

    if (self.requestedMaxPixel > 0) {
        if (targetMaxPixel > self.requestedMaxPixel * 1.15) {
            self.pendingMaxPixel = MAX(self.pendingMaxPixel, targetMaxPixel);
        }
        return;
    }

    if (!force && self.displayedMaxPixel > 0 &&
        targetMaxPixel <= self.displayedMaxPixel * 1.15) {
        return;
    }

    [self dc_startDecodeForMaxPixel:targetMaxPixel];
}

- (void)handleSingleTap:(UITapGestureRecognizer *)recognizer {
    if (self.messageOverlay.isExpanded) {
        [self.messageOverlay setExpanded:NO animated:YES];
        return;
    }

    self.chromeVisible = !self.chromeVisible;
    self.messageOverlay.userInteractionEnabled = self.chromeVisible;
    [UIView animateWithDuration:0.3 animations:^{
        [[UIApplication sharedApplication] setStatusBarHidden:!self.chromeVisible
                                                withAnimation:UIStatusBarAnimationFade];
        self.navBar.alpha = self.chromeVisible ? 1.0 : 0.0;
        self.messageOverlay.alpha = self.chromeVisible ? 1.0 : 0.0;
    }];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer {
    self.decodeDeferredForMemoryPressure = NO;
    if (self.scrollView.zoomScale > self.scrollView.minimumZoomScale) {
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
    } else {
        CGPoint tapPoint = [recognizer locationInView:self.imageView];
        CGFloat newScale = self.scrollView.maximumZoomScale;
        [self dc_requestDecodeForZoomScale:newScale force:NO];
        CGFloat width = self.scrollView.bounds.size.width / newScale;
        CGFloat height = self.scrollView.bounds.size.height / newScale;
        CGRect zoomRect = CGRectMake(tapPoint.x - width / 2,
                                     tapPoint.y - height / 2,
                                     width, height);
        [self.scrollView zoomToRect:zoomRect animated:YES];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    if (self.messageOverlay.isExpanded) return NO;
    if (self.scrollView.zoomScale > self.scrollView.minimumZoomScale + 0.01f) return NO;

    CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.scrollView];
    return velocity.y > 0.0f && fabs(velocity.y) > fabs(velocity.x);
}

- (void)handleDismissPan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.scrollView];
    CGFloat downwardOffset = MAX(0.0f, translation.y);

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        self.imageView.transform = CGAffineTransformMakeTranslation(0.0f, downwardOffset);
        if (self.overlayPresentationActive) {
            CGFloat progress = MIN(1.0f, downwardOffset / 200.0f);
            self.overlayDimmingView.alpha = 1.0f - progress;
            self.navBar.alpha = self.chromeVisible ? (1.0f - progress) : 0.0f;
            self.messageOverlay.alpha = self.chromeVisible ? (1.0f - progress) : 0.0f;
        }
        return;
    }

    if (recognizer.state != UIGestureRecognizerStateEnded &&
        recognizer.state != UIGestureRecognizerStateCancelled &&
        recognizer.state != UIGestureRecognizerStateFailed) {
        return;
    }

    CGPoint velocity = [recognizer velocityInView:self.scrollView];
    BOOL shouldDismiss = recognizer.state == UIGestureRecognizerStateEnded &&
        (downwardOffset >= 80.0f || velocity.y >= 700.0f);

    if (shouldDismiss) {
        self.overlayDismissVelocityY = MAX(0.0f, velocity.y);
        [self dc_dismissViewerAnimated:YES];
    } else {
        self.overlayDismissVelocityY = 0.0f;
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.imageView.transform = CGAffineTransformIdentity;
            if (self.overlayPresentationActive) {
                self.overlayDimmingView.alpha = 1.0f;
                self.navBar.alpha = self.chromeVisible ? 1.0f : 0.0f;
                self.messageOverlay.alpha = self.chromeVisible ? 1.0f : 0.0f;
            }
        } completion:nil];
    }
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    self.decodeDeferredForMemoryPressure = NO;
    self.imageView.autoresizingMask = UIViewAutoresizingNone;
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView
                       withView:(UIView *)view
                        atScale:(CGFloat)scale {
    if (scale <= scrollView.minimumZoomScale + 0.01f) {
        [scrollView setZoomScale:scrollView.minimumZoomScale animated:NO];
        self.imageView.transform = CGAffineTransformIdentity;
        self.imageView.frame = scrollView.bounds;
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                          UIViewAutoresizingFlexibleHeight;
        scrollView.contentSize = scrollView.bounds.size;
        scrollView.contentOffset = CGPointZero;
    } else {
        self.imageView.autoresizingMask = UIViewAutoresizingNone;
    }
    [self dc_requestDecodeForZoomScale:scale force:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [UIView animateWithDuration:0.15 animations:^{
        self.navBar.alpha = 0.0;
    }];
    if (!self.overlayPresentationActive) {
        [self dc_restoreStatusBarState];
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [[DCChatMediaManager sharedManager] clearMemory];
    [[[SDWebImageManager sharedManager] imageCache] clearMemory];

    self.decodeGeneration++;
    self.requestedMaxPixel = 0;
    self.pendingMaxPixel = 0;
    self.decodeDeferredForMemoryPressure = YES;
    if (self.previewImage) self.imageView.image = self.previewImage;
    self.displayedMaxPixel = 0;
    [self.loadingSpinner stopAnimating];
}

- (void)viewDidUnload {
    [self setImageView:nil];
    [self setScrollView:nil];
    [super viewDidUnload];
}

- (void)dc_finishViewerDismissalCleanup {
    DCImageViewerActive = NO;
    [self dc_restoreStatusBarState];
    [self dc_restorePresentingOrientationForWindow:self.overlayPreviousKeyWindow ?: [UIApplication sharedApplication].keyWindow];

    if (self.hasSavedSlideMenuGestureSupport && self.slideMenuController) {
        self.slideMenuController.gestureSupport = self.savedSlideMenuGestureSupport;
        self.hasSavedSlideMenuGestureSupport = NO;
    }

    if (self.chatMediaPurged) {
        self.chatMediaPurged = NO;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DCChatMediaRehydrateVisibleNotification object:nil];
    }

    if (self.overlayOrientationChanged) {
        self.overlayOrientationChanged = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:DCImageViewerUnderlyingGeometryDidChangeNotification
                              object:nil];
        });
    }
}

- (void)dc_dismissViewerAnimated:(BOOL)animated {
    if (self.overlayPresentationActive) {
        if (self.overlayDismissInProgress) return;
        self.overlayDismissInProgress = YES;

        UIWindow *overlayWindow = self.overlayPresentationWindow;
        UIWindow *previousKeyWindow = self.overlayPreviousKeyWindow;
        CGFloat currentOffset = self.imageView.transform.ty;
        BOOL gestureDriven = currentOffset > 0.5f;
        NSTimeInterval duration = animated ? 0.18 : 0.0;
        UIViewAnimationOptions animationOptions = UIViewAnimationOptionCurveEaseOut;
        CGFloat targetOffset = 0.0f;

        if (animated && gestureDriven) {
            targetOffset = MAX(currentOffset,
                               self.view.bounds.size.height + 40.0f);

            CGFloat remainingDistance = MAX(0.0f, targetOffset - currentOffset);
            CGFloat releaseVelocity = MAX(self.overlayDismissVelocityY, 700.0f);
            duration = remainingDistance / releaseVelocity;
            duration = MIN(0.45, MAX(0.08, duration));
            animationOptions = UIViewAnimationOptionCurveLinear |
                               UIViewAnimationOptionBeginFromCurrentState;
        }

        void (^animations)(void) = ^{
            self.overlayDimmingView.alpha = 0.0f;
            self.navBar.alpha = 0.0f;
            self.messageOverlay.alpha = 0.0f;
            if (gestureDriven) {
                self.imageView.transform = CGAffineTransformMakeTranslation(0.0f, targetOffset);
            } else {
                self.view.alpha = 0.0f;
            }
        };

        void (^completion)(BOOL) = ^(BOOL finished) {
            // Remove the landscape-capable viewer window before handing rotation
            // authority back to the portrait-only phone UI. Keeping this window
            // visible during the handoff lets old UIKit continue using its
            // orientation policy even after the app window becomes key.
            self.overlayPresentationActive = NO;
            overlayWindow.hidden = YES;
            overlayWindow.rootViewController = nil;

            if (previousKeyWindow) {
                [previousKeyWindow makeKeyWindow];
            }

            // Return key-window ownership before forcing the phone orientation so
            // UIKit applies the transition to the application's real root hierarchy.
            [self dc_restoreStatusBarState];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self dc_forceDeviceOrientationToPortraitForWindow:previousKeyWindow completion:^{
                    [self dc_finishViewerDismissalCleanup];

                    self.overlayDismissInProgress = NO;
                    self.overlayDismissVelocityY = 0.0f;
                    self.overlayDimmingView = nil;
                    self.overlayPreviousKeyWindow = nil;
                    self.overlayPresentationWindow = nil;
                }];
            });
        };

        if (duration > 0.0) {
            [UIView animateWithDuration:duration
                                  delay:0.0
                                options:animationOptions
                             animations:animations
                             completion:completion];
        } else {
            animations();
            completion(YES);
        }
        return;
    }

    __weak DCImageViewController *weakSelf = self;
    [self dismissViewControllerAnimated:animated completion:^{
        [weakSelf dc_finishViewerDismissalCleanup];
    }];
}

- (IBAction)done:(id)sender {
    [self dc_dismissViewerAnimated:YES];
}

- (IBAction)presentShareSheet:(id)sender {
    if (NSClassFromString(@"UIActivityViewController")) {
        NSArray *itemsToShare = @[self.imageView.image];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc]
            initWithActivityItems:itemsToShare
            applicationActivities:nil];
        [self presentViewController:activityVC animated:YES completion:nil];
    } else {
        UIActionSheet *sheet = [[UIActionSheet alloc]
            initWithTitle:nil
                 delegate:self
        cancelButtonTitle:@"Cancel"
   destructiveButtonTitle:nil
        otherButtonTitles:@"Save to Camera Roll", @"Copy Image", @"Print", @"Email", @"Message", nil];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            UIView *shareView = [self.share valueForKey:@"view"];
            if (shareView) {
                [sheet showFromRect:shareView.bounds inView:shareView animated:YES];
            } else {
                [sheet showInView:self.view];
            }
        } else {
            [sheet showInView:self.view];
        }
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    switch (buttonIndex) {
        case 0:
            UIImageWriteToSavedPhotosAlbum(self.imageView.image, self,
                @selector(image:didFinishSavingWithError:contextInfo:), nil);
            break;
        case 1:
            [[UIPasteboard generalPasteboard] setImage:self.imageView.image];
            [DCTools alert:@"Copied" withMessage:@"Image copied to clipboard."];
            break;
        case 2:
            if ([UIPrintInteractionController isPrintingAvailable]) {
                UIPrintInteractionController *printer = [UIPrintInteractionController sharedPrintController];
                UIPrintInfo *printInfo = [UIPrintInfo printInfo];
                printInfo.outputType = UIPrintInfoOutputPhoto;
                printer.printInfo = printInfo;
                printer.printingItem = self.imageView.image;
                [printer presentAnimated:YES completionHandler:nil];
            } else {
                [DCTools alert:@"Unavailable" withMessage:@"Printing is not available on this device."];
            }
            break;
        case 3:
            if ([MFMailComposeViewController canSendMail]) {
                MFMailComposeViewController *mail = [MFMailComposeViewController new];
                mail.mailComposeDelegate = self;
                NSData *imageData = UIImagePNGRepresentation(self.imageView.image);
                [mail addAttachmentData:imageData mimeType:@"image/png" fileName:@"image.png"];
                [self presentViewController:mail animated:YES completion:nil];
            } else {
                [DCTools alert:@"Unavailable" withMessage:@"Mail is not configured on this device."];
            }
            break;
        case 4:
            if ([MFMessageComposeViewController canSendText] &&
                [MFMessageComposeViewController canSendAttachments]) {
                MFMessageComposeViewController *message = [MFMessageComposeViewController new];
                message.messageComposeDelegate = self;
                NSData *imageData = UIImagePNGRepresentation(self.imageView.image);
                [message addAttachmentData:imageData typeIdentifier:@"public.png" filename:@"image.png"];
                [self presentViewController:message animated:YES completion:nil];
            } else {
                [DCTools alert:@"Unavailable" withMessage:@"Messages is not available on this device."];
            }
            break;
        default:
            break;
    }
}

- (void)mailComposeController:(MFMailComposeViewController *)controller
          didFinishWithResult:(MFMailComposeResult)result
                        error:(NSError *)error {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)messageComposeViewController:(MFMessageComposeViewController *)controller
                  didFinishWithResult:(MessageComposeResult)result {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        [DCTools alert:@"Save Failed" withMessage:error.localizedDescription];
    } else {
        [DCTools alert:@"Saved" withMessage:@"Image saved to camera roll."];
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.decodeGeneration++;
    [self.downloadOperation cancel];
    self.downloadOperation = nil;
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    if (self.fullResolutionPath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.fullResolutionPath error:nil];
    }
    [self dc_finishViewerDismissalCleanup];
}

@end
