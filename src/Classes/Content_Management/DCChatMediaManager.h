//
//  DCChatMediaManager.h
//  Discord Classic
//
//  Created by Ayeris on 8/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SDWebImageOperation.h"

extern NSString * const DCChatMediaPurgeVisibleNotification;
extern NSString * const DCChatMediaRehydrateVisibleNotification;

typedef void (^DCChatMediaCompletionBlock)(UIImage *image,
                                            NSError *error,
                                            BOOL fromCache);
typedef void (^DCChatMediaURLCompletionBlock)(NSURL *url, NSError *error);

@interface DCChatMediaManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) NSUInteger memoryBudget;
@property (nonatomic, readonly) NSUInteger currentMemoryCost;
@property (nonatomic, readonly) NSUInteger memoryEntryCount;

/*
 * Load a display thumbnail for a chat-media source URL.  displaySize is in
 * points; the manager requests/decodes only enough pixels for the current
 * screen scale and keeps the compressed result on disk.
 *
 * The returned operation may be cancelled when a reusable attachment view
 * leaves the screen.  Cache population is bounded independently from the
 * global avatar/guild-icon SDWebImage cache.
 */
- (id<SDWebImageOperation>)loadThumbnailForURL:(NSURL *)sourceURL
                                   displaySize:(CGSize)displaySize
                                    completion:(DCChatMediaCompletionBlock)completion;

/*
 * Hot-path lookup used while a scroll is moving too quickly to justify disk
 * decode/network work.  This never touches disk and never starts a request.
 */
- (UIImage *)memoryThumbnailForURL:(NSURL *)sourceURL
                       displaySize:(CGSize)displaySize;

/*
 * Discord attachment/media-proxy URLs carry short-lived ex/is/hm query
 * credentials. Register fresh payload URLs here so stale attachment models can
 * transparently reuse the newest credentials without changing their stable
 * media identity. Non-Discord URLs are ignored/returned unchanged.
 */
- (void)registerMediaURL:(NSURL *)url;
- (void)registerMediaURL:(NSURL *)url
               channelID:(NSString *)channelID
               messageID:(NSString *)messageID;
- (NSURL *)currentMediaURLForURL:(NSURL *)url;
- (BOOL)mediaURLNeedsRefresh:(NSURL *)url;

/*
 * Resolve a media URL before network use. Expired Discord attachment
 * credentials are refreshed through Discord's attachment URL refresher, with
 * a narrow message-history fallback when ownership is known. The completion
 * block is delivered on the main thread.
 */
- (void)resolveMediaURL:(NSURL *)url
             completion:(DCChatMediaURLCompletionBlock)completion;

/* Force credential refresh after an unexpected signed-media HTTP failure. */
- (void)refreshMediaURL:(NSURL *)url
             completion:(DCChatMediaURLCompletionBlock)completion;

- (void)clearMemory;
- (void)purgeAllCachedContentWithCompletion:(void (^)(void))completion;
- (void)enterBackground;
- (void)enterForeground;
- (void)handleMemoryWarning;
- (void)logMemoryStateWithReason:(NSString *)reason;

@end
