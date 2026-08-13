#include "UILazyImageView.h"
#import "DCChatMediaManager.h"
#import "DCServerCommunicator.h"

@interface UILazyImageView ()
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) id<SDWebImageOperation> thumbnailLoadOperation;
@property (nonatomic, assign) CGSize requestedDisplaySize;
@property (nonatomic, assign) BOOL thumbnailLoadFailed;
@property (nonatomic, assign) BOOL thumbnailLoadingAllowed;
@property (nonatomic, assign) BOOL thumbnailPlaceholderActive;
@end

@implementation UILazyImageView

- (void)dc_commonInit {
    if (self.loadingSpinner) return;

    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    spinner.hidesWhenStopped = YES;
    spinner.userInteractionEnabled = NO;
    [self addSubview:spinner];
    self.loadingSpinner = spinner;
}

- (id)init {
    self = [super init];
    if (self) {
        [self dc_commonInit];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self dc_commonInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self dc_commonInit];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.loadingSpinner.center =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    [self bringSubviewToFront:self.loadingSpinner];
}

- (void)dc_updateLoadingState {
    BOOL canLoad = !DCServerCommunicator.sharedInstance.dataSaver;
    BOOL shouldSpin = (self.image == nil &&
                       self.imageURL != nil &&
                       self.window != nil &&
                       canLoad &&
                       self.thumbnailPlaceholderActive &&
                       !self.thumbnailLoadFailed);
    if (shouldSpin) {
        self.loadingSpinner.hidden = NO;
        [self.loadingSpinner startAnimating];
    } else {
        [self.loadingSpinner stopAnimating];
    }
}

- (void)setImage:(UIImage *)image {
    [super setImage:image];
    [self dc_updateLoadingState];
}

- (void)setImageURL:(NSURL *)imageURL {
    if ((_imageURL == imageURL) || [_imageURL isEqual:imageURL]) {
        return;
    }

    [self.thumbnailLoadOperation cancel];
    self.thumbnailLoadOperation = nil;
    _imageURL = imageURL;
    self.thumbnailLoadFailed = NO;
    [super setImage:nil];
    [self dc_updateLoadingState];
}

- (void)dc_presentChatThumbnail:(UIImage *)image
                         fromCache:(BOOL)fromCache {
    if (!image) return;

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    self.image = image;
    double milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    if (milliseconds >= 8.0) {
        size_t width = image.CGImage ? CGImageGetWidth(image.CGImage) : 0;
        size_t height = image.CGImage ? CGImageGetHeight(image.CGImage) : 0;
        NSLog(@"[MediaPerf] image present %.1fms %lux%lu cache:%d",
              milliseconds,
              (unsigned long)width,
              (unsigned long)height,
              fromCache ? 1 : 0);
    }
}

- (void)prepareChatThumbnailForDisplaySize:(CGSize)displaySize {
    [self prepareChatThumbnailForDisplaySize:displaySize allowLoading:YES];
}

- (void)prepareChatThumbnailForDisplaySize:(CGSize)displaySize
                              allowLoading:(BOOL)allowLoading {
    self.requestedDisplaySize = displaySize;
    self.thumbnailLoadingAllowed = allowLoading;
    self.thumbnailPlaceholderActive = YES;

    if (!self.imageURL || self.image || self.thumbnailLoadFailed ||
        DCServerCommunicator.sharedInstance.dataSaver) {
        [self dc_updateLoadingState];
        return;
    }

    if (!allowLoading) {
        [self.thumbnailLoadOperation cancel];
        self.thumbnailLoadOperation = nil;

        UIImage *hotImage = [[DCChatMediaManager sharedManager]
            memoryThumbnailForURL:self.imageURL
                      displaySize:displaySize];
        if (hotImage) {
            self.thumbnailLoadFailed = NO;
            [self dc_presentChatThumbnail:hotImage fromCache:YES];
        }
        [self dc_updateLoadingState];
        return;
    }

    if (self.thumbnailLoadOperation) {
        [self dc_updateLoadingState];
        return;
    }

    NSURL *representedURL = self.imageURL;
    __weak UILazyImageView *weakSelf = self;
    self.thumbnailLoadOperation = [[DCChatMediaManager sharedManager]
        loadThumbnailForURL:representedURL
                displaySize:displaySize
                 completion:^(UIImage *image, NSError *error, BOOL fromCache) {
        UILazyImageView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.thumbnailLoadOperation = nil;
        if (![strongSelf.imageURL isEqual:representedURL]) return;

        if (image) {
            strongSelf.thumbnailLoadFailed = NO;
            [strongSelf dc_presentChatThumbnail:image fromCache:fromCache];
        } else {
            strongSelf.thumbnailLoadFailed = YES;
            [strongSelf dc_updateLoadingState];
            if (error) {
                NSLog(@"[MediaBudget] thumbnail failed %@: %@", representedURL, error);
            }
        }
    }];
    [self dc_updateLoadingState];
}

- (void)releaseChatThumbnailForResidency {
    [self.thumbnailLoadOperation cancel];
    self.thumbnailLoadOperation = nil;
    self.thumbnailLoadFailed = NO;
    self.thumbnailLoadingAllowed = NO;
    self.thumbnailPlaceholderActive = NO;
    [super setImage:nil];
    [self dc_updateLoadingState];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self releaseChatThumbnailForResidency];
    }

    /*
     * Do not auto-start disk/network work merely because UIKit attached a new
     * cell to the window.  DCChatViewController decides whether the current
     * scroll velocity permits hydration and explicitly calls prepare...
     */
    [self dc_updateLoadingState];
}

@end
