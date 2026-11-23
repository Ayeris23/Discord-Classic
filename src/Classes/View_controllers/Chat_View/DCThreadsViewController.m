//
//  DCThreadsViewController.m
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCThreadsViewController.h"
#import "DCChannel.h"
#import "DCGuild.h"
#import "DCInterfaceStyle.h"
#import "DCMemberListSectionHeaderView.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"
#import "DCUser.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat DCThreadRowHeight = 76.0f;
static const NSUInteger DCThreadResultLimit = 500;
static const NSUInteger DCThreadSearchPageSize = 25;

static UIColor *DCThreadServerListBackgroundColor(void) {
    return [UIColor colorWithRed:31.0f / 255.0f green:31.0f / 255.0f
                            blue:31.0f / 255.0f alpha:1.0f];
}

static UIColor *DCThreadChatCellBackgroundColor(void) {
    return [UIColor colorWithRed:40.0f / 255.0f green:41.0f / 255.0f
                            blue:46.0f / 255.0f alpha:1.0f];
}
static const NSUInteger DCThreadUserLookupLimit = 16;

static dispatch_queue_t DCThreadUserLookupQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.discordclassic.threads.userlookup", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *DCThreadString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL DCThreadTypeIsSupported(NSInteger type) {
    return type == DCChannelTypePublicThread ||
           type == DCChannelTypePrivateThread ||
           type == DCChannelTypeAnnouncementThread;
}

static NSComparisonResult DCThreadCompareSnowflakes(NSString *first, NSString *second) {
    if (first.length != second.length) {
        return first.length > second.length ? NSOrderedDescending : NSOrderedAscending;
    }
    return [first compare:second options:NSLiteralSearch];
}

static NSDate *DCThreadDateFromSnowflake(NSString *snowflake) {
    if (!snowflake.length) return nil;
    unsigned long long identifier = [snowflake longLongValue];
    NSTimeInterval seconds = (NSTimeInterval)((identifier >> 22) + 1420070400000ULL) / 1000.0;
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

static NSString *DCThreadRelativeTime(NSString *snowflake) {
    NSDate *date = DCThreadDateFromSnowflake(snowflake);
    if (!date) return @"Unknown activity";
    NSTimeInterval age = MAX(0.0, -[date timeIntervalSinceNow]);
    if (age < 60.0) return @"just now";
    if (age < 3600.0) return [NSString stringWithFormat:@"%ldm ago", (long)(age / 60.0)];
    if (age < 86400.0) return [NSString stringWithFormat:@"%ldh ago", (long)(age / 3600.0)];
    if (age < 604800.0) return [NSString stringWithFormat:@"%ldd ago", (long)(age / 86400.0)];
    if (age < 2592000.0) return [NSString stringWithFormat:@"%ldw ago", (long)(age / 604800.0)];
    return [DCTools prettyTimestampForDate:date];
}

@interface DCThreadListCell : UITableViewCell
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *threadTitle;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UILabel *activityLabel;
@property (nonatomic, strong) UIImageView *referencedProfileImage;
@end

@implementation DCThreadListCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleGray;

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = DCThreadChatCellBackgroundColor();
    _panel.layer.cornerRadius = 7.0f;
    _panel.layer.borderWidth = 0.5f;
    _panel.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.08f].CGColor;
    _panel.userInteractionEnabled = NO;
    [self.contentView addSubview:_panel];

    _threadTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _threadTitle.backgroundColor = [UIColor clearColor];
    _threadTitle.font = [UIFont boldSystemFontOfSize:16.0f];
    _threadTitle.textColor = [UIColor whiteColor];
    _threadTitle.lineBreakMode = UILineBreakModeTailTruncation;
    [_panel addSubview:_threadTitle];

    _referencedProfileImage = [[UIImageView alloc] initWithFrame:CGRectZero];
    _referencedProfileImage.backgroundColor = [UIColor clearColor];
    _referencedProfileImage.contentMode = UIViewContentModeScaleAspectFill;
    _referencedProfileImage.clipsToBounds = YES;
    _referencedProfileImage.layer.cornerRadius = 10.0f;
    [_panel addSubview:_referencedProfileImage];

    _authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authorLabel.backgroundColor = [UIColor clearColor];
    _authorLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    _authorLabel.textColor = [UIColor lightGrayColor];
    _authorLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_panel addSubview:_authorLabel];

    _activityLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _activityLabel.backgroundColor = [UIColor clearColor];
    _activityLabel.font = [UIFont systemFontOfSize:12.0f];
    _activityLabel.textColor = [UIColor lightGrayColor];
    _activityLabel.textAlignment = UITextAlignmentRight;
    _activityLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [_panel addSubview:_activityLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    self.panel.frame = CGRectMake(8.0f, 4.0f, MAX(0.0f, width - 16.0f), DCThreadRowHeight - 8.0f);
    CGFloat insideWidth = self.panel.bounds.size.width;
    self.threadTitle.frame = CGRectMake(12.0f, 9.0f, MAX(0.0f, insideWidth - 24.0f), 21.0f);
    self.referencedProfileImage.frame = CGRectMake(12.0f, 38.0f, 20.0f, 20.0f);
    CGFloat timeWidth = MIN(110.0f, insideWidth * 0.34f);
    self.activityLabel.frame = CGRectMake(MAX(36.0f, insideWidth - timeWidth - 12.0f),
                                          38.0f, timeWidth, 20.0f);
    self.authorLabel.frame = CGRectMake(40.0f, 38.0f,
                                       MAX(0.0f, insideWidth - 52.0f - timeWidth - 8.0f), 20.0f);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.threadTitle.text = nil;
    self.authorLabel.text = nil;
    self.activityLabel.text = nil;
    self.referencedProfileImage.image = nil;
}

