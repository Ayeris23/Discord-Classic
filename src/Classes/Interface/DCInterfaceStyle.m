//
//  DCInterfaceStyle.m
//  Discord Classic
//
//  Created by Ayeris on 9/13/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCInterfaceStyle.h"
#import "DCInterfaceAssetCatalog.h"
#import "DCUser.h"
#import "DCGuild.h"
#import "DCRole.h"

@implementation DCInterfaceStyle

+ (UIImage *)navigationBarBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"TbarBG"];
}

+ (UIImage *)primaryBarButtonBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"BarButtonDone"];
}

+ (UIImage *)primaryBarButtonPressedBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"BarButtonDonePressed"];
}

+ (UIImage *)barButtonBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"BarButton"];
}

+ (UIImage *)barButtonPressedBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"BarButtonPressed"];
}

+ (UIImage *)toolbarBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"ToolbarBG"];
}

+ (UIImage *)messageFieldBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"MessageField"];
}

+ (UIImage *)sendButtonBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"SendMessageButton"];
}

+ (UIImage *)sendButtonPressedBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"SendMessageButtonPressed"];
}

+ (UIImage *)sendButtonDisabledBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"SendMessageButton-Disabled"];
}

+ (UIImage *)cameraButtonBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"CameraButton"];
}

+ (UIImage *)cameraButtonPressedBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"CameraButtonPressed"];
}

+ (UIImage *)cameraButtonStagedAttachmentsBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"CameraButtonWide"];
}

+ (UIImage *)cameraButtonStagedAttachmentsPressedBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"CameraButtonWidePressed"];
}

+ (UIImage *)downButtonBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"Down"];
}

+ (UIImage *)downButtonPressedBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"DownPressed"];
}

+ (UIImage *)navigationBackButtonBackgroundImage {
    UIImage *image = [DCInterfaceAssetCatalog imageNamed:@"NavigationButton"];
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 14, 0, 6)];
}

+ (UIImage *)navigationBackButtonPressedBackgroundImage {
    UIImage *image = [DCInterfaceAssetCatalog imageNamed:@"NavigationButtonPressed"];
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 14, 0, 6)];
}

+ (UIImage *)guildBannerPlaceholderImage {
    return [DCInterfaceAssetCatalog imageNamed:@"No-Header"];
}

+ (UIImage *)notificationBackgroundImage {
    return [DCInterfaceAssetCatalog imageNamed:@"No-header"];
}

+ (UIImage *)guildIconBaseImage {
    return [DCInterfaceAssetCatalog imageNamed:@"GuildIconBase"];
}

+ (UIImage *)guildFolderImage {
    return [DCInterfaceAssetCatalog imageNamed:@"folder"];
}

+ (UIImage *)sectionHeaderSeparatorImage {
    return [DCInterfaceAssetCatalog imageNamed:@"headerSeparator"];
}

+ (UIImage *)mentionBadgeImage {
    return [DCInterfaceAssetCatalog imageNamed:@"Badge"];
}

+ (UIImage *)privateGuildIconImage {
    return [DCInterfaceAssetCatalog imageNamed:@"privateGuildLogo"];
}

+ (UIImage *)videoPlayOverlayImage {
    return [DCInterfaceAssetCatalog imageNamed:@"PLVideoOverlayPlay.png"];
}

+ (UIImage *)chatAvatarChromeImage {
    return [DCInterfaceAssetCatalog imageNamed:@"PFPInset"];
}

+ (UIImage *)listAvatarChromeImage {
    return [DCInterfaceAssetCatalog imageNamed:@"sinkInMask"];
}

+ (UIImage *)profileAvatarChromeImage {
    return [DCInterfaceAssetCatalog imageNamed:@"pfpOverlay"];
}

+ (UIImage *)statusImageForStatus:(NSInteger)status {
    switch (status) {
        case DCUserStatusOnline:
            return [DCInterfaceAssetCatalog imageNamed:@"online"];
        case DCUserStatusDoNotDisturb:
            return [DCInterfaceAssetCatalog imageNamed:@"dnd"];
        case DCUserStatusIdle:
            return [DCInterfaceAssetCatalog imageNamed:@"absent"];
        case DCUserStatusOffline:
        default:
            return [DCInterfaceAssetCatalog imageNamed:@"offline"];
    }
}

+ (UIImage *)connectedAccountIconForType:(NSString *)accountType {
    if ([accountType isEqualToString:@"youtube"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-YouTube"];
    } else if ([accountType isEqualToString:@"twitter"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Twitter"];
    } else if ([accountType isEqualToString:@"bluesky"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-BlueSky"];
    } else if ([accountType isEqualToString:@"twitch"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Twitch"];
    } else if ([accountType isEqualToString:@"reddit"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Reddit"];
    } else if ([accountType isEqualToString:@"xbox"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Xbox"];
    } else if ([accountType isEqualToString:@"steam"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Steam"];
    } else if ([accountType isEqualToString:@"playstation"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-PSN"];
    } else if ([accountType isEqualToString:@"spotify"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Spotify"];
    } else if ([accountType isEqualToString:@"github"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-GitHub"];
    } else if ([accountType isEqualToString:@"contacts"]) {
        return [DCInterfaceAssetCatalog imageNamed:@"C-Contacts"];
    }
    return [DCInterfaceAssetCatalog imageNamed:@"C-Web"];
}

+ (UIImage *)defaultAvatarImageAtIndex:(NSUInteger)index {
    if (index > 5) {
        return nil;
    }
    return [DCInterfaceAssetCatalog imageNamed:[NSString stringWithFormat:@"DefaultAvatar%lu", (unsigned long)index]];
}


+ (UIColor *)roleColorForUser:(DCUser *)user inGuild:(DCGuild *)guild {
    if (!user || !guild.snowflake.length || guild.roles.count == 0) {
        return [UIColor whiteColor];
    }

    NSArray *roleIDs = [user.guildRoleIDs objectForKey:guild.snowflake];
    if (![roleIDs isKindOfClass:[NSArray class]] || roleIDs.count == 0) {
        return [UIColor whiteColor];
    }

    DCRole *highestColoredRole = nil;
    for (NSString *roleID in roleIDs) {
        DCRole *role = [guild.roles objectForKey:roleID];
        if (!role || role.color == 0) continue;

        if (!highestColoredRole || role.position > highestColoredRole.position) {
            highestColoredRole = role;
            continue;
        }

        if (role.position == highestColoredRole.position &&
            [role.snowflake longLongValue] < [highestColoredRole.snowflake longLongValue]) {
            highestColoredRole = role;
        }
    }

    if (!highestColoredRole) {
        return [UIColor whiteColor];
    }

    NSInteger color = highestColoredRole.color;
    CGFloat red = ((color >> 16) & 0xFF) / 255.0f;
    CGFloat green = ((color >> 8) & 0xFF) / 255.0f;
    CGFloat blue = (color & 0xFF) / 255.0f;
    return [UIColor colorWithRed:red green:green blue:blue alpha:1.0f];
}

+ (UIImage *)universalAddImage {
    return [DCInterfaceAssetCatalog imageNamed:@"U-Add"];
}

+ (UIImage *)universalRemoveImage {
    return [DCInterfaceAssetCatalog imageNamed:@"U-Remove"];
}

+ (UIImage *)universalEditImage {
    return [DCInterfaceAssetCatalog imageNamed:@"U-Pen"];
}

+ (UIImage *)universalPinImage {
    return [DCInterfaceAssetCatalog imageNamed:@"U-Pin"];
}

+ (UIImage *)universalBoostImage {
    return [DCInterfaceAssetCatalog imageNamed:@"U-Boost"];
}

@end
