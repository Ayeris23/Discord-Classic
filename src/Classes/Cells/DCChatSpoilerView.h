//
//  DCChatSpoilerView.h
//  Discord Classic
//
//  Created by Ayeris on 10/22/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCChatSpoilerView : UIView

@property (nonatomic, strong, readonly) UITapGestureRecognizer *revealTapRecognizer;
@property (nonatomic, copy, readonly) NSString *spoilerKey;

+ (BOOL)hasRevealedSpoilers;
+ (void)concealAllSpoilers;
+ (void)concealSpoilersOutsideKeys:(NSSet *)visibleKeys;
- (void)conceal;
- (void)refreshRevealState;

- (id)initWithFrame:(CGRect)frame
        spoilerKey:(NSString *)spoilerKey
       placeholder:(NSString *)placeholder;
- (BOOL)isRevealed;

@end
