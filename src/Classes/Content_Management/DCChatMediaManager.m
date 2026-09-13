//
//  DCChatMediaManager.m
//  Discord Classic
//
//  Created by Ayeris on 8/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCChatMediaManager.h"
#import "DCResourceManager.h"
#import "DCServerCommunicator.h"
#import "SDImageCache.h"
#import "SDWebImageDownloader.h"
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <stdlib.h>

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

static BOOL DCChatMediaVolatileQueryKey(NSString *key) {
    NSString *lower = [key lowercaseString];
    return [lower isEqualToString:@"ex"] ||
           [lower isEqualToString:@"is"] ||
           [lower isEqualToString:@"hm"];
}

static NSDictionary *DCChatMediaSignedQueryValues(NSURL *url) {
    if (!url || !DCChatMediaHostSupportsSizing(url.host)) return nil;
    NSString *query = url.query;
    if (query.length == 0) return nil;

    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithCapacity:3];
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound
            ? part : [part substringToIndex:equals.location];
        if (!DCChatMediaVolatileQueryKey(key)) continue;
        NSString *value = equals.location == NSNotFound
            ? @"" : [part substringFromIndex:equals.location + 1];
        [values setObject:value forKey:[key lowercaseString]];
    }
    return values.count ? values : nil;
}

static unsigned long long DCChatMediaExpiryValue(NSDictionary *signature) {
    NSString *expiry = [signature objectForKey:@"ex"];
    if (![expiry isKindOfClass:[NSString class]] || expiry.length == 0) return 0;
    return strtoull([expiry UTF8String], NULL, 16);
}

static BOOL DCChatMediaSignatureIsFresh(NSDictionary *signature) {
    if (signature.count == 0) return YES;
    unsigned long long expiry = DCChatMediaExpiryValue(signature);
    if (expiry == 0) return YES;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    const NSTimeInterval refreshLeeway = 5.0 * 60.0;
    return (NSTimeInterval)expiry > now + refreshLeeway;
}

static NSString *DCChatMediaEndpointClass(NSString *host) {
    NSString *lower = [host lowercaseString];
    if ([lower hasPrefix:@"media."]) return @"media";
    if ([lower hasPrefix:@"cdn."]) return @"cdn";
    return lower;
}

static NSString *DCChatMediaIdentityKey(NSURL *url) {
    if (!url || !DCChatMediaHostSupportsSizing(url.host) || url.path.length == 0) return nil;
    return [NSString stringWithFormat:@"%@:%@",
            DCChatMediaEndpointClass(url.host), url.path];
}

static NSString *DCChatMediaLocationBase(NSURL *url) {
    if (!url) return nil;
    NSString *absolute = url.absoluteString;
    NSRange question = [absolute rangeOfString:@"?"];
    return question.location == NSNotFound
        ? absolute : [absolute substringToIndex:question.location];
}

static BOOL DCChatMediaIsAttachmentURL(NSURL *url) {
    if (!url || !DCChatMediaHostSupportsSizing(url.host)) return NO;
    NSString *path = [url.path lowercaseString];
    return [path hasPrefix:@"/attachments/"];
}

static NSString *DCChatMediaStableCacheKey(NSURL *url) {
    if (!url) return nil;
    if (!DCChatMediaHostSupportsSizing(url.host)) return url.absoluteString;

    NSString *absolute = url.absoluteString;
    NSRange question = [absolute rangeOfString:@"?"];
    if (question.location == NSNotFound) return absolute;

    NSString *base = [absolute substringToIndex:question.location];
    NSString *query = [absolute substringFromIndex:question.location + 1];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound
            ? part : [part substringToIndex:equals.location];
        if (DCChatMediaVolatileQueryKey(key)) continue;
        [parts addObject:part];
    }
    return parts.count
        ? [NSString stringWithFormat:@"%@?%@", base, [parts componentsJoinedByString:@"&"]]
        : base;
}

