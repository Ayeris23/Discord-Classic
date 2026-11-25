//
//  DCThreadsViewController.m
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCThreadsViewController.h"
#import "DCChannel.h"
#import "DCThreadCreateViewController.h"
#import "DCSearchUI.h"
#import "DCSearchThreads.h"
#import "DCGuild.h"
#import "DCInterfaceStyle.h"
#import "DCMemberListSectionHeaderView.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"
#import "DCUser.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat DCThreadRowHeight = 68.0f;
static const NSUInteger DCThreadResultLimit = 500;
static const NSUInteger DCThreadSearchPageSize = 25;

static UIColor *DCThreadChatCellBackgroundColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithRed:40.0f / 255.0f green:41.0f / 255.0f
                                blue:46.0f / 255.0f alpha:1.0f];
    });
    return color;
}

static UIColor *DCThreadAlternateCellBackgroundColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithRed:33.0f / 255.0f green:34.0f / 255.0f
                                blue:38.0f / 255.0f alpha:1.0f];
    });
    return color;
}

static const NSUInteger DCThreadMemberBatchSize = 32;

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

static NSComparator DCThreadNewestFirstComparator(void) {
    return ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *aID = DCThreadString([a objectForKey:@"last_message_id"]);
        NSString *bID = DCThreadString([b objectForKey:@"last_message_id"]);
        if (!aID.length) aID = DCThreadString([a objectForKey:@"id"]);
        if (!bID.length) bID = DCThreadString([b objectForKey:@"id"]);
        return DCThreadCompareSnowflakes(bID, aID);
    };
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
    if (age < 31536000.0) return [NSString stringWithFormat:@"%ldmo ago", (long)(age / 2592000.0)];
    return [NSString stringWithFormat:@"%ldy ago", (long)(age / 31536000.0)];
}

@interface DCThreadListCell : UITableViewCell
@property (nonatomic, strong) UIView *separatorHigh;
@property (nonatomic, strong) UIView *separatorLow;
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

    UIView *rowBackground = [[UIView alloc] initWithFrame:self.bounds];
    rowBackground.backgroundColor = DCThreadChatCellBackgroundColor();
    rowBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundView = rowBackground;

    _separatorHigh = [[UIView alloc] initWithFrame:CGRectZero];
    _separatorHigh.backgroundColor = [UIColor colorWithRed:31.0f / 255.0f
                                                     green:32.0f / 255.0f
                                                      blue:36.0f / 255.0f alpha:1.0f];
    _separatorHigh.userInteractionEnabled = NO;
    [self.contentView addSubview:_separatorHigh];

    _separatorLow = [[UIView alloc] initWithFrame:CGRectZero];
    _separatorLow.backgroundColor = [UIColor colorWithRed:48.0f / 255.0f
                                                    green:49.0f / 255.0f
                                                     blue:56.0f / 255.0f alpha:1.0f];
    _separatorLow.userInteractionEnabled = NO;
    [self.contentView addSubview:_separatorLow];

    _threadTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _threadTitle.backgroundColor = [UIColor clearColor];
    _threadTitle.font = [UIFont boldSystemFontOfSize:16.0f];
    _threadTitle.textColor = [UIColor whiteColor];
    _threadTitle.shadowColor = [UIColor blackColor];
    _threadTitle.shadowOffset = CGSizeMake(0.0f, 1.0f);
    _threadTitle.lineBreakMode = UILineBreakModeTailTruncation;
    [self.contentView addSubview:_threadTitle];

    _referencedProfileImage = [[UIImageView alloc] initWithFrame:CGRectZero];
    _referencedProfileImage.backgroundColor = [UIColor clearColor];
    _referencedProfileImage.contentMode = UIViewContentModeScaleAspectFill;
    _referencedProfileImage.clipsToBounds = YES;
    _referencedProfileImage.layer.cornerRadius = 10.0f;
    [self.contentView addSubview:_referencedProfileImage];

    _authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authorLabel.backgroundColor = [UIColor clearColor];
    _authorLabel.font = [UIFont boldSystemFontOfSize:13.0f];
    _authorLabel.textColor = [UIColor lightGrayColor];
    _authorLabel.shadowColor = [UIColor colorWithRed:14.0f / 255.0f
                                                  green:15.0f / 255.0f
                                                   blue:16.0f / 255.0f alpha:1.0f];
    _authorLabel.shadowOffset = CGSizeMake(0.0f, 1.0f);
    _authorLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [self.contentView addSubview:_authorLabel];

    _activityLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _activityLabel.backgroundColor = [UIColor clearColor];
    _activityLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:10.0f];
    if (!_activityLabel.font) _activityLabel.font = [UIFont systemFontOfSize:10.0f];
    _activityLabel.textColor = [UIColor colorWithWhite:128.0f / 255.0f alpha:1.0f];
    _activityLabel.shadowColor = [UIColor blackColor];
    _activityLabel.shadowOffset = CGSizeMake(0.0f, 1.0f);
    _activityLabel.textAlignment = UITextAlignmentRight;
    _activityLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [self.contentView addSubview:_activityLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat height = self.contentView.bounds.size.height;
    self.threadTitle.frame = CGRectMake(12.0f, 10.0f, MAX(0.0f, width - 24.0f), 20.0f);
    self.referencedProfileImage.frame = CGRectMake(12.0f, 37.0f, 20.0f, 20.0f);
    CGFloat timeWidth = floorf(MIN(110.0f, width * 0.34f));
    CGFloat timeX = floorf(MAX(36.0f, width - timeWidth - 12.0f));
    self.activityLabel.frame = CGRectMake(timeX, 40.0f, timeWidth, 16.0f);
    self.authorLabel.frame = CGRectMake(40.0f, 37.0f,
                                       MAX(0.0f, timeX - 48.0f), 20.0f);
    self.separatorHigh.frame = CGRectMake(0.0f, MAX(0.0f, height - 2.0f), width, 1.0f);
    self.separatorLow.frame = CGRectMake(0.0f, MAX(0.0f, height - 1.0f), width, 1.0f);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.threadTitle.text = nil;
    self.authorLabel.text = nil;
    self.activityLabel.text = nil;
    self.referencedProfileImage.image = nil;
}

