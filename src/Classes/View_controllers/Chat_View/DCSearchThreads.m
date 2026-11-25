//
//  DCSearchThreads.m
//  Discord Classic
//
//  Created by Ayeris on 11/24/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCSearchThreads.h"
#import "DCServerCommunicator.h"
#import "DCChannel.h"

static const NSUInteger DCSearchThreadsPageSize = 25;
static const NSUInteger DCSearchThreadsResultLimit = 500;

@interface DCSearchThreads ()
@property (nonatomic, copy, readwrite) NSString *query;
@property (nonatomic, strong, readwrite) NSArray *activeResults;
@property (nonatomic, strong, readwrite) NSArray *archivedResults;
@property (nonatomic, assign, readwrite) BOOL loading;
@property (nonatomic, assign, readwrite) BOOL hasMore;
@property (nonatomic, copy) NSString *channelID;
@property (nonatomic, strong) NSArray *loadedActive;
@property (nonatomic, strong) NSArray *loadedArchived;
@property (nonatomic, strong) NSMutableArray *remoteActive;
@property (nonatomic, strong) NSMutableArray *remoteArchived;
@property (nonatomic, assign) NSUInteger offset;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign) BOOL requestInFlight;
- (void)performSearchRequest;
- (void)refreshResults;
@end

@implementation DCSearchThreads

- (id)initWithChannelID:(NSString *)channelID {
    self = [super init];
    if (!self) return nil;
    _channelID = [channelID copy];
    _query = @"";
    _activeResults = @[];
    _archivedResults = @[];
    _loadedActive = @[];
    _loadedArchived = @[];
    _remoteActive = [NSMutableArray array];
    _remoteArchived = [NSMutableArray array];
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)cancel {
    ++_generation;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    self.resultsChanged = nil;
    self.loading = NO;
    self.hasMore = NO;
}

- (void)updateLoadedActiveThreads:(NSArray *)active archivedThreads:(NSArray *)archived {
    self.loadedActive = active ?: @[];
    self.loadedArchived = archived ?: @[];
    if (self.query.length) [self refreshResults];
}