@end

@interface DCThreadsViewController ()
@property (nonatomic, strong) DCChannel *parentChannel;
@property (nonatomic, strong) NSArray *activeThreads;
@property (nonatomic, strong) NSArray *archivedThreads;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableSet *requestedAuthors;
@property (nonatomic, assign) NSUInteger lookupCount;
@property (nonatomic, assign) NSUInteger requestGeneration;
@property (nonatomic, assign) BOOL loadStarted;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL loadingSearchPage;
@property (nonatomic, assign) BOOL hasMoreSearchResults;
@property (nonatomic, assign) NSUInteger nextSearchOffset;
@property (nonatomic, strong) UIView *pagingFooter;
@property (nonatomic, strong) UILabel *pagingLabel;
- (void)loadThreads;
- (void)loadNextSearchPage;
- (void)loadLegacyThreadsForGeneration:(NSUInteger)generation;
- (void)updatePagingFooter;
- (void)updateStatus;
- (void)closeThreads;
- (void)refreshVisibleAuthors:(NSNotification *)notification;
- (void)requestAuthorIfNeeded:(NSString *)authorID;
@end

@implementation DCThreadsViewController

+ (void)presentForChannel:(DCChannel *)channel
           fromController:(UIViewController *)presenter {
    if (!channel || !presenter) return;
    DCChannel *parent = channel;
    if (DCThreadTypeIsSupported(channel.type) && channel.parentID.length) {
        DCChannel *candidate = [DCServerCommunicator.sharedInstance.channels
            objectForKey:channel.parentID];
        if (candidate) {
            parent = candidate;
        } else {
            DCChannel *placeholder = [[DCChannel alloc] init];
            placeholder.snowflake = channel.parentID;
            placeholder.parentGuild = channel.parentGuild;
            parent = placeholder;
        }
    }
    if (!parent.parentGuild.snowflake.length || !parent.snowflake.length) return;

    DCThreadsViewController *viewer = [[DCThreadsViewController alloc]
        initWithStyle:UITableViewStylePlain];
    viewer.parentChannel = parent;
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:viewer];
    navigation.modalPresentationStyle = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        ? UIModalPresentationFormSheet : UIModalPresentationFullScreen;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Threads";
    self.view.backgroundColor = DCThreadServerListBackgroundColor();
    self.tableView.backgroundColor = self.view.backgroundColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = DCThreadRowHeight;
    self.tableView.sectionHeaderHeight = [DCMemberListSectionHeaderView headerHeight];

    [DCInterfaceStyle applyNavigationTitleStyleToBar:self.navigationController.navigationBar];
    [self.navigationController.navigationBar setBackgroundImage:[DCInterfaceStyle navigationBarBackgroundImage]
                                             forBarMetrics:UIBarMetricsDefault];

    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithTitle:@"Done" style:UIBarButtonItemStyleBordered
               target:self action:@selector(closeThreads)];
    [done setBackgroundImage:[DCInterfaceStyle barButtonBackgroundImage]
                  forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [done setBackgroundImage:[DCInterfaceStyle barButtonPressedBackgroundImage]
                  forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    self.navigationItem.leftBarButtonItem = done;

    UIBarButtonItem *create = [[UIBarButtonItem alloc]
        initWithTitle:@"Create" style:UIBarButtonItemStyleDone
               target:nil action:NULL];
    [create setBackgroundImage:[DCInterfaceStyle primaryBarButtonBackgroundImage]
                    forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [create setBackgroundImage:[DCInterfaceStyle primaryBarButtonPressedBackgroundImage]
                    forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    create.enabled = NO;
    self.navigationItem.rightBarButtonItem = create;

    self.requestedAuthors = [NSMutableSet set];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshVisibleAuthors:)
                                                 name:@"RELOAD USER DATA" object:nil];

    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [self.loadingSpinner startAnimating];
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.font = [UIFont systemFontOfSize:14.0f];
    self.statusLabel.textColor = [UIColor lightGrayColor];
    self.statusLabel.textAlignment = UITextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"Loading threads…";
    UIView *background = [[UIView alloc] initWithFrame:self.tableView.bounds];
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [background addSubview:self.statusLabel];
    [background addSubview:self.loadingSpinner];
    self.tableView.backgroundView = background;
    self.loading = YES;
    [self updateStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.loadStarted) [self loadThreads];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGPoint center = CGPointMake(CGRectGetMidX(self.tableView.backgroundView.bounds),
                                 CGRectGetMidY(self.tableView.backgroundView.bounds));
    self.statusLabel.frame = CGRectMake(16.0f, center.y + 12.0f,
        MAX(0.0f, self.tableView.backgroundView.bounds.size.width - 32.0f), 50.0f);
    self.loadingSpinner.center = CGPointMake(center.x, center.y - 18.0f);
}

- (void)dealloc {
    ++_requestGeneration;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)closeThreads {
    ++self.requestGeneration;
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateStatus {
    BOOL empty = self.activeThreads.count + self.archivedThreads.count == 0;
    self.tableView.backgroundView.hidden = !empty;
    self.statusLabel.hidden = !empty;
    if (self.loading) {
        self.statusLabel.text = @"Loading threads…";
        [self.loadingSpinner startAnimating];
    } else {
        [self.loadingSpinner stopAnimating];
        if (!self.statusLabel.text.length || [self.statusLabel.text isEqualToString:@"Loading threads…"])
            self.statusLabel.text = @"No threads found in this channel.";
    }
}

- (void)loadThreads {
    self.loadStarted = YES;
    self.loading = YES;
    self.hasMoreSearchResults = YES;
    self.nextSearchOffset = 0;
    self.activeThreads = @[];
    self.archivedThreads = @[];
    ++self.requestGeneration;
    [self updateStatus];
    [self loadNextSearchPage];
}

- (void)updatePagingFooter {
    if (!self.hasMoreSearchResults || !self.loadStarted) {
        if (self.tableView.tableFooterView == self.pagingFooter)
            self.tableView.tableFooterView = nil;
        return;
    }
    if (!self.pagingFooter) {
        self.pagingFooter = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 38)];
        self.pagingFooter.backgroundColor = [UIColor clearColor];
        self.pagingLabel = [[UILabel alloc] initWithFrame:self.pagingFooter.bounds];
        self.pagingLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                            UIViewAutoresizingFlexibleHeight;
        self.pagingLabel.backgroundColor = [UIColor clearColor];
        self.pagingLabel.font = [UIFont systemFontOfSize:12.0f];
        self.pagingLabel.textColor = [UIColor lightGrayColor];
        self.pagingLabel.textAlignment = UITextAlignmentCenter;
        [self.pagingFooter addSubview:self.pagingLabel];
    }
    self.pagingLabel.text = self.loadingSearchPage ? @"Loading more threads…" : @"Scroll for more threads";
    if (self.tableView.tableFooterView != self.pagingFooter)
        self.tableView.tableFooterView = self.pagingFooter;
}