@end

@interface DCThreadsViewController () <UISearchBarDelegate>
@property (nonatomic, strong) DCChannel *parentChannel;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) DCSearchThreads *threadSearch;
@property (nonatomic, strong) NSArray *activeThreads;
@property (nonatomic, strong) NSArray *archivedThreads;
@property (nonatomic, strong) NSMutableDictionary *cachedThreadPayloads;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableSet *requestedAuthors;
@property (nonatomic, strong) NSMutableSet *pendingAuthors;
@property (nonatomic, strong) NSMutableSet *profileRequestedAuthors;
@property (nonatomic, assign) BOOL authorBatchScheduled;
@property (nonatomic, assign) NSUInteger requestGeneration;
@property (nonatomic, assign) BOOL loadStarted;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL loadingSearchPage;
@property (nonatomic, assign) BOOL hasMoreSearchResults;
@property (nonatomic, assign) NSUInteger nextSearchOffset;
@property (nonatomic, strong) UIView *pagingFooter;
@property (nonatomic, strong) UILabel *pagingLabel;
- (void)showCreateThread:(id)sender;
- (void)updateCreateButtonAvailability;
- (void)loadThreads;
- (void)loadNextSearchPage;
- (void)loadLegacyThreadsForGeneration:(NSUInteger)generation;
- (void)updatePagingFooter;
- (void)updateStatus;
- (void)closeThreads;
- (void)refreshVisibleAuthors:(NSNotification *)notification;
- (void)configureAuthorInCell:(DCThreadListCell *)cell forThread:(NSDictionary *)thread;
- (void)requestAuthorIfNeeded:(NSString *)authorID;
- (void)flushPendingAuthorRequests;
- (void)fetchVisibleAuthorsMissingFromGateway:(NSArray *)authorIDs;
- (void)fetchAuthorProfile:(NSString *)authorID;
- (NSArray *)visibleThreadsForSection:(NSInteger)section;
- (void)threadSearchDidUpdate;
- (void)refreshSearchCancelButton;
- (NSDictionary *)threadPayloadForCachedChannel:(DCChannel *)channel;
- (void)mergeCachedThreadsIntoActive:(NSMutableArray *)active archived:(NSMutableArray *)archived;
- (void)channelRegistryDidChange:(NSNotification *)notification;
- (void)applicationBecameActive:(NSNotification *)notification;
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
    self.view.backgroundColor = DCThreadChatCellBackgroundColor();
    self.tableView.backgroundColor = self.view.backgroundColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = DCThreadRowHeight;
    self.tableView.sectionHeaderHeight = [DCMemberListSectionHeaderView headerHeight];
    self.searchBar = [DCSearchUI searchBarWithPlaceholder:@"Search Threads" delegate:self];
    self.searchBar.frame = CGRectMake(0.0f, 0.0f, self.tableView.bounds.size.width, 44.0f);
    self.tableView.tableHeaderView = self.searchBar;

    self.threadSearch = [[DCSearchThreads alloc] initWithChannelID:self.parentChannel.snowflake];
    __weak DCThreadsViewController *weakSelf = self;
    self.threadSearch.resultsChanged = ^{
        DCThreadsViewController *viewer = weakSelf;
        if (viewer) [viewer threadSearchDidUpdate];
    };

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
               target:self action:@selector(showCreateThread:)];
    [create setBackgroundImage:[DCInterfaceStyle primaryBarButtonBackgroundImage]
                    forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [create setBackgroundImage:[DCInterfaceStyle primaryBarButtonPressedBackgroundImage]
                    forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    self.navigationItem.rightBarButtonItem = create;
    [self updateCreateButtonAvailability];

    self.requestedAuthors = [NSMutableSet set];
    self.pendingAuthors = [NSMutableSet set];
    self.profileRequestedAuthors = [NSMutableSet set];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshVisibleAuthors:)
                                                 name:@"RELOAD USER DATA" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshVisibleAuthors:)
                                                 name:@"GuildMemberListUpdated" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(channelRegistryDidChange:)
                                                 name:@"RELOAD CHANNEL LIST" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationBecameActive:)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateCreateButtonAvailability];
}