static NSURL *DCChatMediaURLByReplacingSignedQuery(NSURL *url,
                                                    NSDictionary *signature,
                                                    NSString *locationBase) {
    if (!url || signature.count == 0) return url;

    NSString *absolute = url.absoluteString;
    NSRange question = [absolute rangeOfString:@"?"];
    NSString *base = locationBase.length
        ? locationBase
        : (question.location == NSNotFound
            ? absolute : [absolute substringToIndex:question.location]);
    NSString *query = question.location == NSNotFound
        ? @"" : [absolute substringFromIndex:question.location + 1];

    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [query componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange equals = [part rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound
            ? part : [part substringToIndex:equals.location];
        if (DCChatMediaVolatileQueryKey(key)) continue;
        [parts addObject:part];
    }
    for (NSString *key in @[@"ex", @"is", @"hm"]) {
        NSString *value = [signature objectForKey:key];
        if ([value isKindOfClass:[NSString class]] && value.length) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
    }

    NSString *rebuilt = parts.count
        ? [NSString stringWithFormat:@"%@?%@", base, [parts componentsJoinedByString:@"&"]]
        : base;
    return [NSURL URLWithString:rebuilt];
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
@property (strong, nonatomic) NSMutableDictionary *latestMediaSignatures;
@property (strong, nonatomic) NSMutableDictionary *latestMediaLocations;
@property (strong, nonatomic) NSMutableArray *latestMediaSignatureKeys;
@property (assign, nonatomic) NSUInteger mediaSignatureLimit;
@property (strong, nonatomic) NSMutableDictionary *mediaOwners;
@property (strong, nonatomic) NSMutableArray *mediaOwnerKeys;
@property (assign, nonatomic) NSUInteger mediaOwnerLimit;
@property (strong, nonatomic) NSMutableDictionary *mediaRefreshWaiters;
@property (strong, nonatomic) NSOperationQueue *mediaRefreshQueue;
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
    _latestMediaSignatures = [NSMutableDictionary dictionary];
    _latestMediaLocations = [NSMutableDictionary dictionary];
    _latestMediaSignatureKeys = [NSMutableArray array];
    _mediaOwners = [NSMutableDictionary dictionary];
    _mediaOwnerKeys = [NSMutableArray array];
    _mediaRefreshWaiters = [NSMutableDictionary dictionary];
    _mutableMemoryCost = 0;
    _memoryCachingEnabled = YES;

    DCResourceManager *resources = [DCResourceManager sharedManager];
    _mediaSignatureLimit = resources.memoryClass == DCDeviceMemoryClass256MB ? 256U : 512U;
    _mediaOwnerLimit = resources.memoryClass == DCDeviceMemoryClass256MB ? 1024U : 2048U;
    _mediaRefreshQueue = [[NSOperationQueue alloc] init];
    _mediaRefreshQueue.maxConcurrentOperationCount =
        resources.memoryClass == DCDeviceMemoryClass256MB ? 1 : 2;

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

- (void)registerMediaURL:(NSURL *)url {
    [self registerMediaURL:url channelID:nil messageID:nil];
}

- (void)registerMediaURL:(NSURL *)url
               channelID:(NSString *)channelID
               messageID:(NSString *)messageID {
    NSString *identity = DCChatMediaIdentityKey(url);
    if (!identity.length) return;

    if (channelID.length && messageID.length) {
        NSDictionary *owner = @{ @"channelID" : channelID,
                                 @"messageID" : messageID };
        @synchronized (self.mediaOwners) {
            [self.mediaOwners setObject:owner forKey:identity];
            [self.mediaOwnerKeys removeObject:identity];
            [self.mediaOwnerKeys addObject:identity];
            while (self.mediaOwnerKeys.count > self.mediaOwnerLimit) {
                NSString *oldest = [self.mediaOwnerKeys objectAtIndex:0];
                [self.mediaOwnerKeys removeObjectAtIndex:0];
                [self.mediaOwners removeObjectForKey:oldest];
            }
        }
    }

    NSDictionary *candidate = DCChatMediaSignedQueryValues(url);
    if (candidate.count == 0 || !DCChatMediaSignatureIsFresh(candidate)) return;

    @synchronized (self.latestMediaSignatures) {
        NSDictionary *current = [self.latestMediaSignatures objectForKey:identity];
        unsigned long long candidateExpiry = DCChatMediaExpiryValue(candidate);
        unsigned long long currentExpiry = DCChatMediaExpiryValue(current);
        BOOL shouldStore = !current ||
                           candidateExpiry > currentExpiry ||
                           (candidateExpiry != 0 && candidateExpiry == currentExpiry) ||
                           (currentExpiry == 0 && candidateExpiry != 0);
        if (!shouldStore) return;

        [self.latestMediaSignatures setObject:candidate forKey:identity];
        NSString *location = DCChatMediaLocationBase(url);
        if (location.length) {
            [self.latestMediaLocations setObject:location forKey:identity];
        }
        [self.latestMediaSignatureKeys removeObject:identity];
        [self.latestMediaSignatureKeys addObject:identity];
        while (self.latestMediaSignatureKeys.count > self.mediaSignatureLimit) {
            NSString *oldest = [self.latestMediaSignatureKeys objectAtIndex:0];
            [self.latestMediaSignatureKeys removeObjectAtIndex:0];
            [self.latestMediaSignatures removeObjectForKey:oldest];
            [self.latestMediaLocations removeObjectForKey:oldest];
        }
    }
}

- (NSURL *)currentMediaURLForURL:(NSURL *)url {
    NSString *identity = DCChatMediaIdentityKey(url);
    if (!identity.length) return url;

    NSDictionary *inputSignature = DCChatMediaSignedQueryValues(url);
    BOOL inputFresh = DCChatMediaSignatureIsFresh(inputSignature);
    unsigned long long inputExpiry = DCChatMediaExpiryValue(inputSignature);

    NSDictionary *storedSignature = nil;
    NSString *storedLocation = nil;
    @synchronized (self.latestMediaSignatures) {
        NSDictionary *candidate = [self.latestMediaSignatures objectForKey:identity];
        if (candidate && !DCChatMediaSignatureIsFresh(candidate)) {
            [self.latestMediaSignatures removeObjectForKey:identity];
            [self.latestMediaLocations removeObjectForKey:identity];
            [self.latestMediaSignatureKeys removeObject:identity];
        } else if (candidate) {
            storedSignature = [candidate copy];
            storedLocation = [[self.latestMediaLocations objectForKey:identity] copy];
            [self.latestMediaSignatureKeys removeObject:identity];
            [self.latestMediaSignatureKeys addObject:identity];
        }
    }

    if (inputSignature.count && inputFresh) {
        unsigned long long storedExpiry = DCChatMediaExpiryValue(storedSignature);
        if (!storedSignature || inputExpiry >= storedExpiry) {
            return url;
        }
    }

    if (storedSignature.count) {
        return DCChatMediaURLByReplacingSignedQuery(url,
                                                    storedSignature,
                                                    storedLocation);
    }
    return url;
}

- (BOOL)mediaURLNeedsRefresh:(NSURL *)url {
    NSURL *current = [self currentMediaURLForURL:url];
    NSDictionary *signature = DCChatMediaSignedQueryValues(current);
    return signature.count > 0 && !DCChatMediaSignatureIsFresh(signature);
}

- (void)dc_completeURL:(NSURL *)url
                 error:(NSError *)error
            completion:(DCChatMediaURLCompletionBlock)completion {
    if (!completion) return;
    void (^finish)(void) = ^{
        completion(url, error);
    };
    if ([NSThread isMainThread]) {
        finish();
    } else {
        dispatch_async(dispatch_get_main_queue(), finish);
    }
}

- (void)dc_registerMediaURLsInObject:(id)object
                           channelID:(NSString *)channelID
                           messageID:(NSString *)messageID {
    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)object allValues]) {
            [self dc_registerMediaURLsInObject:value
                                     channelID:channelID
                                     messageID:messageID];
        }
        return;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            [self dc_registerMediaURLsInObject:value
                                     channelID:channelID
                                     messageID:messageID];
        }
        return;
    }
    if (![object isKindOfClass:[NSString class]]) return;

    NSString *string = (NSString *)object;
    if ([string rangeOfString:@"discord" options:NSCaseInsensitiveSearch].location == NSNotFound ||
        [string rangeOfString:@"http" options:NSCaseInsensitiveSearch].location != 0) {
        return;
    }
    NSURL *url = [NSURL URLWithString:string];
    if (!DCChatMediaIdentityKey(url)) return;
    if (DCChatMediaSignedQueryValues(url).count == 0) return;
    [self registerMediaURL:url channelID:channelID messageID:messageID];
}

