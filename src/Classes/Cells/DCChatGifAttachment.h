//
//  DCChatGifAttachment.h
//  Discord Classic
//
//  Created by Ayeris on 3/12/26.
//  Copyright (c) 2026 bag.xml. All rights reserved.
//

#import "UILazyImageView.h"

@interface DCChatGifAttachment : UILazyImageView
@property (strong, nonatomic) NSURL *gifURL;
@property (assign, nonatomic, getter=isVideoBacked) BOOL videoBacked;
- (void)stopPlayback;
- (void)prepareForDisplay;
- (void)prepareForDisplayAllowLoading:(BOOL)allowLoading;
- (void)releaseThumbnailForResidency;
@end
