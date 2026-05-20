# Discord Classic
![siteBanner](https://github.com/user-attachments/assets/ea272fc6-c230-4579-a81c-a8e28d941ace)
Discord Classic is a third-party alternative Discord client designed for devices running old versions of iOS. 

Created by trevir in 2018, it aims to be as close as possible to feature-complete (excluding but not limited to Voice Chats or Activities).

## Compatiblilty Table
| Supported?  | iOS version | Remarks |
| ------------- | ------------- | ------------- |
| No  | 5.0.x  | SSL issues prevent connection |
| Yes  | 5.1.x  | None |
| Yes  | 6.x  | None |
| Yes  | 7.x  | No native UI yet |
| Yes  | 8+  | UI starts to break |

### iPad support
There is no dedicated UI storyboard for iPads at the moment so bugs will be present, other than that the core functionality should still work fine.

## Logging in

> [!CAUTION]
> **DO NOT SHARE YOUR DISCORD TOKEN WITH ANYONE!** Tokens are what authenticate to Discord that you are *you*. If anyone gains access to your Discord token, they can access your account too! <br>
> If you believe that someone may have your Discord token, change your account password immediately.

> [!IMPORTANT]
> When trying to log in using an email address and password, you might receive a message about Captchas. <br>
> If this happens, the only workaround is to login to the same account on a modern device and complete the captcha there. You should then be able to login on Discord Classic.

Discord Classic allows users to login by specifying an email and password or by entering an account token. Token login should only be used as a last resort.

### Two-factor Authentication
Currently, the only method of 2FA supported is app-based (Google/Microsoft Authenticator). SMS authentication is not supported, and neither are backup codes.

## Building
For help on building Discord Classic, see [BUILDING.md](BUILDING.md).

## Got an issue? Need help?
If you're encountering issues, feel free to [open a new issue](https://github.com/Ayeris23/Discord-Classic/issues) and make sure to include the following:
- A description of the issue (x happens when trying to y...)
- Steps to recreate the issue (1. xxx, 2. yyy, 3. zzz, etc.)
- The device running Discord Classic (iPhone 3GS? iPad 4? iPod Touch 5?)
- The version of iOS installed
Make sure before creating an issue that it hasn't already been reported.

If you need any extra support with Discord Classic, feel free to join [bag.xml's Discord server](https://discord.gg/eE3XTCEMqr). Inside the #discord-classic channel, you can get real-time help at any time if you're having issues regarding the app or more. You'll find that most contributors are actually active there.

## Credits

### Contributors
- [trevir](https://github.com/trev3d) (creator)
- [Ayeris23](https://github.com/Ayeris23) (current leader)
- [bag.xml](https://github.com/bag-xml)
- [plzdonthaxme](https://github.com/justtryingthingsout)
- [ObscureMosquito (Requis)](https://github.com/ObscureMosquito)
- [Toru](https://github.com/ToruTheRedFox)

### Libraries
- [APLSlideMenu](https://github.com/apploft/APLSlideMenu)
- [Base64](https://github.com/nicklockwood/Base64)
- [BButton](https://github.com/mattlawer/BButton)
- [CKRefreshControl](https://github.com/instructure/CKRefreshControl)
- [NSString+Emojize](https://github.com/diy/nsstringemojize)
- [SDWebImage](https://github.com/SDWebImage/SDWebImage)
- [libwebp](https://github.com/webmproject/libwebp)
- [TSMarkdownParser](https://github.com/laptobbe/TSMarkdownParser)
- [UIColor+Hex](https://github.com/bag-xml/UIColor-Hex)
- [UIImage+animatedGIF](https://github.com/mayoff/uiimage-from-animated-gif)
- [WSWebSocket](https://github.com/ndcube/WebSocket-for-Objective-C)
