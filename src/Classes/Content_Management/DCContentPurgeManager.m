//
//  DCContentPurgeManager.m
//  Discord Classic
//
//  Created by Ayeris on 9/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCContentPurgeManager.h"
#import "DCCacheManager.h"
#import "DCChatMediaManager.h"
#import "DCMessageStore.h"
#import "DCServerCommunicator.h"
#import "SDWebImageManager.h"
#import "SDImageCache.h"

static BOOL DCRemoveDirectoryContents(NSString *directory, NSError **error) {
    if (directory.length == 0) return YES;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:directory isDirectory:&isDirectory]) {
        return YES;
    }
    if (!isDirectory) {
        return [fileManager removeItemAtPath:directory error:error];
    }

    NSError *listError = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:directory
                                                         error:&listError];
    if (!contents) {
        if (error) *error = listError;
        return NO;
    }

    NSError *firstError = nil;
    for (NSString *name in contents) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSError *removeError = nil;
        if (![fileManager removeItemAtPath:path error:&removeError] && !firstError) {
            firstError = removeError;
        }
    }

    if (firstError) {
        if (error) *error = firstError;
        return NO;
    }
    return YES;
}

static BOOL DCRemoveDocumentCacheArtifacts(NSError **error) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = [paths objectAtIndex:0];

    NSError *listError = nil;
    NSArray *contents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:documents
                            error:&listError];
    if (!contents) {
        if (error) *error = listError;
        return NO;
    }

    NSError *firstError = nil;
    for (NSString *name in contents) {
        if (![name hasPrefix:@"dc_"]) continue;

        NSString *path = [documents stringByAppendingPathComponent:name];
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path
                                                        error:&removeError] &&
            !firstError) {
            firstError = removeError;
        }
    }

    if (firstError) {
        if (error) *error = firstError;
        return NO;
    }
    return YES;
}

@implementation DCContentPurgeManager

+ (void)purgeAllContentPreservingCredentialsWithCompletion:(DCContentPurgeCompletionBlock)completion {
    DCServerCommunicator *communicator = [DCServerCommunicator sharedInstance];
    [communicator prepareForContentPurgeWithCompletion:^{
        DCCacheManager *cache = [DCCacheManager sharedInstance];

        [[DCMessageStore sharedInstance] removeAllWindows];
        [[DCChatMediaManager sharedManager] enterBackground];
        [[SDWebImageManager sharedManager] cancelAll];
        [[[SDWebImageManager sharedManager] imageCache] clearMemory];

        NSURLCache *URLCache = [NSURLCache sharedURLCache];
        [URLCache removeAllCachedResponses];
        [URLCache setMemoryCapacity:0];
        [URLCache setDiskCapacity:0];

        [cache invalidateAllMessages];
        [cache invalidateAllMessageWindows];
        [cache invalidateGuildCache];
        [cache invalidateDisplayLayout];
        [cache invalidateFolderCompositeCache];
        [cache invalidateUserCache];
        [cache invalidateUserInfoCache];
        [cache invalidateGatewayCheckpoint];
        [cache clearLastActiveChatChannel];
        [cache clearLastSelectedGuild];

        // Folder open/closed state is content-derived. Reset those records while
        // retaining login credentials and normal application preferences.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *defaultValues = [defaults dictionaryRepresentation];
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        for (NSString *key in defaultValues) {
            if (key.length == 0 ||
                [key rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
                continue;
            }
            id value = [defaultValues objectForKey:key];
            if ([value isKindOfClass:[NSDictionary class]] &&
                [(NSDictionary *)value objectForKey:@"opened"] != nil) {
                [defaults removeObjectForKey:key];
            }
        }
        [defaults synchronize];

        // Queue behind every asynchronous DCCacheManager writer before the
        // filesystem sweep removes any remaining cache artifacts.
        [cache performCacheOperation:^id{
            return nil;
        }];

        dispatch_group_t group = dispatch_group_create();

        dispatch_group_enter(group);
        [[[SDWebImageManager sharedManager] imageCache]
            clearDiskOnCompletion:^{
                dispatch_group_leave(group);
            }];

        dispatch_group_enter(group);
        [[DCChatMediaManager sharedManager]
            purgeAllCachedContentWithCompletion:^{
                dispatch_group_leave(group);
            }];

        dispatch_group_notify(group,
                              dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *purgeError = nil;
            NSError *operationError = nil;
            BOOL success = YES;

            if (!DCRemoveDocumentCacheArtifacts(&operationError)) {
                success = NO;
                purgeError = operationError;
            }

            NSArray *cachePaths = NSSearchPathForDirectoriesInDomains(
                NSCachesDirectory, NSUserDomainMask, YES);
            operationError = nil;
            if (!DCRemoveDirectoryContents([cachePaths objectAtIndex:0], &operationError)) {
                success = NO;
                if (!purgeError) purgeError = operationError;
            }

            operationError = nil;
            if (!DCRemoveDirectoryContents(NSTemporaryDirectory(), &operationError)) {
                success = NO;
                if (!purgeError) purgeError = operationError;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(success, purgeError);
            });
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }];
}

@end