- (void)loadNextSearchPage {
    if (!self.hasMoreSearchResults || self.loadingSearchPage) return;
    self.loadingSearchPage = YES;
    [self updatePagingFooter];
    NSUInteger generation = self.requestGeneration;
    NSUInteger offset = self.nextSearchOffset;
    NSString *channelID = [self.parentChannel.snowflake copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    __weak DCThreadsViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = [NSString stringWithFormat:
            @"/channels/%@/threads/search?sort_by=last_message_time&sort_order=desc&limit=%lu&offset=%lu",
            channelID, (unsigned long)DCThreadSearchPageSize, (unsigned long)offset];
        NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:path token:token];
        [request setTimeoutInterval:12.0];
        [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request
                                            returningResponse:&response error:&error];
        id result = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *threads = [result isKindOfClass:[NSDictionary class]]
            ? [result objectForKey:@"threads"] : nil;
        BOOL success = !error && response.statusCode == 200 &&
                       [threads isKindOfClass:[NSArray class]];
        BOOL hasMore = success && [[result objectForKey:@"has_more"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            DCThreadsViewController *viewer = weakSelf;
            if (!viewer || viewer.requestGeneration != generation) return;
            if (!success) {
                NSLog(@"[Threads] Search unavailable (HTTP %ld, offset %lu); using archived-thread fallback",
                      (long)response.statusCode, (unsigned long)offset);
                viewer.loadingSearchPage = NO;
                viewer.hasMoreSearchResults = NO;
                [viewer updatePagingFooter];
                if (offset == 0) [viewer loadLegacyThreadsForGeneration:generation];
                return;
            }

            NSMutableArray *active = [viewer.activeThreads mutableCopy] ?: [NSMutableArray array];
            NSMutableArray *archived = [viewer.archivedThreads mutableCopy] ?: [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *thread in active) {
                NSString *identifier = DCThreadString([thread objectForKey:@"id"]);
                if (identifier) [seen addObject:identifier];
            }
            for (NSDictionary *thread in archived) {
                NSString *identifier = DCThreadString([thread objectForKey:@"id"]);
                if (identifier) [seen addObject:identifier];
            }
            for (NSDictionary *thread in threads) {
                if (![thread isKindOfClass:[NSDictionary class]]) continue;
                NSString *identifier = DCThreadString([thread objectForKey:@"id"]);
                NSString *parentID = DCThreadString([thread objectForKey:@"parent_id"]);
                if (!identifier.length || ![parentID isEqualToString:channelID] ||
                    [seen containsObject:identifier]) continue;
                id rawType = [thread objectForKey:@"type"];
                NSInteger type = [rawType respondsToSelector:@selector(integerValue)]
                    ? [rawType integerValue] : -1;
                if (!DCThreadTypeIsSupported(type)) continue;
                NSDictionary *metadata = [thread objectForKey:@"thread_metadata"];
                BOOL isArchived = [metadata isKindOfClass:[NSDictionary class]] &&
                    [[metadata objectForKey:@"archived"] boolValue];
                [seen addObject:identifier];
                if (isArchived) [archived addObject:thread];
                else [active addObject:thread];
                if (active.count + archived.count >= DCThreadResultLimit) break;
            }
            viewer.activeThreads = active;
            viewer.archivedThreads = archived;
            viewer.nextSearchOffset = offset + threads.count;
            viewer.hasMoreSearchResults = hasMore && threads.count > 0 &&
                active.count + archived.count < DCThreadResultLimit;
            viewer.loadingSearchPage = NO;
            viewer.loading = NO;
            [viewer.tableView reloadData];
            [viewer updateStatus];
            [viewer updatePagingFooter];
            NSLog(@"[Threads] Search page %lu: %lu received, %lu active, %lu archived, more=%@",
                  (unsigned long)(offset / DCThreadSearchPageSize + 1),
                  (unsigned long)threads.count, (unsigned long)active.count,
                  (unsigned long)archived.count, viewer.hasMoreSearchResults ? @"YES" : @"NO");
        });
    });
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.tableView || !self.hasMoreSearchResults ||
        self.loadingSearchPage || self.loading) return;
    CGFloat remaining = scrollView.contentSize.height -
        (scrollView.contentOffset.y + scrollView.bounds.size.height);
    if (remaining < 180.0f) [self loadNextSearchPage];
}