- (void)updateCreateButtonAvailability {
    uint64_t permission = [DCServerCommunicator.sharedInstance
        effectivePermissionsForChannel:self.parentChannel];
    DCChannel *registeredParent = [DCServerCommunicator.sharedInstance.channels
        objectForKey:self.parentChannel.snowflake];
    BOOL canCreate = registeredParent != nil &&
        self.parentChannel.type == DCChannelTypeGuildText &&
        (permission & DCPermissionViewChannel) != 0 &&
        (permission & (DCPermissionCreatePublicThreads |
                       DCPermissionCreatePrivateThreads)) != 0;
    self.navigationItem.rightBarButtonItem.enabled = canCreate;
}

- (void)showCreateThread:(id)sender {
    if (!self.navigationItem.rightBarButtonItem.enabled) return;
    self.navigationItem.backBarButtonItem =
        [DCInterfaceStyle navigationBackButtonItemWithTitle:@"Threads"];
    DCThreadCreateViewController *creator = [[DCThreadCreateViewController alloc]
        initWithParentChannel:self.parentChannel];
    [self.navigationController pushViewController:creator animated:YES];
}

- (NSDictionary *)threadPayloadForCachedChannel:(DCChannel *)channel {
    if (!DCThreadTypeIsSupported(channel.type) ||
        ![channel.parentID isEqualToString:self.parentChannel.snowflake] ||
        !channel.snowflake.length) return nil;
    if (channel.parentGuild.snowflake.length &&
        ![channel.parentGuild.snowflake isEqualToString:self.parentChannel.parentGuild.snowflake])
        return nil;

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id": channel.snowflake,
        @"parent_id": self.parentChannel.snowflake,
        @"guild_id": self.parentChannel.parentGuild.snowflake,
        @"name": channel.name ?: @"Untitled Thread",
        @"type": @(channel.type)
    }];
    if (channel.lastMessageId.length)
        [payload setObject:channel.lastMessageId forKey:@"last_message_id"];
    return payload;
}

