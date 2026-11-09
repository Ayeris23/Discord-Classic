//
//  DCCaptchaCompatibilityViewController.h
//  Discord Classic
//
//  Created by Ayeris on 11/8/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCCaptchaCompatibilityViewController : UIViewController <UIWebViewDelegate>

@property (nonatomic, copy) NSString *captchaSitekey;
@property (nonatomic, copy) NSString *captchaRQData;
@property (nonatomic, copy) NSString *captchaService;

@end
