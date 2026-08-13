//
//  DCChatVideoAttachment.m
//  Discord Classic
//
//  Created by Toru the Red Fox on 25/10/22.
//  Copyright (c) 2022 Toru the Red Fox. All rights reserved.
//

#import "DCChatVideoAttachment.h"
#import "DCChatMediaManager.h"
#import "DCServerCommunicator.h"

@interface DCChatVideoAttachment ()
@property (strong, nonatomic) UIActivityIndicatorView *loadingSpinner;
@property (assign, nonatomic) BOOL displayHierarchyBuilt;
@property (strong, nonatomic) id<SDWebImageOperation> thumbnailLoadOperation;
@property (assign, nonatomic) BOOL thumbnailLoadingAllowed;
@property (assign, nonatomic) BOOL thumbnailPlaceholderActive;
@end

@implementation DCChatVideoAttachment

- (void)dc_applyContainerConfiguration {
    self.backgroundColor = [UIColor blackColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

- (void)dc_buildDisplayHierarchyIfNeeded {
    if (self.displayHierarchyBuilt && self.thumbnail && self.playButton && self.videoWarning) {
        return;
    }

    // Build UIKit presentation lazily; metadata already carries stable row geometry.
    self.displayHierarchyBuilt = YES;
    [self dc_applyContainerConfiguration];

    if (!self.thumbnail) {
        UIImageView *thumbnail = [[UIImageView alloc] initWithFrame:self.bounds];
        thumbnail.contentMode = UIViewContentModeScaleAspectFit;
        thumbnail.userInteractionEnabled = NO;
        thumbnail.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:thumbnail];
        self.thumbnail = thumbnail;
    }

    if (!self.playButton) {
        UIImageView *playButton = [[UIImageView alloc] initWithFrame:self.bounds];
        playButton.contentMode = UIViewContentModeCenter;
        playButton.userInteractionEnabled = NO;
        playButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        playButton.image = [UIImage imageNamed:@"PLVideoOverlayPlay.png"];
        [self addSubview:playButton];
        self.playButton = playButton;
    }

    if (!self.videoWarning) {
        UILabel *warning = [[UILabel alloc] initWithFrame:self.bounds];
        warning.backgroundColor = [UIColor clearColor];
        warning.textColor = [UIColor whiteColor];
        warning.textAlignment = NSTextAlignmentCenter;
        warning.font = [UIFont fontWithName:@"HelveticaNeue" size:16.0f] ?: [UIFont systemFontOfSize:16.0f];
        warning.userInteractionEnabled = NO;
        warning.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:warning];
        self.videoWarning = warning;
    }

    if (!self.loadingSpinner) {
        UIActivityIndicatorView *spinner =
            [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        spinner.hidesWhenStopped = YES;
        spinner.userInteractionEnabled = NO;
        spinner.autoresizingMask =
            UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self addSubview:spinner];
        self.loadingSpinner = spinner;
    }

    self.thumbnail.image = self.thumbnailImage;
    self.videoWarning.text = self.warningText ?: @"";
    self.videoWarning.hidden = (self.warningText.length == 0);
}

- (void)dc_updateLoadingState {
    if (!self.displayHierarchyBuilt) return;

    BOOL hasThumbnail = (self.thumbnailImage != nil || self.thumbnail.image != nil);
    BOOL hasWarning = (self.warningText.length > 0) || !self.videoWarning.hidden;
    BOOL canLoad = !DCServerCommunicator.sharedInstance.dataSaver;
    BOOL shouldSpin = (!hasThumbnail && !hasWarning && self.window != nil &&
                       canLoad && self.thumbnailPlaceholderActive);

    self.playButton.hidden = !hasThumbnail;
    if (shouldSpin) {
        self.loadingSpinner.hidden = NO;
        [self.loadingSpinner startAnimating];
    } else {
        [self.loadingSpinner stopAnimating];
    }
}

- (void)dc_presentThumbnailImage:(UIImage *)image
                        fromCache:(BOOL)fromCache {
    if (!image) return;

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    self.thumbnailImage = image;
    double milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    if (milliseconds >= 8.0) {
        size_t width = image.CGImage ? CGImageGetWidth(image.CGImage) : 0;
        size_t height = image.CGImage ? CGImageGetHeight(image.CGImage) : 0;
        NSLog(@"[MediaPerf] video present %.1fms %lux%lu cache:%d",
              milliseconds,
              (unsigned long)width,
              (unsigned long)height,
              fromCache ? 1 : 0);
    }
}

