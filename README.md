# Discord Classic
![siteBanner](https://github.com/user-attachments/assets/ea272fc6-c230-4579-a81c-a8e28d941ace)
Discord Classic is a *third-party* Discord client for legacy Apple devices. Created in 2018, it aims to be as close to feature-complete as possible (excluding for example VCs or activities).

# Compatiblilty
Discord Classic requires a **32-bit** Apple device running at least iOS 5.1.

iOS 5.0 is not supported as Discord's V9 API (what we use) requires at least TLS 1.1.

| Works?  | iOS version | Notes |
| ------------- | ------------- | ------------- |
| No  | 5.0.x  | Lacks TLS 1.1 support |
| Yes  | 5.1.x  | None |
| Yes  | 6.x  | None |
| Yes  | 7.x  | No native UI yet |
| Yes  | 8+  | UI bugs will appear |

## Logging in

> [!CAUTION]
> **DO NOT SHARE YOUR DISCORD TOKEN WITH ANYONE!** Tokens are what authenticate to Discord that you are *you*. If anyone gains access to your Discord token, they can access your account too! <br>
> If you believe that someone may have your Discord token, change your account password immediately.

> [!IMPORTANT]
> When trying to log in using an email address and password, you might receive a message about Captchas. <br>
> If this happens, the only workaround is to login to the same account on a modern device connected to the same network and complete the captcha there. You should then be able to login on Discord Classic.

Discord Classic allows users to login by specifying an email and password or by entering an account token. Token login should only be used as a last resort.

### Two-factor Authentication
Currently, the only method of 2FA supported is app-based (Google/Microsoft Authenticator). SMS authentication is not supported, and neither are backup codes.

## Building
For help on building Discord Classic, see [BUILDING.md](BUILDING.md).

## Got an issue? Need help?
If you're encountering issues, feel free to [open a new issue](https://github.com/Ayeris23/Discord-Classic/issues) and include the following:
- A description of the issue
- Steps to recreate the issue
- The device running Discord Classic
- The version of iOS installed
Also, make sure before creating an issue that it hasn't already been reported.

If you need any extra support with Discord Classic, feel free to join [bag.xml's Discord server](https://discord.gg/eE3XTCEMqr). Inside the #discord-classic channel, you can get real-time help if you're having issues regarding the app or more. You'll find that most contributors are active there.

# Credits
- [trevir](https://github.com/trev3d) (project creator)
- [bag.xml](https://github.com/bag-xml) (leader during early 2025)
- [plzdonthaxme](https://github.com/justtryingthingsout) (leader during late 2025)
- [Ayeris23](https://github.com/Ayeris23) (leader since April 2026)
- [kooper](https://github.com/dskooper) (contributor, fixed Theos builds)
- [ObscureMosquito (Requis)](https://github.com/ObscureMosquito) (contributor)
- [Toru](https://github.com/ToruTheRedFox) (contributor)

# Libraries
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
