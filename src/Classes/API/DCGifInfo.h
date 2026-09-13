//
//  DCGifInfo.h
//  Discord Classic
//
//  Created by Ayeris on 3/15/26.
//  Copyright (c) 2026 bag.xml. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCGifInfo : NSObject
@property (strong, nonatomic) NSURL *gifURL;
@property (strong, nonatomic) NSURL *thumbnailURL;
@property (assign, nonatomic) CGSize naturalSize;
@property (assign, nonatomic, getter=isVideoBacked) BOOL videoBacked;
@end
