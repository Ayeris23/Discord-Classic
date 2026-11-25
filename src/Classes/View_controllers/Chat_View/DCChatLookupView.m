//
//  DCChatLookupView.m
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCChatLookupView.h"
#import "DCUser.h"
#import "DCGuild.h"
#import "DCTools.h"
#import "DCInterfaceStyle.h"
#import <math.h>

static const CGFloat DCChatLookupRowHeight = 44.0f;
static const NSUInteger DCChatLookupMaximumResults = 500;

@interface DCChatLookupMemberCell : UITableViewCell
@property (nonatomic, retain) UIImageView *avatar;
@property (nonatomic, retain) UIImageView *statusIndicator;
@property (nonatomic, retain) UILabel *nickname;
@property (nonatomic, retain) UILabel *username;
- (void)configureWithUser:(DCUser *)user guild:(DCGuild *)guild row:(NSUInteger)row;
@end

@implementation DCChatLookupMemberCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleGray;
        self.contentView.backgroundColor = [UIColor clearColor];
        self.backgroundView = [[UIView alloc] initWithFrame:self.bounds];

        self.avatar = [[UIImageView alloc] initWithFrame:CGRectMake(5, 3, 36, 36)];
        self.avatar.contentMode = UIViewContentModeScaleAspectFill;
        self.avatar.clipsToBounds = YES;
        [self.contentView addSubview:self.avatar];

        self.statusIndicator = [[UIImageView alloc] initWithFrame:CGRectMake(28, 27, 13, 13)];
        [self.contentView addSubview:self.statusIndicator];

        self.nickname = [[UILabel alloc] initWithFrame:CGRectZero];
        self.nickname.backgroundColor = [UIColor clearColor];
        self.nickname.font = [UIFont boldSystemFontOfSize:17.0f];
        self.nickname.lineBreakMode = UILineBreakModeTailTruncation;
        self.nickname.shadowColor = [UIColor blackColor];
        self.nickname.shadowOffset = CGSizeMake(0, 1);
        [self.contentView addSubview:self.nickname];

        self.username = [[UILabel alloc] initWithFrame:CGRectZero];
        self.username.backgroundColor = [UIColor clearColor];
        self.username.textColor = [UIColor colorWithWhite:128.0f/255.0f alpha:1.0f];
        self.username.font = [UIFont fontWithName:@"HelveticaNeue" size:10.0f] ?: [UIFont systemFontOfSize:10.0f];
        self.username.textAlignment = UITextAlignmentRight;
        self.username.shadowColor = [UIColor blackColor];
        self.username.shadowOffset = CGSizeMake(0, 1);
        [self.contentView addSubview:self.username];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat available = MAX(0.0f, floorf(width - 60.0f));
    CGFloat rawWidth = ceilf([self.username.text sizeWithFont:self.username.font].width) + 2.0f;
    CGFloat nameWidth = ceilf([self.nickname.text sizeWithFont:self.nickname.font].width);
    BOOL showRaw = self.username.text.length &&
                   ![self.username.text isEqualToString:self.nickname.text] &&
                   rawWidth < available * 0.48f &&
                   nameWidth + rawWidth + 10.0f <= available;
    self.username.hidden = !showRaw;
    if (showRaw) {
        self.username.frame = CGRectMake(floorf(width - rawWidth - 10.0f), 13.0f,
                                         rawWidth, 18.0f);
    }
    self.nickname.frame = CGRectMake(48.0f, 9.0f,
        MAX(0.0f, floorf(available - (showRaw ? rawWidth + 10.0f : 0.0f))), 22.0f);
}

- (void)configureWithUser:(DCUser *)user guild:(DCGuild *)guild row:(NSUInteger)row {
    self.backgroundView.backgroundColor = (row % 2 == 0)
        ? [UIColor colorWithRed:40.0f/255.0f green:41.0f/255.0f blue:46.0f/255.0f alpha:1.0f]
        : [UIColor colorWithRed:33.0f/255.0f green:34.0f/255.0f blue:38.0f/255.0f alpha:1.0f];
    self.nickname.text = [user displayNameInGuild:guild] ?: user.username ?: @"Unknown";
    self.nickname.textColor = [DCInterfaceStyle roleColorForUser:user inGuild:guild];
    self.username.text = user.username ?: @"";
    self.statusIndicator.hidden = NO;
    self.statusIndicator.image = [DCInterfaceStyle statusImageForStatus:user.status];

    UIImage *image = [DCTools cachedUserAvatar:user inGuild:guild];
    self.avatar.image = image ?: user.profileImage;
    if (!image) [DCTools getUserAvatar:user inGuild:guild];
    [self setNeedsLayout];
}
@end

