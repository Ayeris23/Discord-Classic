//
//  DCChatMediaManager.m
//  Discord Classic
//

#import "DCChatMediaManager.h"
#import "DCResourceManager.h"
#import "SDImageCache.h"
#import "SDWebImageDownloader.h"
#import <ImageIO/ImageIO.h>
#include <math.h>

NSString * const DCChatMediaPurgeVisibleNotification = @"DCChatMediaPurgeVisibleNotification";
NSString * const DCChatMediaRehydrateVisibleNotification = @"DCChatMediaRehydrateVisibleNotification";

static const NSUInteger DCChatMediaMegabyte = 1024U * 1024U;
// Private downloader option used by the chat-media raw-data path.
static const NSUInteger DCSDWebImageDownloaderAvoidDecode = (1U << 8);

static NSUInteger DCDecodedImageCost(UIImage *image) {
    if (!image || !image.CGImage) return 0;

    size_t bytesPerRow = CGImageGetBytesPerRow(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (bytesPerRow > 0 && height > 0) {
        return (NSUInteger)(bytesPerRow * height);
    }

    size_t width = CGImageGetWidth(image.CGImage);
    if (width == 0 || height == 0) return 0;
    return (NSUInteger)(width * height * 4U);
}

static BOOL DCChatMediaHostSupportsSizing(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *lower = [host lowercaseString];
    return [lower hasSuffix:@"discordapp.net"] ||
           [lower hasSuffix:@"discordapp.com"] ||
           [lower hasSuffix:@"discord.com"];
}

/*
 * iOS 5/6 predates NSURLComponents.  Rebuild only the query string while
 * preserving Discord's signed ex/is/hm parameters and any other opaque fields.
 */
static NSURL *DCChatThumbnailURL(NSURL *sourceURL, CGSize displaySize) {
    if (!sourceURL) return nil;
    if (!DCChatMediaHostSupportsSizing(sourceURL.host)) return sourceURL;

    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0.0f) scale = 1.0f;

    NSInteger pixelWidth = (NSInteger)ceil(MAX(1.0f, displaySize.width * scale));
    NSInteger pixelHeight = (NSInteger)ceil(MAX(1.0f, displaySize.height * scale));

    /* A malformed cell should never accidentally ask Discord for a giant
     * bitmap.  Current legacy iPad Retina presentation tops out around 1404px. */
    pixelWidth = MIN(pixelWidth, 1600);
    pixelHeight = MIN(pixelHeight, 1600);

    NSString *absolute = sourceURL.absoluteString;
    NSRange question = [absolute rangeOfString:@"?"];
    NSString *base = question.location == NSNotFound
        ? absolute
        : [absolute substringToIndex:question.location];
    NSString *query = question.location == NSNotFound
        ? @""
        : [absolute substringFromIndex:question.location + 1];

    NSMutableArray *parts = [NSMutableArray array];
    BOOL hasFormat = NO;
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound
            ? part
            : [part substringToIndex:equals.location];
        NSString *lowerKey = [key lowercaseString];
        if ([lowerKey isEqualToString:@"width"] ||
            [lowerKey isEqualToString:@"height"]) {
            continue;
        }
        if ([lowerKey isEqualToString:@"format"]) {
            [parts addObject:@"format=png"];
            hasFormat = YES;
            continue;
        }
        [parts addObject:part];
    }

    if (!hasFormat) [parts addObject:@"format=png"];
    [parts addObject:[NSString stringWithFormat:@"width=%ld", (long)pixelWidth]];
    [parts addObject:[NSString stringWithFormat:@"height=%ld", (long)pixelHeight]];

    NSString *rebuilt = [NSString stringWithFormat:@"%@?%@",
                         base,
                         [parts componentsJoinedByString:@"&"]];
    return [NSURL URLWithString:rebuilt];
}

