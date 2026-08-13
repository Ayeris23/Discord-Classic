//
//  DCChatGifAttachment.m
//  Discord Classic
//
//  Created by Ayeris on 3/12/26.
//  Copyright (c) 2026 bag.xml. All rights reserved.
//

#import "DCChatGifAttachment.h"
#import "DCChatMediaManager.h"
#import "DCServerCommunicator.h"
#import <SDWebImage/UIImageView+WebCache.h>

@interface DCChatGifAttachment ()
@property (strong, nonatomic) UIView *dimOverlay;
@property (strong, nonatomic) UIActivityIndicatorView *spinner;
@property (strong, nonatomic) id<SDWebImageOperation> thumbnailLoadOperation;
@property (assign, nonatomic) BOOL thumbnailLoadFailed;
@property (assign, nonatomic) BOOL thumbnailLoadingAllowed;
@property (assign, nonatomic) BOOL thumbnailPlaceholderActive;
@end

@implementation DCChatGifAttachment

- (void)awakeFromNib {
    [super awakeFromNib];
    
    // Dim overlay
    self.dimOverlay = [[UIView alloc] initWithFrame:self.bounds];
    self.dimOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4f];
    self.dimOverlay.hidden = YES;
    self.dimOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:self.dimOverlay];
    
    // Spinner: also doubles as the static-thumbnail loader while the GIF is idle.
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.spinner.hidden = YES;
    [self addSubview:self.spinner];
    
    // Make sure badge is on top
    [self bringSubviewToFront:self.gifBadge];
    
    // Tap gesture
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    self.userInteractionEnabled = YES;
    [self addGestureRecognizer:tap];
}

- (void)dc_updateIdleLoadingState {
    if (self.isLoading) return;
    BOOL canLoad = !DCServerCommunicator.sharedInstance.dataSaver;
    BOOL shouldSpin = (!self.staticThumbnail &&
                       self.thumbnailURL &&
                       self.window &&
                       canLoad &&
                       self.thumbnailPlaceholderActive &&
                       !self.thumbnailLoadFailed);
    self.dimOverlay.hidden = YES;
    if (shouldSpin) {
        self.spinner.hidden = NO;
        [self.spinner startAnimating];
        self.gifBadge.hidden = YES;
    } else {
        [self.spinner stopAnimating];
        self.spinner.hidden = YES;
        self.gifBadge.hidden = (self.staticThumbnail == nil);
    }
}

- (void)dc_presentStaticThumbnail:(UIImage *)image
                         fromCache:(BOOL)fromCache {
    if (!image) return;

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    self.staticThumbnail = image;
    self.gifThumbnail.image = image;
    double milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    if (milliseconds >= 8.0) {
        size_t width = image.CGImage ? CGImageGetWidth(image.CGImage) : 0;
        size_t height = image.CGImage ? CGImageGetHeight(image.CGImage) : 0;
        NSLog(@"[MediaPerf] GIF present %.1fms %lux%lu cache:%d",
              milliseconds,
              (unsigned long)width,
              (unsigned long)height,
              fromCache ? 1 : 0);
    }
}

