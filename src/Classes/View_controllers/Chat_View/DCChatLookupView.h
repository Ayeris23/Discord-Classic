//
//  DCChatLookupView.h
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@class DCChatLookupView;
@class DCGuild;
@class DCUser;

@protocol DCChatLookupViewDelegate <NSObject>
- (void)chatLookupView:(DCChatLookupView *)lookup didSelectUser:(DCUser *)user;
@end

@interface DCChatLookupView : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, assign) id<DCChatLookupViewDelegate> delegate;
@property (nonatomic, readonly) NSUInteger resultCount;
- (void)setMentionUsers:(NSArray *)users guild:(DCGuild *)guild query:(NSString *)query;
- (void)clearResults;
@end