static UIImage *DCChatThumbnailFromData(NSData *data, CGSize displaySize) {
    if (data.length == 0) return nil;

    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0.0f) scale = 1.0f;
    CGFloat maxPixelFloat = MAX(displaySize.width, displaySize.height) * scale;
    NSUInteger maxPixel = (NSUInteger)ceil(MAX(1.0f, MIN(maxPixelFloat, 1600.0f)));

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    NSDictionary *options = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
        (NSString *)kCGImageSourceShouldCache: @YES
    };

    CGImageRef thumbnailRef =
        CGImageSourceCreateThumbnailAtIndex(source, 0,
                                            (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumbnailRef) return nil;

    UIImage *thumbnail = [UIImage imageWithCGImage:thumbnailRef
                                             scale:scale
                                       orientation:UIImageOrientationUp];
    CGImageRelease(thumbnailRef);
    return thumbnail;
}

@interface DCChatMediaLoadOperation : NSObject <SDWebImageOperation>
@property (atomic, assign, getter=isCancelled) BOOL cancelled;
@property (strong, nonatomic) NSOperation *cacheOperation;
@property (strong, nonatomic) id<SDWebImageOperation> downloadOperation;
@end

@implementation DCChatMediaLoadOperation
- (void)cancel {
    self.cancelled = YES;
    [self.cacheOperation cancel];
    [self.downloadOperation cancel];
    self.cacheOperation = nil;
    self.downloadOperation = nil;
}
@end

@interface DCChatMediaManager ()
@property (strong, nonatomic) SDImageCache *diskCache;
@property (strong, nonatomic) SDWebImageDownloader *downloader;
@property (strong, nonatomic) NSMutableDictionary *memoryImages;
@property (strong, nonatomic) NSMutableDictionary *memoryCosts;
@property (strong, nonatomic) NSMutableArray *lruKeys;
@property (assign, nonatomic) NSUInteger mutableMemoryCost;
@property (assign, nonatomic) NSUInteger entryLimit;
@property (assign, nonatomic) BOOL memoryCachingEnabled;
@property (assign, nonatomic) CFAbsoluteTime lastTrimLogTime;
@end

@implementation DCChatMediaManager