- (void)resolveMediaURL:(NSURL *)url
             completion:(DCChatMediaURLCompletionBlock)completion {
    if (!url) {
        [self dc_completeURL:nil error:nil completion:completion];
        return;
    }

    NSURL *current = [self currentMediaURLForURL:url];
    if (![self mediaURLNeedsRefresh:current]) {
        [self dc_completeURL:current error:nil completion:completion];
        return;
    }
    [self refreshMediaURL:url completion:completion];
}

- (NSError *)dc_refreshAttachmentURLDirectly:(NSURL *)url {
    if (!DCChatMediaIsAttachmentURL(url)) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:10
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"This Discord media URL is not a refreshable attachment URL"}];
    }

    NSString *inputURL = DCChatMediaLocationBase(url);
    if (!inputURL.length) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:11
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Attachment URL could not be normalized for refresh"}];
    }

    NSMutableURLRequest *request = [DCServerCommunicator
        requestWithPath:@"/attachments/refresh-urls"
                  token:DCServerCommunicator.sharedInstance.token];
    // Use the current API host directly so a legacy-domain redirect cannot
    // rewrite or discard this POST body on older Foundation stacks.
    [request setURL:[NSURL URLWithString:@"https://discord.com/api/v9/attachments/refresh-urls"]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

    NSError *bodyError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{
        @"attachment_urls" : @[ inputURL ]
    } options:0 error:&bodyError];
    if (!body) return bodyError;
    [request setHTTPBody:body];

    NSError *requestError = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&requestError];
    if (requestError) return requestError;
    if (response.statusCode != 200 || data.length == 0) {
        NSString *description = [NSString stringWithFormat:
            @"Attachment URL refresh returned HTTP %ld", (long)response.statusCode];
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:response.statusCode ?: 12
                               userInfo:@{NSLocalizedDescriptionKey:description}];
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        return jsonError ?: [NSError errorWithDomain:@"DCChatMediaSignature"
                                                code:13
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"Attachment URL refresh returned invalid JSON"}];
    }

    NSArray *refreshedURLs = [(NSDictionary *)parsed objectForKey:@"refreshed_urls"];
    if (![refreshedURLs isKindOfClass:[NSArray class]] || refreshedURLs.count == 0) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:14
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Attachment URL refresh returned no refreshed URL"}];
    }

    NSString *refreshedString = nil;
    for (id value in refreshedURLs) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        id candidate = [(NSDictionary *)value objectForKey:@"refreshed"];
        if ([candidate isKindOfClass:[NSString class]] && [candidate length]) {
            refreshedString = candidate;
            break;
        }
    }
    if (!refreshedString.length) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:15
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Attachment URL refresh response did not contain a usable URL"}];
    }

    NSURL *refreshedURL = [NSURL URLWithString:refreshedString];
    NSDictionary *signature = DCChatMediaSignedQueryValues(refreshedURL);
    if (signature.count == 0 || !DCChatMediaSignatureIsFresh(signature)) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:16
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Attachment URL refresh did not provide fresh credentials"}];
    }

    // Keep the caller's CDN/media host and any sizing parameters. Only the
    // volatile Discord credentials need to move forward.
    NSURL *resolved = DCChatMediaURLByReplacingSignedQuery(url, signature, nil);
    [self registerMediaURL:resolved];
    return nil;
}