- (void)mergeCachedThreadsIntoActive:(NSMutableArray *)active archived:(NSMutableArray *)archived {
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *thread in active) {
        NSString *identifier = DCThreadString([thread objectForKey:@"id"]);
        if (identifier.length) [seen addObject:identifier];
    }
    for (NSDictionary *thread in archived) {
        NSString *identifier = DCThreadString([thread objectForKey:@"id"]);
        if (identifier.length) [seen addObject:identifier];
    }
    for (NSDictionary *payload in [self.cachedThreadPayloads allValues]) {
        NSString *identifier = DCThreadString([payload objectForKey:@"id"]);
        if (!identifier.length || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        [active addObject:payload];
    }
    [active sortUsingComparator:DCThreadNewestFirstComparator()];
    [archived sortUsingComparator:DCThreadNewestFirstComparator()];
    if (active.count > DCThreadResultLimit)
        [active removeObjectsInRange:NSMakeRange(DCThreadResultLimit, active.count - DCThreadResultLimit)];
    NSUInteger remaining = DCThreadResultLimit - active.count;
    if (archived.count > remaining)
        [archived removeObjectsInRange:NSMakeRange(remaining, archived.count - remaining)];
}

- (void)channelRegistryDidChange:(NSNotification *)notification {
    DCChannel *channel = notification.object;
    if (![channel isKindOfClass:[DCChannel class]]) return;
    NSDictionary *cachedPayload = [self threadPayloadForCachedChannel:channel];
    if (!cachedPayload) return;

    NSString *identifier = [cachedPayload objectForKey:@"id"];
    [self.cachedThreadPayloads setObject:cachedPayload forKey:identifier];
    NSMutableArray *active = [self.activeThreads mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *archived = [self.archivedThreads mutableCopy] ?: [NSMutableArray array];
    BOOL changed = NO;
    BOOL found = NO;
    for (NSMutableArray *section in @[active, archived]) {
        for (NSUInteger i = 0; i < section.count; i++) {
            NSDictionary *existing = [section objectAtIndex:i];
            if (![DCThreadString([existing objectForKey:@"id"]) isEqualToString:identifier]) continue;
            found = YES;
            NSMutableDictionary *updated = [existing mutableCopy];
            if (channel.name.length)
                [updated setObject:channel.name forKey:@"name"];
            NSString *lastID = [cachedPayload objectForKey:@"last_message_id"];
            if (lastID.length) [updated setObject:lastID forKey:@"last_message_id"];
            if (![updated isEqualToDictionary:existing]) {
                [section replaceObjectAtIndex:i withObject:updated];
                changed = YES;
            }
            break;
        }
        if (found) break;
    }
    if (!found) {
        [active addObject:cachedPayload];
        changed = YES;
    }
    if (!changed) return;
    [active sortUsingComparator:DCThreadNewestFirstComparator()];
    [archived sortUsingComparator:DCThreadNewestFirstComparator()];
    if (active.count > DCThreadResultLimit)
        [active removeObjectsInRange:NSMakeRange(DCThreadResultLimit, active.count - DCThreadResultLimit)];
    NSUInteger available = DCThreadResultLimit - active.count;
    if (archived.count > available)
        [archived removeObjectsInRange:NSMakeRange(available, archived.count - available)];
    self.activeThreads = active;
    self.archivedThreads = archived;
    [self.threadSearch updateLoadedActiveThreads:active archivedThreads:archived];
    if (!self.threadSearch.query.length) [self.tableView reloadData];
    [self updateStatus];
}

- (void)applicationBecameActive:(NSNotification *)notification {
    if (self.loadStarted && self.isViewLoaded && self.view.window &&
        self.navigationController.topViewController == self && !self.loadingSearchPage)
        [self loadThreads];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self loadThreads];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (fabsf(self.searchBar.frame.size.width - self.tableView.bounds.size.width) > 0.5f) {
        CGRect headerFrame = self.searchBar.frame;
        headerFrame.size.width = self.tableView.bounds.size.width;
        self.searchBar.frame = headerFrame;
        self.tableView.tableHeaderView = self.searchBar;
    }
    CGPoint center = CGPointMake(CGRectGetMidX(self.tableView.backgroundView.bounds),
                                 CGRectGetMidY(self.tableView.backgroundView.bounds));
    self.statusLabel.frame = CGRectMake(16.0f, center.y + 12.0f,
        MAX(0.0f, self.tableView.backgroundView.bounds.size.width - 32.0f), 50.0f);
    self.loadingSpinner.center = CGPointMake(center.x, center.y - 18.0f);
}

- (void)dealloc {
    ++_requestGeneration;
    [self.threadSearch cancel];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)closeThreads {
    ++self.requestGeneration;
    [self.threadSearch cancel];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray *)visibleThreadsForSection:(NSInteger)section {
    if (self.threadSearch.query.length)
        return section == 0 ? self.threadSearch.activeResults : self.threadSearch.archivedResults;
    return section == 0 ? self.activeThreads : self.archivedThreads;
}