- (void)updateQuery:(NSString *)query activeThreads:(NSArray *)active archivedThreads:(NSArray *)archived {
    NSString *newQuery = [[query ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if ([newQuery isEqualToString:self.query]) {
        [self updateLoadedActiveThreads:active archivedThreads:archived];
        return;
    }
    ++_generation;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    self.query = newQuery;
    self.loadedActive = active ?: @[];
    self.loadedArchived = archived ?: @[];
    [self.remoteActive removeAllObjects];
    [self.remoteArchived removeAllObjects];
    self.offset = 0;
    self.requestInFlight = NO;
    self.hasMore = NO;
    self.loading = newQuery.length > 0;
    [self refreshResults];
    if (self.loading)
        [self performSelector:@selector(performSearchRequest) withObject:nil afterDelay:0.3];
}

- (BOOL)thread:(NSDictionary *)thread matchesQuery:(NSString *)query {
    NSString *name = [thread objectForKey:@"name"];
    return [name isKindOfClass:[NSString class]] &&
        [name rangeOfString:query options:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)].location != NSNotFound;
}

- (void)addThreads:(NSArray *)threads toArray:(NSMutableArray *)destination
             seen:(NSMutableSet *)seen filter:(BOOL)filter {
    for (NSDictionary *thread in threads) {
        if (![thread isKindOfClass:[NSDictionary class]]) continue;
        NSString *identifier = [thread objectForKey:@"id"];
        if (![identifier isKindOfClass:[NSString class]] || !identifier.length ||
            [seen containsObject:identifier]) continue;
        if (filter && ![self thread:thread matchesQuery:self.query]) continue;
        [seen addObject:identifier];
        [destination addObject:thread];
        if (seen.count >= DCSearchThreadsResultLimit) break;
    }
}

- (void)refreshResults {
    NSMutableArray *active = [NSMutableArray array];
    NSMutableArray *archived = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    if (self.query.length) {
        [self addThreads:self.remoteActive toArray:active seen:seen filter:NO];
        [self addThreads:self.remoteArchived toArray:archived seen:seen filter:NO];
        [self addThreads:self.loadedActive toArray:active seen:seen filter:YES];
        [self addThreads:self.loadedArchived toArray:archived seen:seen filter:YES];
    }
    self.activeResults = active;
    self.archivedResults = archived;
    if (self.resultsChanged) self.resultsChanged();
}

- (void)loadNextPage {
    if (!self.query.length || !self.hasMore || self.loading) return;
    [self performSearchRequest];
}

- (void)performSearchRequest {
    if (!self.query.length || !self.channelID.length || self.requestInFlight) return;
    self.requestInFlight = YES;
    self.loading = YES;
    if (self.resultsChanged) self.resultsChanged();
    NSUInteger generation = self.generation;
    NSUInteger offset = self.offset;
    NSString *channelID = [self.channelID copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    NSString *name = self.query.length > 100 ? [self.query substringToIndex:100] : self.query;
    CFStringRef encodedName = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
        (__bridge CFStringRef)name, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    NSString *encoded = CFBridgingRelease(encodedName);
    __weak DCSearchThreads *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = [NSString stringWithFormat:
            @"/channels/%@/threads/search?name=%@&sort_by=last_message_time&sort_order=desc&limit=%lu&offset=%lu",
            channelID, encoded, (unsigned long)DCSearchThreadsPageSize, (unsigned long)offset];
        NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:path token:token];
        [request setTimeoutInterval:12.0];
        [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request
                                            returningResponse:&response error:&error];
        id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *threads = [object isKindOfClass:[NSDictionary class]]
            ? [object objectForKey:@"threads"] : nil;
        BOOL success = !error && response.statusCode == 200 &&
            [threads isKindOfClass:[NSArray class]];
        BOOL hasMore = success && [[object objectForKey:@"has_more"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            DCSearchThreads *search = weakSelf;
            if (!search || generation != search.generation) return;
            search.loading = NO;
            search.requestInFlight = NO;
            if (success) {
                NSMutableSet *seen = [NSMutableSet set];
                for (NSDictionary *thread in search.remoteActive)
                    if ([thread objectForKey:@"id"]) [seen addObject:[thread objectForKey:@"id"]];
                for (NSDictionary *thread in search.remoteArchived)
                    if ([thread objectForKey:@"id"]) [seen addObject:[thread objectForKey:@"id"]];
                for (NSDictionary *thread in threads) {
                    if (![thread isKindOfClass:[NSDictionary class]]) continue;
                    NSString *identifier = [thread objectForKey:@"id"];
                    NSString *parent = [thread objectForKey:@"parent_id"];
                    if (![identifier isKindOfClass:[NSString class]] ||
                        ![parent isEqualToString:channelID] || [seen containsObject:identifier]) continue;
                    NSInteger type = [[thread objectForKey:@"type"] integerValue];
                    if (type != DCChannelTypePublicThread &&
                        type != DCChannelTypePrivateThread &&
                        type != DCChannelTypeAnnouncementThread) continue;
                    NSDictionary *metadata = [thread objectForKey:@"thread_metadata"];
                    BOOL archived = [metadata isKindOfClass:[NSDictionary class]] &&
                        [[metadata objectForKey:@"archived"] boolValue];
                    [seen addObject:identifier];
                    [(archived ? search.remoteArchived : search.remoteActive) addObject:thread];
                    if (seen.count >= DCSearchThreadsResultLimit) break;
                }
                search.offset = offset + threads.count;
                search.hasMore = hasMore && threads.count &&
                    search.remoteActive.count + search.remoteArchived.count < DCSearchThreadsResultLimit;
            } else {
                search.hasMore = NO;
                NSLog(@"[Thread Search] Request failed (HTTP %ld)", (long)response.statusCode);
            }
            [search refreshResults];
        });
    });
}

@end