+ (instancetype)sharedManager {
    static DCChatMediaManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[DCChatMediaManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _memoryImages = [NSMutableDictionary dictionary];
    _memoryCosts = [NSMutableDictionary dictionary];
    _lruKeys = [NSMutableArray array];
    _mutableMemoryCost = 0;
    _memoryCachingEnabled = YES;

    DCResourceManager *resources = [DCResourceManager sharedManager];

    // Byte cost is authoritative; retain only a broad count guard for tiny thumbnails.
    NSUInteger tinyObjectGuard =
        MAX(48U, resources.chatThumbnailMemoryBudget / (64U * 1024U));
    _entryLimit = MIN(192U, tinyObjectGuard);

    _diskCache = [[SDImageCache alloc] initWithNamespace:@"DiscordClassicChatThumbnails"];
    _diskCache.shouldCacheImagesInMemory = NO;
    _diskCache.shouldDecompressImages = YES;
    _diskCache.maxCacheSize = MAX(64U * DCChatMediaMegabyte,
                                  MIN(256U * DCChatMediaMegabyte,
                                      resources.chatThumbnailMemoryBudget * 8U));

    _downloader = [[SDWebImageDownloader alloc] init];
    _downloader.shouldDecompressImages = NO;
    switch (resources.memoryClass) {
        case DCDeviceMemoryClass256MB:
            _downloader.maxConcurrentDownloads = 1;
            break;
        case DCDeviceMemoryClass512MB:
            _downloader.maxConcurrentDownloads = 2;
            break;
        case DCDeviceMemoryClass1GB:
        case DCDeviceMemoryClass2GBPlus:
            _downloader.maxConcurrentDownloads = 3;
            break;
        default:
            _downloader.maxConcurrentDownloads = 1;
            break;
    }

    [self logMemoryStateWithReason:@"initialized"];
    return self;
}

- (NSUInteger)memoryBudget {
    return [DCResourceManager sharedManager].chatThumbnailMemoryBudget;
}

- (NSUInteger)currentMemoryCost {
    return self.mutableMemoryCost;
}

- (NSUInteger)memoryEntryCount {
    return self.memoryImages.count;
}

- (UIImage *)dc_memoryImageForKey:(NSString *)key {
    UIImage *image = [self.memoryImages objectForKey:key];
    if (!image) return nil;

    [self.lruKeys removeObject:key];
    [self.lruKeys addObject:key];
    return image;
}

- (void)dc_storeMemoryImage:(UIImage *)image forKey:(NSString *)key {
    if (!image || key.length == 0 || !self.memoryCachingEnabled) return;

    NSUInteger cost = DCDecodedImageCost(image);
    if (cost == 0 || cost > self.memoryBudget) {
        return;
    }

    NSNumber *oldCost = [self.memoryCosts objectForKey:key];
    if (oldCost) {
        self.mutableMemoryCost -= MIN(self.mutableMemoryCost, [oldCost unsignedIntegerValue]);
    }

    [self.memoryImages setObject:image forKey:key];
    [self.memoryCosts setObject:@(cost) forKey:key];
    [self.lruKeys removeObject:key];
    [self.lruKeys addObject:key];
    self.mutableMemoryCost += cost;

    NSUInteger beforeTrim = self.mutableMemoryCost;
    NSUInteger beforeCount = self.memoryImages.count;
    while ((self.mutableMemoryCost > self.memoryBudget ||
            self.memoryImages.count > self.entryLimit) &&
           self.lruKeys.count > 0) {
        NSString *oldest = [self.lruKeys objectAtIndex:0];
        [self.lruKeys removeObjectAtIndex:0];
        NSNumber *evictedCost = [self.memoryCosts objectForKey:oldest];
        if (evictedCost) {
            self.mutableMemoryCost -= MIN(self.mutableMemoryCost,
                                          [evictedCost unsignedIntegerValue]);
        }
        [self.memoryCosts removeObjectForKey:oldest];
        [self.memoryImages removeObjectForKey:oldest];
    }

    if (beforeTrim != self.mutableMemoryCost || beforeCount != self.memoryImages.count) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (self.lastTrimLogTime <= 0.0 || now - self.lastTrimLogTime >= 1.0) {
            self.lastTrimLogTime = now;
            uint64_t resident = [[DCResourceManager sharedManager]
                currentResidentMemoryBytes];
            NSLog(@"[MediaBudget] trim %.2fMB/%lu -> %.2fMB/%lu budget %.1fMB resident %.1fMB",
                  (double)beforeTrim / (double)DCChatMediaMegabyte,
                  (unsigned long)beforeCount,
                  (double)self.mutableMemoryCost / (double)DCChatMediaMegabyte,
                  (unsigned long)self.memoryImages.count,
                  (double)self.memoryBudget / (double)DCChatMediaMegabyte,
                  (double)resident / (double)DCChatMediaMegabyte);
        }
    }
}

- (UIImage *)memoryThumbnailForURL:(NSURL *)sourceURL
                       displaySize:(CGSize)displaySize {
    if (!sourceURL || displaySize.width <= 0.0f || displaySize.height <= 0.0f) {
        return nil;
    }

    NSURL *requestURL = DCChatThumbnailURL(sourceURL, displaySize);
    NSString *key = requestURL.absoluteString;
    if (key.length == 0) return nil;
    return [self dc_memoryImageForKey:key];
}