- (NSError *)dc_refreshOwningMessageForURL:(NSURL *)url
                                  identity:(NSString *)identity {
    NSDictionary *owner = nil;
    @synchronized (self.mediaOwners) {
        owner = [[self.mediaOwners objectForKey:identity] copy];
        if (owner) {
            [self.mediaOwnerKeys removeObject:identity];
            [self.mediaOwnerKeys addObject:identity];
        }
    }

    NSString *channelID = [owner objectForKey:@"channelID"];
    NSString *messageID = [owner objectForKey:@"messageID"];
    if (!channelID.length || !messageID.length) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:20
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"No owning message is known for media refresh fallback"}];
    }

    NSString *path = [NSString stringWithFormat:
        @"/channels/%@/messages?around=%@&limit=1", channelID, messageID];
    NSMutableURLRequest *request = [DCServerCommunicator
        requestWithPath:path
                  token:DCServerCommunicator.sharedInstance.token];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

    NSError *requestError = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&requestError];
    if (requestError) return requestError;
    if (response.statusCode != 200 || data.length == 0) {
        NSString *description = [NSString stringWithFormat:
            @"Message-history refresh returned HTTP %ld", (long)response.statusCode];
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:response.statusCode ?: 21
                               userInfo:@{NSLocalizedDescriptionKey:description}];
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![parsed isKindOfClass:[NSArray class]]) {
        return jsonError ?: [NSError errorWithDomain:@"DCChatMediaSignature"
                                                code:22
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"Message-history refresh returned invalid JSON"}];
    }

    NSDictionary *messageJSON = nil;
    for (id value in (NSArray *)parsed) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        id candidateID = [(NSDictionary *)value objectForKey:@"id"];
        if ([candidateID isKindOfClass:[NSString class]] &&
            [candidateID isEqualToString:messageID]) {
            messageJSON = value;
            break;
        }
    }
    if (!messageJSON) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:23
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Owning message was not returned by history refresh"}];
    }

    [self dc_registerMediaURLsInObject:messageJSON
                             channelID:channelID
                             messageID:messageID];
    NSURL *resolved = [self currentMediaURLForURL:url];
    if ([self mediaURLNeedsRefresh:resolved]) {
        return [NSError errorWithDomain:@"DCChatMediaSignature"
                                   code:24
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Message-history refresh did not provide fresh media credentials"}];
    }
    return nil;
}

