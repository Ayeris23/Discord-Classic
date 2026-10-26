//
//  DCChatVideoAttachment.h
//  Discord Classic
//
//  Created by Toru the Red Fox on 25/10/22.
//  Copyright (c) 2022 Toru the Red Fox. All rights reserved.
//

#import <UIKit/UIKit.h>

@class DCChatSpoilerView;

@interface DCChatVideoAttachment : UIView
@property (nonatomic, strong) DCChatSpoilerView *spoilerView;
@property (strong, nonatomic) IBOutlet UIImageView *playButton;
@property (weak, nonatomic) IBOutlet UIImageView *thumbnail;
@property (strong, nonatomic) NSURL *videoURL;
@property (strong, nonatomic) NSURL *thumbnailURL;
@property (assign, nonatomic) BOOL spoiler;
@property (copy, nonatomic) NSString *spoilerKey;
@property (copy, nonatomic) NSString *spoilerPlaceholder;
@property (strong, nonatomic) UIImage *thumbnailImage;
@property (copy, nonatomic) NSString *warningText;
@property (assign, nonatomic) CGSize naturalSize;
@property (assign, nonatomic) BOOL thumbnailLoading;
@property (weak, nonatomic) IBOutlet UILabel *videoWarning;
@property (nonatomic, strong) NSURL *linkURL;

- (id)initMetadataOnly;
- (void)prepareForDisplay;
- (void)prepareForDisplayAllowLoading:(BOOL)allowLoading;
- (void)releaseThumbnailForResidency;
@end
