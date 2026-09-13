//
//  DCContentPurgeManager.h
//  Discord Classic
//
//  Created by Ayeris on 9/12/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^DCContentPurgeCompletionBlock)(BOOL success, NSError *error);

@interface DCContentPurgeManager : NSObject

+ (void)purgeAllContentPreservingCredentialsWithCompletion:(DCContentPurgeCompletionBlock)completion;

@end