- (void)refreshMediaURL:(NSURL *)url
             completion:(DCChatMediaURLCompletionBlock)completion {
    NSString *identity = DCChatMediaIdentityKey(url);
    if (!identity.length) {
        NSError *error = [NSError errorWithDomain:@"DCChatMediaSignature"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"This media URL does not use refreshable Discord credentials"}];
        [self dc_completeURL:url error:error completion:completion];
        return;
    }

    __weak DCChatMediaManager *weakSelf = self;
    void (^waiter)(NSError *) = ^(NSError *refreshError) {
        DCChatMediaManager *strongSelf = weakSelf;
        NSURL *resolved = strongSelf ? [strongSelf currentMediaURLForURL:url] : url;
        if (completion) completion(resolved, refreshError);
    };

    BOOL shouldStart = NO;
    @synchronized (self.mediaRefreshWaiters) {
        NSMutableArray *waiters = [self.mediaRefreshWaiters objectForKey:identity];
        if (!waiters) {
            waiters = [NSMutableArray array];
            [self.mediaRefreshWaiters setObject:waiters forKey:identity];
            shouldStart = YES;
        }
        if (waiter) [waiters addObject:[waiter copy]];
    }
    if (!shouldStart) return;

    [self.mediaRefreshQueue addOperationWithBlock:^{
        @autoreleasepool {
            DCChatMediaManager *strongSelf = weakSelf;
            if (!strongSelf) return;

            NSURL *current = [strongSelf currentMediaURLForURL:url];
            NSError *directError = [strongSelf dc_refreshAttachmentURLDirectly:current];
            NSError *refreshError = directError;
            NSString *method = @"attachment URL";

            if (directError) {
                NSError *fallbackError = [strongSelf dc_refreshOwningMessageForURL:url
                                                                           identity:identity];
                if (!fallbackError) {
                    refreshError = nil;
                    method = @"message history";
                } else {
                    NSLog(@"[MediaSignature] direct refresh failed %@: %@; fallback failed: %@",
                          identity, directError, fallbackError);
                    refreshError = fallbackError;
                }
            }

            NSURL *resolved = [strongSelf currentMediaURLForURL:url];
            if (!refreshError && [strongSelf mediaURLNeedsRefresh:resolved]) {
                refreshError = [NSError errorWithDomain:@"DCChatMediaSignature"
                                                   code:25
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Media refresh completed without fresh credentials"}];
            }

            if (refreshError) {
                NSLog(@"[MediaSignature] refresh failed %@: %@", identity, refreshError);
            } else {
                NSLog(@"[MediaSignature] refreshed %@ via %@", identity, method);
            }

            NSArray *waiters = nil;
            @synchronized (strongSelf.mediaRefreshWaiters) {
                waiters = [[strongSelf.mediaRefreshWaiters objectForKey:identity] copy];
                [strongSelf.mediaRefreshWaiters removeObjectForKey:identity];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                for (void (^block)(NSError *) in waiters) {
                    block(refreshError);
                }
            });
        }
    }];
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
    NSString *key = DCChatMediaStableCacheKey(requestURL);
    if (key.length == 0) return nil;
    return [self dc_memoryImageForKey:key];
}

- (BOOL)dc_errorMayIndicateExpiredSignature:(NSError *)error {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    return error.code == 401 || error.code == 403 || error.code == 404;
}

