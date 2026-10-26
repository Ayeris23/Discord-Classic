//
//  DCChatSpoilerView.m
//  Discord Classic
//
//  Created by Ayeris on 10/22/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCChatSpoilerView.h"
#import "ThumbHash.h"
#import "Base64.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface DCChatSpoilerView ()
@property (nonatomic, copy, readwrite) NSString *spoilerKey;
@property (nonatomic, strong) UIImageView *placeholderImageView;
@property (nonatomic, strong) UIView *labelBackground;
@property (nonatomic, strong, readwrite) UITapGestureRecognizer *revealTapRecognizer;
@end

@implementation DCChatSpoilerView

+ (NSMutableSet *)revealedKeys {
    static NSMutableSet *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ keys = [NSMutableSet new]; });
    return keys;
}

+ (BOOL)hasRevealedSpoilers {
    return [[self revealedKeys] count] != 0;
}

+ (void)concealAllSpoilers {
    [[self revealedKeys] removeAllObjects];
}

+ (void)concealSpoilersOutsideKeys:(NSSet *)visibleKeys {
    [[self revealedKeys] intersectSet:visibleKeys];
}

+ (NSCache *)placeholderCache {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 48;
    });
    return cache;
}

- (id)initWithFrame:(CGRect)frame
        spoilerKey:(NSString *)spoilerKey
       placeholder:(NSString *)placeholder {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.spoilerKey = spoilerKey;
    self.backgroundColor = [UIColor colorWithWhite:0.13f alpha:1.0f];
    self.clipsToBounds = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *preview = [[UIImageView alloc] initWithFrame:self.bounds];
    preview.contentMode = UIViewContentModeScaleToFill;
    preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    preview.userInteractionEnabled = NO;
    [self addSubview:preview];
    self.placeholderImageView = preview;

    if (placeholder.length > 0 && placeholder.length <= 1024) {
        NSCache *cache = [[self class] placeholderCache];
        UIImage *previewImage = [cache objectForKey:placeholder];
        if (!previewImage) {
            NSData *data = [NSData dataWithBase64EncodedString:placeholder];
            if (data.length > 0 && data.length <= 512) {
                previewImage = thumbHashToImage(data);
                if (previewImage) [cache setObject:previewImage forKey:placeholder];
            }
        }
        preview.image = previewImage;
    }

    UIView *pill = [[UIView alloc] initWithFrame:CGRectZero];
    pill.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.75f];
    pill.layer.cornerRadius = 13.0f;
    pill.userInteractionEnabled = NO;
    [self addSubview:pill];
    self.labelBackground = pill;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 84, 26)];
    label.text = @"SPOILER";
    label.font = [UIFont boldSystemFontOfSize:14.0f];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor clearColor];
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0, -1);
    label.userInteractionEnabled = NO;
    [pill addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(revealSpoiler:)];
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = YES;
    [self addGestureRecognizer:tap];
    self.revealTapRecognizer = tap;

    [self refreshRevealState];
    return self;
}

- (BOOL)isRevealed {
    return self.spoilerKey.length > 0 &&
        [[[self class] revealedKeys] containsObject:self.spoilerKey];
}

- (void)conceal {
    if (self.spoilerKey.length) {
        [[[self class] revealedKeys] removeObject:self.spoilerKey];
    }
    self.hidden = NO;
}

- (void)refreshRevealState {
    self.hidden = [self isRevealed];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self conceal];
    } else {
        [self refreshRevealState];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize pillSize = CGSizeMake(108.0f, 26.0f);
    self.labelBackground.frame = CGRectMake(
        floorf((self.bounds.size.width - pillSize.width) * 0.5f),
        floorf((self.bounds.size.height - pillSize.height) * 0.5f),
        pillSize.width, pillSize.height);
}

- (void)revealSpoiler:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    if (self.spoilerKey.length > 0) {
        [[[self class] revealedKeys] addObject:self.spoilerKey];
    }
    self.hidden = YES;
}

@end