- (void)threadSearchDidUpdate {
    if (!self.isViewLoaded) return;
    [self.tableView reloadData];
    [self updateStatus];
    [self updatePagingFooter];
}

- (void)updateStatus {
    BOOL searching = self.threadSearch.query.length > 0;
    BOOL empty = [self visibleThreadsForSection:0].count +
                 [self visibleThreadsForSection:1].count == 0;
    self.tableView.backgroundView.hidden = !empty;
    self.statusLabel.hidden = !empty;
    BOOL showSpinner = searching ? self.threadSearch.loading : self.loading;
    if (showSpinner) {
        self.statusLabel.text = searching ? @"Searching threads…" : @"Loading threads…";
        [self.loadingSpinner startAnimating];
    } else {
        [self.loadingSpinner stopAnimating];
        self.statusLabel.text = searching ? @"No matching thread names." :
            @"No threads found in this channel.";
    }
}

- (void)loadThreads {
    ++self.requestGeneration;
    self.loadStarted = YES;
    self.loading = YES;
    self.loadingSearchPage = NO;
    self.hasMoreSearchResults = YES;
    self.nextSearchOffset = 0;
    self.cachedThreadPayloads = [NSMutableDictionary dictionary];
    NSMutableArray *known = [NSMutableArray array];
    for (DCChannel *channel in [DCServerCommunicator.sharedInstance.channels allValues]) {
        if (![channel isKindOfClass:[DCChannel class]]) continue;
        NSDictionary *payload = [self threadPayloadForCachedChannel:channel];
        if (payload) [known addObject:payload];
    }
    [known sortUsingComparator:DCThreadNewestFirstComparator()];
    for (NSUInteger i = 0; i < MIN(known.count, DCThreadResultLimit); i++) {
        NSDictionary *payload = [known objectAtIndex:i];
        [self.cachedThreadPayloads setObject:payload forKey:[payload objectForKey:@"id"]];
    }
    NSMutableArray *active = [NSMutableArray array];
    NSMutableArray *archived = [NSMutableArray array];
    [self mergeCachedThreadsIntoActive:active archived:archived];
    self.activeThreads = active;
    self.archivedThreads = archived;
    [self.threadSearch updateLoadedActiveThreads:active archivedThreads:archived];
    if (!self.threadSearch.query.length) [self.tableView reloadData];
    [self updateStatus];
    [self loadNextSearchPage];
}

