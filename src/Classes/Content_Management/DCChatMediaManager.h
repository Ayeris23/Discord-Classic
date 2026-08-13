//
//  DCChatMediaManager.h
//  Discord Classic
//
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SDWebImageOperation.h"

extern NSString * const DCChatMediaPurgeVisibleNotification;
extern NSString * const DCChatMediaRehydrateVisibleNotification;

typedef void (^DCChatMediaCompletionBlock)(UIImage *image,
                                            NSError *error,
                                            BOOL fromCache);

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

- (void)clearMemory;
- (void)enterBackground;
- (void)enterForeground;
- (void)handleMemoryWarning;
- (void)logMemoryStateWithReason:(NSString *)reason;

@end