- (void)dc_startThumbnailLoadIfNeededAllowLoading:(BOOL)allowLoading {
    self.thumbnailLoadingAllowed = allowLoading;
    self.thumbnailPlaceholderActive = YES;

    if (!self.thumbnailURL || self.staticThumbnail ||
        self.thumbnailLoadFailed || !self.window ||
        DCServerCommunicator.sharedInstance.dataSaver) {
        [self dc_updateIdleLoadingState];
        return;
    }

    CGSize displaySize = self.bounds.size;
    if (!allowLoading) {
        [self.thumbnailLoadOperation cancel];
        self.thumbnailLoadOperation = nil;

        UIImage *hotImage = [[DCChatMediaManager sharedManager]
            memoryThumbnailForURL:self.thumbnailURL
                      displaySize:displaySize];
        if (hotImage) {
            self.thumbnailLoadFailed = NO;
            [self dc_presentStaticThumbnail:hotImage fromCache:YES];
        }
        [self dc_updateIdleLoadingState];
        return;
    }

    if (self.thumbnailLoadOperation) {
        [self dc_updateIdleLoadingState];
        return;
    }

    NSURL *representedURL = self.thumbnailURL;
    __weak DCChatGifAttachment *weakSelf = self;
    self.thumbnailLoadOperation = [[DCChatMediaManager sharedManager]
        loadThumbnailForURL:representedURL
                displaySize:displaySize
                 completion:^(UIImage *image, NSError *error, BOOL fromCache) {
        DCChatGifAttachment *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.thumbnailLoadOperation = nil;
        if (![strongSelf.thumbnailURL isEqual:representedURL] || !strongSelf.window) return;

        if (image) {
            strongSelf.thumbnailLoadFailed = NO;
            [strongSelf dc_presentStaticThumbnail:image fromCache:fromCache];
        } else {
            strongSelf.thumbnailLoadFailed = YES;
            if (error) {
                NSLog(@"[MediaBudget] GIF thumbnail failed %@: %@", representedURL, error);
            }
        }
        [strongSelf dc_updateIdleLoadingState];
    }];
    [self dc_updateIdleLoadingState];
}

- (void)prepareForDisplay {
    [self prepareForDisplayAllowLoading:YES];
}

- (void)prepareForDisplayAllowLoading:(BOOL)allowLoading {
    self.dimOverlay.frame = self.bounds;
    self.spinner.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    self.gifThumbnail.image = self.staticThumbnail;
    [self dc_updateIdleLoadingState];
    [self bringSubviewToFront:self.dimOverlay];
    [self bringSubviewToFront:self.spinner];
    [self bringSubviewToFront:self.gifBadge];
    [self dc_startThumbnailLoadIfNeededAllowLoading:allowLoading];
}

- (void)handleTap {
    if (self.isLoading || !self.staticThumbnail) return;
    if (self.gifThumbnail.image != self.staticThumbnail) {
        // Already playing, stop it
        [self stopPlayback];
        return;
    }
    
    self.isLoading = YES;
    self.dimOverlay.hidden = NO;
    self.spinner.hidden = NO;
    [self.spinner startAnimating];
    self.gifBadge.hidden = YES;
    
    [[SDWebImageManager sharedManager] downloadImageWithURL:self.gifURL
                                                    options:SDWebImageCacheMemoryOnly
                                                   progress:nil
                                                  completed:^(UIImage *image, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            self.dimOverlay.hidden = YES;
            self.spinner.hidden = YES;
            [self.spinner stopAnimating];
            
            if (image && finished && self.window) {
                self.gifThumbnail.image = image;
            } else {
                self.gifBadge.hidden = NO;
            }
        });
    }];
}

- (void)stopPlayback {
    self.gifThumbnail.image = self.staticThumbnail;
    self.dimOverlay.hidden = YES;
    self.spinner.hidden = YES;
    [self.spinner stopAnimating];
    self.gifBadge.hidden = (self.staticThumbnail == nil);
    self.isLoading = NO;
}

- (void)releaseThumbnailForResidency {
    [self.thumbnailLoadOperation cancel];
    self.thumbnailLoadOperation = nil;
    self.thumbnailLoadFailed = NO;
    self.thumbnailLoadingAllowed = NO;
    self.thumbnailPlaceholderActive = NO;
    [self stopPlayback];
    self.staticThumbnail = nil;
    self.gifThumbnail.image = nil;
    [self dc_updateIdleLoadingState];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self releaseThumbnailForResidency];
    }

    /*
     * Window attachment alone is not permission to touch disk/network while
     * the table is flinging.  The chat controller explicitly hydrates this
     * view according to the current scroll policy.
     */
    [self dc_updateIdleLoadingState];
}

@end