- (void)dc_startThumbnailDownloadForSourceURL:(NSURL *)sourceURL
                                  displaySize:(CGSize)displaySize
                                     cacheKey:(NSString *)key
                                        token:(DCChatMediaLoadOperation *)token
                          allowSignatureRetry:(BOOL)allowSignatureRetry
                                   completion:(DCChatMediaCompletionBlock)completion {
    if (!sourceURL || !token || token.isCancelled) return;

    __weak DCChatMediaManager *weakSelf = self;
    __weak DCChatMediaLoadOperation *weakToken = token;
    [self resolveMediaURL:sourceURL completion:^(NSURL *resolvedURL, NSError *resolutionError) {
        DCChatMediaManager *strongSelf = weakSelf;
        DCChatMediaLoadOperation *strongToken = weakToken;
        if (!strongSelf || !strongToken || strongToken.isCancelled) return;

        if (resolutionError && [strongSelf mediaURLNeedsRefresh:resolvedURL]) {
            if (completion) completion(nil, resolutionError, NO);
            return;
        }

        NSURL *requestURL = DCChatThumbnailURL(resolvedURL, displaySize);
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
                DCChatMediaManager *innerSelf = weakSelf;
                DCChatMediaLoadOperation *innerToken = weakToken;
                if (!innerSelf || !innerToken || innerToken.isCancelled || !finished) return;

                if (allowSignatureRetry &&
                    [innerSelf dc_errorMayIndicateExpiredSignature:error]) {
                    [innerSelf refreshMediaURL:sourceURL
                                    completion:^(NSURL *retryURL, NSError *refreshError) {
                        DCChatMediaLoadOperation *retryToken = weakToken;
                        if (!retryToken || retryToken.isCancelled) return;
                        if (refreshError && [innerSelf mediaURLNeedsRefresh:retryURL]) {
                            if (completion) completion(nil, refreshError, NO);
                            return;
                        }
                        [innerSelf dc_startThumbnailDownloadForSourceURL:sourceURL
                                                            displaySize:displaySize
                                                               cacheKey:key
                                                                  token:retryToken
                                                    allowSignatureRetry:NO
                                                             completion:completion];
                    }];
                    return;
                }

                UIImage *thumbnail = DCChatThumbnailFromData(data, displaySize);
                if (thumbnail) {
                    [innerSelf.diskCache storeImage:thumbnail forKey:key toDisk:YES];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        DCChatMediaManager *mainSelf = weakSelf;
                        DCChatMediaLoadOperation *mainToken = weakToken;
                        if (!mainSelf || !mainToken || mainToken.isCancelled) return;
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
}

- (id<SDWebImageOperation>)loadThumbnailForURL:(NSURL *)sourceURL
                                   displaySize:(CGSize)displaySize
                                    completion:(DCChatMediaCompletionBlock)completion {
    if (!sourceURL || displaySize.width <= 0.0f || displaySize.height <= 0.0f) {
        if (completion) completion(nil, nil, NO);
        return nil;
    }

    NSURL *cacheURL = DCChatThumbnailURL(sourceURL, displaySize);
    NSString *key = DCChatMediaStableCacheKey(cacheURL);
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

        [strongSelf dc_startThumbnailDownloadForSourceURL:sourceURL
                                              displaySize:displaySize
                                                 cacheKey:key
                                                    token:strongToken
                                      allowSignatureRetry:YES
                                               completion:completion];
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

- (void)purgeAllCachedContentWithCompletion:(void (^)(void))completion {
    self.memoryCachingEnabled = NO;
    [self.downloader cancelAllDownloads];
    [self.mediaRefreshQueue cancelAllOperations];
    [self clearMemory];

    @synchronized (self.latestMediaSignatures) {
        [self.latestMediaSignatures removeAllObjects];
        [self.latestMediaLocations removeAllObjects];
        [self.latestMediaSignatureKeys removeAllObjects];
    }
    @synchronized (self.mediaOwners) {
        [self.mediaOwners removeAllObjects];
        [self.mediaOwnerKeys removeAllObjects];
    }
    @synchronized (self.mediaRefreshWaiters) {
        [self.mediaRefreshWaiters removeAllObjects];
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:DCChatMediaPurgeVisibleNotification
                      object:nil];

    [self.diskCache clearDiskOnCompletion:^{
        if (completion) completion();
    }];
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
