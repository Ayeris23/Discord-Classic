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

@implementation DCContentPurgeManager

+ (void)purgeAllContentPreservingCredentialsWithCompletion:(DCContentPurgeCompletionBlock)completion {
    DCServerCommunicator *communicator = [DCServerCommunicator sharedInstance];
    [communicator prepareForContentPurgeWithCompletion:^{
        DCCacheManager *cache = [DCCacheManager sharedInstance];

        [[DCMessageStore sharedInstance] removeAllWindows];
        [[DCChatMediaManager sharedManager] enterBackground];
        [[SDWebImageManager sharedManager] cancelAll];
        [[[SDWebImageManager sharedManager] imageCache] clearMemory];
        [[NSURLCache sharedURLCache] removeAllCachedResponses];

        [cache invalidateAllMessages];
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

        // DCCacheManager has asynchronous message/folder writers. Queue behind
        // them before declaring the persistent state empty.
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

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (completion) completion(YES, nil);
        });
    }];
}

@end
