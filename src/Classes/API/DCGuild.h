//
//  DCGuild.h
//  Discord Classic
//
//  Created by bag.xml on 3/12/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

/*DCGuild is a representation of a Discord API Guild object.
 Its easier to work with than raw JSON data and has some handy
 built in functions*/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "DCTools.h"

@interface DCGuild : NSObject<NSCoding>
// ID/snowflake
@property (strong, nonatomic) DCSnowflake* snowflake;
// Name
@property (strong, nonatomic) NSString* name;
// The ID of the guild's owner
@property (strong, nonatomic) DCSnowflake* ownerID;
// The number of members in the guild
@property (assign, nonatomic) NSInteger memberCount;
// The number of currently online members in the guild
@property (assign, nonatomic) NSInteger onlineCount;
// Whether it is muted
@property (assign, nonatomic) BOOL muted;

// Raw guild icon used by folder composites and non-menu views.
@property (strong, nonatomic) UIImage* icon;
// Cached 48pt main-menu tile.
@property (strong, nonatomic) UIImage *compositedIcon;
// Discord asset hashes are durable version identifiers. iconURL remains for
// compatibility with the existing cold-start SDWebImage hydration path.
@property (strong, nonatomic) NSString *iconID;
@property (strong, nonatomic) NSString *iconURL;
// The guild's banner
@property (strong, nonatomic) UIImage* banner;
@property (strong, nonatomic) NSString *bannerID;

// Array of child DCChannel objects
@property (strong, nonatomic) NSMutableArray* channels;
// Whether or not the guild has any unread child channels
@property (assign, nonatomic) BOOL unread;
// Number of pings a guild has
@property (nonatomic, readonly) NSInteger mentionCount;
// Legacy dense member list retained for compatibility with older callers.
@property (strong, nonatomic) NSMutableArray* members;
// Sparse Discord member-list stream keyed by absolute list index.
@property (strong, nonatomic) NSMutableDictionary *memberListItems;
// Invalidated stream positions may remain visible until a replacement SYNC.
@property (strong, nonatomic) NSMutableIndexSet *memberListStaleIndexes;
// Ordered group metadata from GUILD_MEMBER_LIST_UPDATE.
@property (strong, nonatomic) NSArray *memberListGroups;
// Discord list identifier and the channel whose permissions produced it.
@property (strong, nonatomic) NSString *memberListID;
@property (strong, nonatomic) NSString *memberListChannelID;
// Roles in the guild
@property (strong, nonatomic) NSMutableDictionary* roles;
// Array of the current user's roles in the guild
@property (strong, nonatomic) NSMutableArray* userRoles;
// Emojis in the guild
@property (strong, nonatomic) NSMutableDictionary* emojis;

- (void)checkIfRead;
@end