- (void)loadLegacyThreadsForGeneration:(NSUInteger)generation {
    NSString *guildID = [self.parentChannel.parentGuild.snowflake copy];
    NSString *channelID = [self.parentChannel.snowflake copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    __weak DCThreadsViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *paths = @[
            [NSString stringWithFormat:@"/guilds/%@/threads/active", guildID],
            [NSString stringWithFormat:@"/channels/%@/threads/archived/public?limit=100", channelID],
            [NSString stringWithFormat:@"/channels/%@/users/@me/threads/archived/private?limit=100", channelID],
            [NSString stringWithFormat:@"/channels/%@/threads/archived/private?limit=100", channelID]
        ];
        NSMutableArray *active = [NSMutableArray array];
        NSMutableArray *archived = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        BOOL succeeded = NO;
        for (NSUInteger endpoint = 0; endpoint < paths.count; endpoint++) {
            NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:
                [paths objectAtIndex:endpoint] token:token];
            [request setTimeoutInterval:10.0];
            [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
            NSHTTPURLResponse *response = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                returningResponse:&response error:nil];
            if (response.statusCode != 200 || !data.length) continue;
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSArray *threads = [object objectForKey:@"threads"];
            if (![threads isKindOfClass:[NSArray class]]) continue;
            succeeded = YES;
            for (NSDictionary *thread in threads) {
                if (![thread isKindOfClass:[NSDictionary class]]) continue;
                NSString *identifier = DCThreadString([thread objectForKey:@"id"]);
                NSString *parentID = DCThreadString([thread objectForKey:@"parent_id"]);
                if (!identifier.length || ![parentID isEqualToString:channelID] ||
                    [seen containsObject:identifier]) continue;
                id rawType = [thread objectForKey:@"type"];
                NSInteger type = [rawType respondsToSelector:@selector(integerValue)]
                    ? [rawType integerValue] : -1;
                if (!DCThreadTypeIsSupported(type)) continue;
                [seen addObject:identifier];
                if (endpoint == 0) [active addObject:thread];
                else [archived addObject:thread];
            }
        }
        NSComparator newestFirst = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *aDate = DCThreadString([a objectForKey:@"last_message_id"]);
            NSString *bDate = DCThreadString([b objectForKey:@"last_message_id"]);
            if (!aDate.length) aDate = DCThreadString([a objectForKey:@"id"]);
            if (!bDate.length) bDate = DCThreadString([b objectForKey:@"id"]);
            return DCThreadCompareSnowflakes(bDate, aDate);
        };
        [active sortUsingComparator:newestFirst];
        [archived sortUsingComparator:newestFirst];
        if (active.count > DCThreadResultLimit)
            [active removeObjectsInRange:NSMakeRange(DCThreadResultLimit, active.count - DCThreadResultLimit)];
        NSUInteger room = DCThreadResultLimit - active.count;
        if (archived.count > room)
            [archived removeObjectsInRange:NSMakeRange(room, archived.count - room)];

        dispatch_async(dispatch_get_main_queue(), ^{
            DCThreadsViewController *viewer = weakSelf;
            if (!viewer || viewer.requestGeneration != generation) return;
            NSArray *cachedChannels = [DCServerCommunicator.sharedInstance.channels allValues];
            for (DCChannel *channel in cachedChannels) {
                if (![channel isKindOfClass:[DCChannel class]] ||
                    !DCThreadTypeIsSupported(channel.type) ||
                    ![channel.parentID isEqualToString:channelID] ||
                    !channel.snowflake.length || [seen containsObject:channel.snowflake]) continue;
                NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"id": channel.snowflake,
                    @"parent_id": channelID,
                    @"guild_id": guildID,
                    @"name": channel.name ?: @"Untitled Thread",
                    @"type": @(channel.type)
                }];
                if (channel.lastMessageId.length)
                    [payload setObject:channel.lastMessageId forKey:@"last_message_id"];
                [seen addObject:channel.snowflake];
                [active addObject:payload];
            }
            [active sortUsingComparator:newestFirst];
            if (active.count > DCThreadResultLimit)
                [active removeObjectsInRange:NSMakeRange(DCThreadResultLimit, active.count - DCThreadResultLimit)];
            NSUInteger available = DCThreadResultLimit - active.count;
            if (archived.count > available)
                [archived removeObjectsInRange:NSMakeRange(available, archived.count - available)];
            viewer.activeThreads = active;
            viewer.archivedThreads = archived;
            viewer.loading = NO;
            if (!succeeded && !active.count) viewer.statusLabel.text = @"Unable to load threads.";
            [viewer.tableView reloadData];
            [viewer updateStatus];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.activeThreads.count : self.archivedThreads.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if ([self tableView:tableView numberOfRowsInSection:section] == 0) return nil;
    DCMemberListSectionHeaderView *header = [[DCMemberListSectionHeaderView alloc]
        initWithFrame:CGRectMake(0.0f, 0.0f, tableView.bounds.size.width,
                                 [DCMemberListSectionHeaderView headerHeight])];
    header.title = section == 0 ? @"ACTIVE THREADS" : @"ARCHIVED THREADS";
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self tableView:tableView numberOfRowsInSection:section]
        ? [DCMemberListSectionHeaderView headerHeight] : 0.0f;
}

