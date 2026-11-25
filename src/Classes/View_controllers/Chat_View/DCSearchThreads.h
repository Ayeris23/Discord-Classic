//
//  DCSearchThreads.h
//  Discord Classic
//
//  Created by Ayeris on 11/24/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <Foundation/Foundation.h>

@interface DCSearchThreads : NSObject

@property (nonatomic, copy, readonly) NSString *query;
@property (nonatomic, strong, readonly) NSArray *activeResults;
@property (nonatomic, strong, readonly) NSArray *archivedResults;
@property (nonatomic, assign, readonly) BOOL loading;
@property (nonatomic, assign, readonly) BOOL hasMore;
@property (nonatomic, copy) void (^resultsChanged)(void);

- (id)initWithChannelID:(NSString *)channelID;
- (void)updateQuery:(NSString *)query activeThreads:(NSArray *)active archivedThreads:(NSArray *)archived;
- (void)updateLoadedActiveThreads:(NSArray *)active archivedThreads:(NSArray *)archived;
- (void)loadNextPage;
- (void)cancel;

@end