- (void)dc_startThumbnailLoadIfNeededAllowLoading:(BOOL)allowLoading {
    self.thumbnailLoadingAllowed = allowLoading;
    self.thumbnailPlaceholderActive = YES;

    if (!self.thumbnailURL || self.thumbnailImage ||
        self.warningText.length > 0 || !self.window ||
        DCServerCommunicator.sharedInstance.dataSaver) {
        [self dc_updateLoadingState];
        return;
    }

    CGSize displaySize = self.bounds.size;
    if (!allowLoading) {
        [self.thumbnailLoadOperation cancel];
        self.thumbnailLoadOperation = nil;
        self.thumbnailLoading = NO;

        UIImage *hotImage = [[DCChatMediaManager sharedManager]
            memoryThumbnailForURL:self.thumbnailURL
                      displaySize:displaySize];
        if (hotImage) {
            [self dc_presentThumbnailImage:hotImage fromCache:YES];
        }
        [self dc_updateLoadingState];
        return;
    }

    if (self.thumbnailLoadOperation) {
        [self dc_updateLoadingState];
        return;
    }

    NSURL *representedURL = self.thumbnailURL;
    __weak DCChatVideoAttachment *weakSelf = self;
    self.thumbnailLoading = YES;
    self.thumbnailLoadOperation = [[DCChatMediaManager sharedManager]
        loadThumbnailForURL:representedURL
                displaySize:displaySize
                 completion:^(UIImage *image, NSError *error, BOOL fromCache) {
        DCChatVideoAttachment *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.thumbnailLoadOperation = nil;
        strongSelf.thumbnailLoading = NO;
        if (![strongSelf.thumbnailURL isEqual:representedURL] || !strongSelf.window) return;

        if (image) {
            [strongSelf dc_presentThumbnailImage:image fromCache:fromCache];
        } else {
            strongSelf.warningText = @"Unsupported Attachment";
            if (error) {
                NSLog(@"[MediaBudget] video thumbnail failed %@: %@", representedURL, error);
            }
        }
        [strongSelf dc_updateLoadingState];
    }];
    [self dc_updateLoadingState];
}

- (id)initMetadataOnly {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self dc_applyContainerConfiguration];
        self.displayHierarchyBuilt = NO;
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self dc_applyContainerConfiguration];
        [self dc_buildDisplayHierarchyIfNeeded];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    self.displayHierarchyBuilt = YES;
    [self dc_applyContainerConfiguration];
    self.thumbnailImage = self.thumbnail.image;
    if (!self.warningText.length && !self.videoWarning.hidden) {
        self.warningText = self.videoWarning.text;
    }
    [self dc_buildDisplayHierarchyIfNeeded];
}

- (void)setThumbnailImage:(UIImage *)thumbnailImage {
    _thumbnailImage = thumbnailImage;
    if (self.thumbnail) {
        self.thumbnail.image = thumbnailImage;
    }
    [self dc_updateLoadingState];
}

- (void)setWarningText:(NSString *)warningText {
    _warningText = [warningText copy];
    if (self.videoWarning) {
        self.videoWarning.text = _warningText ?: @"";
        self.videoWarning.hidden = (_warningText.length == 0);
    }
    [self dc_updateLoadingState];
}

- (void)prepareForDisplay {
    [self prepareForDisplayAllowLoading:YES];
}

- (void)prepareForDisplayAllowLoading:(BOOL)allowLoading {
    [self dc_buildDisplayHierarchyIfNeeded];
    self.thumbnail.frame = self.bounds;
    self.thumbnail.image = self.thumbnailImage;
    self.backgroundColor = self.thumbnailImage
        ? [UIColor clearColor]
        : [UIColor blackColor];
    self.videoWarning.frame = self.bounds;
    self.videoWarning.text = self.warningText ?: @"";
    self.videoWarning.hidden = (self.warningText.length == 0);
    self.videoWarning.textAlignment = NSTextAlignmentCenter;
    self.loadingSpinner.center =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    [self dc_updateLoadingState];
    [self bringSubviewToFront:self.playButton];
    [self bringSubviewToFront:self.loadingSpinner];
    [self bringSubviewToFront:self.videoWarning];
    [self dc_startThumbnailLoadIfNeededAllowLoading:allowLoading];
}

- (void)releaseThumbnailForResidency {
    [self.thumbnailLoadOperation cancel];
    self.thumbnailLoadOperation = nil;
    self.thumbnailLoading = NO;
    self.thumbnailLoadingAllowed = NO;
    self.thumbnailPlaceholderActive = NO;
    self.thumbnailImage = nil;
    self.thumbnail.image = nil;
    [self dc_updateLoadingState];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self releaseThumbnailForResidency];
    }

    /* The table controller owns hydration timing; attaching this view to the
     * window must not start disk/network work during a fling. */
    [self dc_updateLoadingState];
}

@end