- (NSDictionary *)threadAtIndexPath:(NSIndexPath *)path {
    NSArray *section = path.section == 0 ? self.activeThreads : self.archivedThreads;
    return path.row < (NSInteger)section.count ? [section objectAtIndex:path.row] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *reuseID = @"DCThreadListCell";
    DCThreadListCell *cell = (DCThreadListCell *)[tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[DCThreadListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:reuseID];
    NSDictionary *thread = [self threadAtIndexPath:path];
    cell.threadTitle.text = DCThreadString([thread objectForKey:@"name"]) ?: @"Untitled Thread";
    NSString *lastID = DCThreadString([thread objectForKey:@"last_message_id"]);
    cell.activityLabel.text = DCThreadRelativeTime(lastID ?: DCThreadString([thread objectForKey:@"id"]));
    NSString *ownerID = DCThreadString([thread objectForKey:@"owner_id"]);
    DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:ownerID];
    cell.authorLabel.text = user ? [user displayNameInGuild:self.parentChannel.parentGuild] : @"Unknown author";
    cell.authorLabel.textColor = user
        ? [DCInterfaceStyle roleColorForUser:user inGuild:self.parentChannel.parentGuild]
        : [UIColor lightGrayColor];
    UIImage *avatar = user ? [DCTools cachedUserAvatar:user inGuild:self.parentChannel.parentGuild] : nil;
    cell.referencedProfileImage.image = avatar ?: user.profileImage ?: [DCInterfaceStyle defaultAvatarImageAtIndex:0];
    if (user && !avatar) [DCTools getUserAvatar:user inGuild:self.parentChannel.parentGuild];
    if (ownerID.length && (!user ||
        ![user.guildRoleIDs objectForKey:self.parentChannel.parentGuild.snowflake])) {
        [self requestAuthorIfNeeded:ownerID];
    }
    return cell;
}

