//
//  DCInterfaceStyle.h
//  Discord Classic
//
//  Created by Ayeris on 9/13/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCInterfaceStyle : NSObject

+ (UIImage *)navigationBarBackgroundImage;
+ (UIImage *)primaryBarButtonBackgroundImage;
+ (UIImage *)primaryBarButtonPressedBackgroundImage;
+ (UIImage *)barButtonBackgroundImage;
+ (UIImage *)barButtonPressedBackgroundImage;
+ (UIImage *)toolbarBackgroundImage;
+ (UIImage *)messageFieldBackgroundImage;
+ (UIImage *)sendButtonBackgroundImage;
+ (UIImage *)sendButtonPressedBackgroundImage;
+ (UIImage *)sendButtonDisabledBackgroundImage;
+ (UIImage *)cameraButtonBackgroundImage;
+ (UIImage *)cameraButtonPressedBackgroundImage;
+ (UIImage *)cameraButtonStagedAttachmentsBackgroundImage;
+ (UIImage *)cameraButtonStagedAttachmentsPressedBackgroundImage;
+ (UIImage *)downButtonBackgroundImage;
+ (UIImage *)downButtonPressedBackgroundImage;
+ (UIImage *)navigationBackButtonBackgroundImage;
+ (UIImage *)navigationBackButtonPressedBackgroundImage;

+ (UIImage *)guildBannerPlaceholderImage;
+ (UIImage *)notificationBackgroundImage;
+ (UIImage *)guildIconBaseImage;
+ (UIImage *)guildFolderImage;
+ (UIImage *)sectionHeaderSeparatorImage;
+ (UIImage *)mentionBadgeImage;
+ (UIImage *)privateGuildIconImage;
+ (UIImage *)videoPlayOverlayImage;
+ (UIImage *)chatAvatarChromeImage;
+ (UIImage *)listAvatarChromeImage;
+ (UIImage *)profileAvatarChromeImage;

+ (UIImage *)statusImageForStatus:(NSInteger)status;
+ (UIImage *)connectedAccountIconForType:(NSString *)accountType;
+ (UIImage *)defaultAvatarImageAtIndex:(NSUInteger)index;

+ (UIImage *)universalAddImage;
+ (UIImage *)universalRemoveImage;
+ (UIImage *)universalEditImage;
+ (UIImage *)universalPinImage;
+ (UIImage *)universalBoostImage;

@end