- (id<SDWebImageOperation>)loadThumbnailForURL:(NSURL *)sourceURL
                                   displaySize:(CGSize)displaySize
                                    completion:(DCChatMediaCompletionBlock)completion {
    if (!sourceURL || displaySize.width <= 0.0f || displaySize.height <= 0.0f) {
        if (completion) completion(nil, nil, NO);
        return nil;
    }

    NSURL *requestURL = DCChatThumbnailURL(sourceURL, displaySize);
    NSString *key = requestURL.absoluteString;
    if (key.length == 0) {
        if (completion) completion(nil, nil, NO);
        return nil;
    }

    UIImage *memoryImage = [self dc_memoryImageForKey:key];
    if (memoryImage) {
        if (completion) completion(memoryImage, nil, YES);
        return nil;
    }

    DCChatMediaLoadOperation *token = [[DCChatMediaLoadOperation alloc] init];
    __weak DCChatMediaLoadOperation *weakToken = token;
    __weak DCChatMediaManager *weakSelf = self;

    token.cacheOperation = [self.diskCache queryDiskCacheForKey:key
                                                           done:^(UIImage *diskImage, SDImageCacheType cacheType) {
        DCChatMediaLoadOperation *strongToken = weakToken;
        DCChatMediaManager *strongSelf = weakSelf;
        if (!strongToken || strongToken.isCancelled || !strongSelf) return;

        if (diskImage) {
            [strongSelf dc_storeMemoryImage:diskImage forKey:key];
            if (completion) completion(diskImage, nil, YES);
            return;
        }

        strongToken.downloadOperation = [strongSelf.downloader
            downloadImageWithURL:requestURL
                         options:(SDWebImageDownloaderLowPriority |
                                  (SDWebImageDownloaderOptions)DCSDWebImageDownloaderAvoidDecode)
                        progress:nil
                       completed:^(UIImage *downloadedImage,
                                   NSData *data,
                                   NSError *error,
                                   BOOL finished) {
            @autoreleasepool {
                DCChatMediaLoadOperation *innerToken = weakToken;
                DCChatMediaManager *innerSelf = weakSelf;
                if (!innerToken || innerToken.isCancelled || !innerSelf) return;
                if (!finished) return;

                UIImage *thumbnail = DCChatThumbnailFromData(data, displaySize);

                if (thumbnail) {
                    /* Store the already-downsampled bitmap, not the original
                     * response bytes, so disk rehydration can never resurrect a
                     * 1024px/third-party full-size decode. */
                    [innerSelf.diskCache storeImage:thumbnail
                                             forKey:key
                                             toDisk:YES];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        DCChatMediaLoadOperation *mainToken = weakToken;
                        DCChatMediaManager *mainSelf = weakSelf;
                        if (!mainToken || mainToken.isCancelled || !mainSelf) return;
                        [mainSelf dc_storeMemoryImage:thumbnail forKey:key];
                        if (completion) completion(thumbnail, nil, NO);
                    });
                } else {
                    NSError *thumbnailError = error;
                    if (!thumbnailError) {
                        thumbnailError = [NSError errorWithDomain:@"DCChatMediaManager"
                                                             code:1
                                                         userInfo:@{NSLocalizedDescriptionKey:
                                                             @"Downloaded media could not be downsampled"}];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        DCChatMediaLoadOperation *mainToken = weakToken;
                        if (!mainToken || mainToken.isCancelled) return;
                        if (completion) completion(nil, thumbnailError, NO);
                    });
                }
            }
        }];
    }];

    return token;
}

- (void)clearMemory {
    [self.memoryImages removeAllObjects];
    [self.memoryCosts removeAllObjects];
    [self.lruKeys removeAllObjects];
    self.mutableMemoryCost = 0;
    self.lastTrimLogTime = 0.0;
}

- (void)enterBackground {
    self.memoryCachingEnabled = NO;
    [self.downloader cancelAllDownloads];
    [self clearMemory];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DCChatMediaPurgeVisibleNotification
                      object:nil];
    [self logMemoryStateWithReason:@"background purge"];
}

- (void)enterForeground {
    self.memoryCachingEnabled = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DCChatMediaRehydrateVisibleNotification
                      object:nil];
    [self logMemoryStateWithReason:@"foreground"];
}

- (void)handleMemoryWarning {
    [self clearMemory];
    [self logMemoryStateWithReason:@"memory warning purge"];
}

- (void)logMemoryStateWithReason:(NSString *)reason {
    uint64_t resident = [[DCResourceManager sharedManager] currentResidentMemoryBytes];
    NSLog(@"[MediaBudget] %@ cache %.2f/%.1fMB entries %lu/%lu diskMax %.0fMB downloads %lu resident %.1fMB",
          reason ?: @"state",
          (double)self.mutableMemoryCost / (double)DCChatMediaMegabyte,
          (double)self.memoryBudget / (double)DCChatMediaMegabyte,
          (unsigned long)self.memoryImages.count,
          (unsigned long)self.entryLimit,
          (double)self.diskCache.maxCacheSize / (double)DCChatMediaMegabyte,
          (unsigned long)self.downloader.currentDownloadCount,
          (double)resident / (double)DCChatMediaMegabyte);
}

@end