- (void)refreshVisibleAuthors:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshVisibleAuthors:notification]; });
        return;
    }
    if (!self.isViewLoaded) return;
    DCUser *changedUser = [notification.object isKindOfClass:[DCUser class]]
        ? (DCUser *)notification.object : nil;
    for (NSIndexPath *path in [self.tableView indexPathsForVisibleRows]) {
        if (path.section >= 2 || path.row >= [self tableView:self.tableView numberOfRowsInSection:path.section]) continue;
        DCThreadListCell *cell = (DCThreadListCell *)[self.tableView cellForRowAtIndexPath:path];
        if (![cell isKindOfClass:[DCThreadListCell class]]) continue;
        NSDictionary *thread = [self threadAtIndexPath:path];
        NSString *ownerID = DCThreadString([thread objectForKey:@"owner_id"]);
        if (changedUser && ![changedUser.snowflake isEqualToString:ownerID]) continue;
        DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:ownerID];
        if (!user) continue;
        cell.authorLabel.text = [user displayNameInGuild:self.parentChannel.parentGuild];
        cell.authorLabel.textColor = [DCInterfaceStyle roleColorForUser:user
                                                                 inGuild:self.parentChannel.parentGuild];
        UIImage *avatar = [DCTools cachedUserAvatar:user inGuild:self.parentChannel.parentGuild];
        cell.referencedProfileImage.image = avatar ?: user.profileImage ?: [DCInterfaceStyle defaultAvatarImageAtIndex:0];
    }
}