@interface DCChatLookupView ()
@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) NSArray *results;
@property (nonatomic, retain) DCGuild *guild;
@property (nonatomic, retain) UILabel *emptyLabel;
@end

@implementation DCChatLookupView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor colorWithRed:40.0f/255.0f green:41.0f/255.0f blue:46.0f/255.0f alpha:1.0f];
        self.tableView = [[UITableView alloc] initWithFrame:self.bounds style:UITableViewStylePlain];
        self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.tableView.delegate = self;
        self.tableView.dataSource = self;
        self.tableView.rowHeight = DCChatLookupRowHeight;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tableView.backgroundColor = self.backgroundColor;
        self.tableView.alwaysBounceVertical = NO;
        [self addSubview:self.tableView];

        self.emptyLabel = [[UILabel alloc] initWithFrame:self.bounds];
        self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.emptyLabel.backgroundColor = [UIColor clearColor];
        self.emptyLabel.textColor = [UIColor lightGrayColor];
        self.emptyLabel.textAlignment = UITextAlignmentCenter;
        self.emptyLabel.font = [UIFont systemFontOfSize:13.0f];
        self.emptyLabel.text = @"No matching members";
        self.emptyLabel.hidden = YES;
        [self addSubview:self.emptyLabel];

        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(userDataChanged:) name:@"RELOAD USER DATA" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(userDataChanged:) name:@"USER_PRESENCE_UPDATED" object:nil];
    }
    return self;
}

- (void)userDataChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self userDataChanged:notification]; });
        return;
    }
    if (self.window && self.results.count) [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSUInteger)resultCount { return self.results.count; }

- (void)setMentionUsers:(NSArray *)users guild:(DCGuild *)guild query:(NSString *)query {
    self.guild = guild;
    NSString *needle = [query lowercaseString] ?: @"";
    if (!needle.length) {
        self.results = [users subarrayWithRange:NSMakeRange(0, MIN(users.count, DCChatLookupMaximumResults))];
    } else {
        NSMutableArray *buckets[8] = {
            [NSMutableArray array], [NSMutableArray array],
            [NSMutableArray array], [NSMutableArray array],
            [NSMutableArray array], [NSMutableArray array],
            [NSMutableArray array], [NSMutableArray array]
        };
        for (DCUser *user in users) {
            NSString *name = [[user displayNameInGuild:guild] lowercaseString] ?: @"";
            NSString *raw = [user.username lowercaseString] ?: @"";
            NSString *global = [user.globalName lowercaseString] ?: @"";
            NSInteger bucket = -1;
            if ([name isEqualToString:needle]) bucket = 0;
            else if ([name hasPrefix:needle]) bucket = 1;
            else if ([name rangeOfString:needle].location != NSNotFound) bucket = 2;
            else if ([raw isEqualToString:needle]) bucket = 3;
            else if ([raw hasPrefix:needle]) bucket = 4;
            else if ([global hasPrefix:needle]) bucket = 5;
            else if ([raw rangeOfString:needle].location != NSNotFound) bucket = 6;
            else if ([global rangeOfString:needle].location != NSNotFound) bucket = 7;
            if (bucket >= 0) [buckets[bucket] addObject:user];
        }
        NSMutableArray *matched = [NSMutableArray array];
        for (NSUInteger bucket = 0; bucket < 8; bucket++) {
            NSUInteger remaining = DCChatLookupMaximumResults - matched.count;
            if (!remaining) break;
            NSArray *items = buckets[bucket];
            [matched addObjectsFromArray:[items subarrayWithRange:NSMakeRange(0, MIN(remaining, items.count))]];
        }
        self.results = matched;
    }
    self.emptyLabel.hidden = self.results.count != 0;
    [self.tableView reloadData];
    [self.tableView setContentOffset:CGPointZero animated:NO];
}

- (void)clearResults {
    self.results = nil;
    self.guild = nil;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"Chat Lookup Member";
    DCChatLookupMemberCell *cell = (DCChatLookupMemberCell *)[tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[DCChatLookupMemberCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    [cell configureWithUser:[self.results objectAtIndex:indexPath.row] guild:self.guild row:indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.row >= self.results.count) return;
    DCUser *user = [self.results objectAtIndex:indexPath.row];
    [self.delegate chatLookupView:self didSelectUser:user];
}

@end