- (void)updatePagingFooter {
    BOOL searching = self.threadSearch.query.length > 0;
    BOOL more = searching ? self.threadSearch.hasMore : self.hasMoreSearchResults;
    BOOL fetching = searching ? self.threadSearch.loading : self.loadingSearchPage;
    if ((!more && !fetching) || (!searching && !self.loadStarted)) {
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
    self.pagingLabel.text = searching
        ? (fetching ? @"Searching threads…" : @"Scroll for more matches")
        : (fetching ? @"Loading more threads…" : @"Scroll for more threads");
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

            NSMutableArray *active = offset == 0 ? [NSMutableArray array] :
                ([viewer.activeThreads mutableCopy] ?: [NSMutableArray array]);
            NSMutableArray *archived = offset == 0 ? [NSMutableArray array] :
                ([viewer.archivedThreads mutableCopy] ?: [NSMutableArray array]);
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
            [viewer mergeCachedThreadsIntoActive:active archived:archived];
            viewer.activeThreads = active;
            viewer.archivedThreads = archived;
            [viewer.threadSearch updateLoadedActiveThreads:active archivedThreads:archived];
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
    if (scrollView != self.tableView) return;
    CGFloat remaining = scrollView.contentSize.height -
        (scrollView.contentOffset.y + scrollView.bounds.size.height);
    if (remaining >= 180.0f) return;
    if (self.threadSearch.query.length) {
        [self.threadSearch loadNextPage];
    } else if (self.hasMoreSearchResults && !self.loadingSearchPage && !self.loading) {
        [self loadNextSearchPage];
    }
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
            [viewer mergeCachedThreadsIntoActive:active archived:archived];
            viewer.activeThreads = active;
            viewer.archivedThreads = archived;
            [viewer.threadSearch updateLoadedActiveThreads:active archivedThreads:archived];
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
    return [self visibleThreadsForSection:section].count;
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
    NSArray *section = [self visibleThreadsForSection:path.section];
    return path.row < (NSInteger)section.count ? [section objectAtIndex:path.row] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *reuseID = @"DCThreadListCell";
    DCThreadListCell *cell = (DCThreadListCell *)[tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[DCThreadListCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:reuseID];
    NSUInteger stripeIndex = path.row +
        (path.section == 1 ? [self visibleThreadsForSection:0].count : 0);
    cell.backgroundView.backgroundColor = (stripeIndex & 1)
        ? DCThreadAlternateCellBackgroundColor() : DCThreadChatCellBackgroundColor();
    NSDictionary *thread = [self threadAtIndexPath:path];
    cell.threadTitle.text = DCThreadString([thread objectForKey:@"name"]) ?: @"Untitled Thread";
    NSString *lastID = DCThreadString([thread objectForKey:@"last_message_id"]);
    cell.activityLabel.text = DCThreadRelativeTime(lastID ?: DCThreadString([thread objectForKey:@"id"]));
    [self configureAuthorInCell:cell forThread:thread];
    return cell;
}

- (void)configureAuthorInCell:(DCThreadListCell *)cell forThread:(NSDictionary *)thread {
    NSString *ownerID = DCThreadString([thread objectForKey:@"owner_id"]);
    DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:ownerID];
    NSString *displayName = [user displayNameInGuild:self.parentChannel.parentGuild];
    BOOL hasIdentity = displayName.length > 0;
    cell.authorLabel.text = hasIdentity ? displayName : @"Unknown author";
    cell.authorLabel.textColor = hasIdentity
        ? [DCInterfaceStyle roleColorForUser:user inGuild:self.parentChannel.parentGuild]
        : [UIColor lightGrayColor];
    UIImage *avatar = hasIdentity
        ? [DCTools cachedUserAvatar:user inGuild:self.parentChannel.parentGuild] : nil;
    cell.referencedProfileImage.image = avatar ?:
        (hasIdentity ? user.profileImage : nil) ?: [DCInterfaceStyle defaultAvatarImageAtIndex:0];
    if (hasIdentity && !avatar) {
        [DCTools getUserAvatar:user inGuild:self.parentChannel.parentGuild];
    }
    if (ownerID.length && (!hasIdentity ||
        ![user.guildRoleIDs objectForKey:self.parentChannel.parentGuild.snowflake])) {
        [self requestAuthorIfNeeded:ownerID];
    }
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
        [self configureAuthorInCell:cell forThread:thread];
    }
}

- (void)requestAuthorIfNeeded:(NSString *)authorID {
    if (!authorID.length || [self.requestedAuthors containsObject:authorID]) return;
    [self.requestedAuthors addObject:authorID];
    [self.pendingAuthors addObject:authorID];
    if (self.authorBatchScheduled) return;
    self.authorBatchScheduled = YES;
    [self performSelector:@selector(flushPendingAuthorRequests)
               withObject:nil afterDelay:0.05];
}

- (void)flushPendingAuthorRequests {
    self.authorBatchScheduled = NO;
    if (!self.pendingAuthors.count) return;
    NSArray *identifiers = [self.pendingAuthors allObjects];
    NSUInteger count = MIN(DCThreadMemberBatchSize, identifiers.count);
    NSArray *batch = [identifiers subarrayWithRange:NSMakeRange(0, count)];
    [self.pendingAuthors minusSet:[NSSet setWithArray:batch]];

    NSString *guildID = self.parentChannel.parentGuild.snowflake;
    if (guildID.length) {
        [DCServerCommunicator.sharedInstance requestMemberChunkForUserIds:batch
                                                                   inGuild:guildID];
        [self performSelector:@selector(fetchVisibleAuthorsMissingFromGateway:)
                   withObject:batch afterDelay:1.5];
    }
    if (self.pendingAuthors.count) {
        self.authorBatchScheduled = YES;
        [self performSelector:@selector(flushPendingAuthorRequests)
                   withObject:nil afterDelay:0.15];
    }
}