- (void)requestAuthorIfNeeded:(NSString *)authorID {
    if (!authorID.length || [self.requestedAuthors containsObject:authorID] ||
        self.lookupCount >= DCThreadUserLookupLimit) return;
    [self.requestedAuthors addObject:authorID];
    ++self.lookupCount;
    NSUInteger generation = self.requestGeneration;
    NSString *guildID = [self.parentChannel.parentGuild.snowflake copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    NSString *userID = [authorID copy];
    __weak DCThreadsViewController *weakSelf = self;
    dispatch_async(DCThreadUserLookupQueue(), ^{
        DCThreadsViewController *viewer = weakSelf;
        if (!viewer || viewer.requestGeneration != generation) return;
        NSString *path = [NSString stringWithFormat:@"/guilds/%@/members/%@", guildID, userID];
        NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:path token:token];
        [request setTimeoutInterval:12.0];
        NSHTTPURLResponse *response = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request
                                            returningResponse:&response error:nil];
        if (response.statusCode != 200 || !data.length) return;
        id member = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![member isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *userJSON = [member objectForKey:@"user"];
        if (![userJSON isKindOfClass:[NSDictionary class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DCThreadsViewController *currentViewer = weakSelf;
            if (!currentViewer || currentViewer.requestGeneration != generation) return;
            DCUser *user = [DCTools convertJsonUser:userJSON cache:YES];
            if (!user) return;
            [DCServerCommunicator.sharedInstance applyGuildProfileFromMember:member
                                                                        toUser:user
                                                                       guildID:guildID
                                                                authoritative:YES];
            [DCTools getUserAvatar:user inGuild:currentViewer.parentChannel.parentGuild];
            [currentViewer refreshVisibleAuthors:nil];
        });
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *thread = [self threadAtIndexPath:path];
    if (!thread) return;
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSMutableDictionary *threadPayload = [thread mutableCopy];
    if (![threadPayload objectForKey:@"guild_id"] && self.parentChannel.parentGuild.snowflake.length) {
        [threadPayload setObject:self.parentChannel.parentGuild.snowflake forKey:@"guild_id"];
    }
    ++self.requestGeneration;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DCThreadOpenRequested"
                                                            object:nil
                                                          userInfo:@{@"thread": threadPayload}];
    }];
}

@end