- (void)fetchVisibleAuthorsMissingFromGateway:(NSArray *)authorIDs {
    if (!self.isViewLoaded || !self.view.window) return;
    NSMutableSet *visibleIDs = [NSMutableSet set];
    for (NSIndexPath *path in [self.tableView indexPathsForVisibleRows]) {
        NSDictionary *thread = [self threadAtIndexPath:path];
        NSString *ownerID = DCThreadString([thread objectForKey:@"owner_id"]);
        if (ownerID.length) [visibleIDs addObject:ownerID];
    }
    for (NSString *authorID in authorIDs) {
        if (![visibleIDs containsObject:authorID]) continue;
        DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:authorID];
        if ([user displayNameInGuild:self.parentChannel.parentGuild].length) continue;
        [self fetchAuthorProfile:authorID];
    }
}

- (void)fetchAuthorProfile:(NSString *)authorID {
    if (!authorID.length || [self.profileRequestedAuthors containsObject:authorID]) return;
    [self.profileRequestedAuthors addObject:authorID];
    NSUInteger generation = self.requestGeneration;
    NSString *guildID = [self.parentChannel.parentGuild.snowflake copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    NSString *userID = [authorID copy];
    __weak DCThreadsViewController *weakSelf = self;
    dispatch_async(DCThreadUserLookupQueue(), ^{
        DCThreadsViewController *viewer = weakSelf;
        if (!viewer || viewer.requestGeneration != generation) return;
        DCUser *cached = [DCServerCommunicator.sharedInstance userForSnowflake:userID];
        if ([cached displayNameInGuild:viewer.parentChannel.parentGuild].length) return;

        NSString *path = [NSString stringWithFormat:@"/users/%@/profile?guild_id=%@", userID, guildID];
        NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:path token:token];
        [request setTimeoutInterval:10.0];
        NSHTTPURLResponse *response = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request
                                            returningResponse:&response error:nil];
        NSDictionary *profile = nil;
        id responseJSON = data.length
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (response.statusCode == 200 && [responseJSON isKindOfClass:[NSDictionary class]]) {
            profile = responseJSON;
        }
        NSDictionary *userJSON = DCThreadString([profile objectForKey:@"id"])
            ? profile : [profile objectForKey:@"user"];
        NSDictionary *memberJSON = [profile objectForKey:@"guild_member"];
        if (![userJSON isKindOfClass:[NSDictionary class]]) {
            path = [NSString stringWithFormat:@"/guilds/%@/members/%@", guildID, userID];
            request = [DCServerCommunicator requestWithPath:path token:token];
            [request setTimeoutInterval:10.0];
            data = [NSURLConnection sendSynchronousRequest:request
                                        returningResponse:&response error:nil];
            responseJSON = data.length
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (response.statusCode == 200 && [responseJSON isKindOfClass:[NSDictionary class]]) {
                memberJSON = responseJSON;
                userJSON = [memberJSON objectForKey:@"user"];
            }
        }
        if (![userJSON isKindOfClass:[NSDictionary class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DCThreadsViewController *currentViewer = weakSelf;
            if (!currentViewer || currentViewer.requestGeneration != generation) return;
            DCUser *user = [DCTools convertJsonUser:userJSON cache:YES];
            if (!user) return;
            if ([memberJSON isKindOfClass:[NSDictionary class]]) {
                [DCServerCommunicator.sharedInstance applyGuildProfileFromMember:memberJSON
                                                                           toUser:user
                                                                          guildID:guildID
                                                                   authoritative:YES];
            }
            [currentViewer refreshVisibleAuthors:nil];
        });
    });
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
    [DCSearchUI styleCancelButtonInSearchBar:searchBar];
    [self performSelector:@selector(refreshSearchCancelButton) withObject:nil afterDelay:0.2];
}

- (void)refreshSearchCancelButton {
    [DCSearchUI styleCancelButtonInSearchBar:self.searchBar];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self.threadSearch updateQuery:searchText activeThreads:self.activeThreads
                  archivedThreads:self.archivedThreads];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [self.threadSearch updateQuery:@"" activeThreads:self.activeThreads
                  archivedThreads:self.archivedThreads];
    [searchBar resignFirstResponder];
    [searchBar setShowsCancelButton:NO animated:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
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
    [self.threadSearch cancel];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DCThreadOpenRequested"
                                                            object:nil
                                                          userInfo:@{@"thread": threadPayload}];
    }];
}

@end
