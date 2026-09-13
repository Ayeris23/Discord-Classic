//
//  DCWebImageOperations.m
//  Discord Classic
//
//  Created by bag.xml on 3/17/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCTools.h"
#include <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
#include <dispatch/dispatch.h>
#include <objc/NSObjCRuntime.h>
#include <sys/utsname.h>
#import "Base64.h"
#import "DCChatVideoAttachment.h"
#import "DCChannel.h"
#import "DCGuild.h"
#import "DCGifInfo.h"
#import "DCEmoji.h"
#import "DCMessage.h"
#import "DCRole.h"
#import "DCServerCommunicator.h"
#import "DCUser.h"
#import "NSString+Emojize.h"
#import "QuickLook/QuickLook.h"
#import "SDWebImageManager.h"
#include "TSMarkdownParser.h"
#import "DCMarkdownParser.h"
#import "UIImage+animatedGIF.h"
#import "UILazyImage.h"
#import "DCContentManager.h"
#import "DCResourceManager.h"
#import "DCChatMediaManager.h"
#import "DTCoreTextLayouter.h"
#import "DTCoreTextLayoutFrame.h"
#import <CoreText/CoreText.h>

// https://discord.gg/X4NSsMC

static NSURL *DCRegisterChatMediaURL(NSURL *url,
                                     NSString *channelID,
                                     NSString *messageID) {
    if (url) {
        [[DCChatMediaManager sharedManager] registerMediaURL:url
                                                   channelID:channelID
                                                   messageID:messageID];
    }
    return url;
}

static BOOL DCMessageContentIsOnlyURL(NSString *content, NSString *urlString) {
    if (content.length == 0 || urlString.length == 0) return NO;
    NSString *trimmed = [content stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [trimmed isEqualToString:urlString];
}

/* Older CoreText builds can stall while resolving unsupported supplementary
 * emoji. Route supported scalar glyphs explicitly and use a display-only
 * placeholder for unsupported clusters without changing the message model. */
static BOOL DCNeedsLegacyUnicodeCompatibility(void) {
    return ([[[UIDevice currentDevice] systemVersion] compare:@"7.0"
                                                       options:NSNumericSearch] == NSOrderedAscending);
}

static BOOL DCIsModernEmojiScalar(uint32_t scalar) {
    /*
     * Covers the supplementary emoji/symbol blocks that matter to the old
     * CoreText fallback failure (including U+1F642). Restricting this
     * range prevents rare non-emoji supplementary scripts from being rewritten.
     */
    return scalar >= 0x1F000 && scalar <= 0x1FAFF;
}

static uint32_t DCScalarFromSurrogatePair(unichar high, unichar low) {
    return (((uint32_t)high - 0xD800U) << 10)
         + ((uint32_t)low - 0xDC00U)
         + 0x10000U;
}

static CFCharacterSetRef DCInstalledAppleColorEmojiCharacterSet(void);

static uint16_t DCReadBigEndianUInt16(const UInt8 *bytes, NSUInteger length, NSUInteger offset) {
    if (!bytes || offset > length || length - offset < 2) return 0;
    return (uint16_t)(((uint16_t)bytes[offset] << 8) |
                      (uint16_t)bytes[offset + 1]);
}

static uint32_t DCReadBigEndianUInt32(const UInt8 *bytes, NSUInteger length, NSUInteger offset) {
    if (!bytes || offset > length || length - offset < 4) return 0;
    return ((uint32_t)bytes[offset] << 24) |
           ((uint32_t)bytes[offset + 1] << 16) |
           ((uint32_t)bytes[offset + 2] << 8) |
            (uint32_t)bytes[offset + 3];
}

/*
 * CTFontCopyCharacterSet is normally the right coverage query, but on an old
 * CoreText build it can under-report characters added by a much newer
 * replacement AppleColorEmoji.  The font file itself still has the authority:
 * supplementary Unicode mappings live in a format-12/13 'cmap' subtable.
 * Read that table directly so upgraded devices are not artificially limited by
 * iOS 5/6's cached/legacy coverage view.
 */
static CFDataRef DCInstalledAppleColorEmojiCmapTable(void) {
    static CFDataRef cmapTable = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!DCInstalledAppleColorEmojiCharacterSet()) return;
        CTFontRef font = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 14.0f, NULL);
        if (!font) return;
        cmapTable = CTFontCopyTable(font, kCTFontTableCmap, 0);
        CFRelease(font);
    });
    return cmapTable;
}

static uint32_t DCGlyphFromCmapGroupSubtable(const UInt8 *bytes,
                                              NSUInteger length,
                                              NSUInteger subtableOffset,
                                              uint16_t format,
                                              uint32_t scalar) {
    if (subtableOffset > length || length - subtableOffset < 16) return 0;

    uint32_t subtableLength = DCReadBigEndianUInt32(bytes, length, subtableOffset + 4);
    uint32_t groupCount = DCReadBigEndianUInt32(bytes, length, subtableOffset + 12);
    if (subtableLength < 16 || subtableLength > length - subtableOffset) return 0;

    NSUInteger groupBase = subtableOffset + 16;
    NSUInteger availableGroupBytes = subtableLength - 16;
    if ((uint64_t)groupCount * 12ULL > (uint64_t)availableGroupBytes) return 0;

    /* Groups are sorted by starting character code; binary-search them. */
    uint32_t low = 0;
    uint32_t high = groupCount;
    while (low < high) {
        uint32_t mid = low + ((high - low) / 2);
        NSUInteger groupOffset = groupBase + ((NSUInteger)mid * 12U);
        uint32_t start = DCReadBigEndianUInt32(bytes, length, groupOffset);
        uint32_t end = DCReadBigEndianUInt32(bytes, length, groupOffset + 4);

        if (scalar < start) {
            high = mid;
        } else if (scalar > end) {
            low = mid + 1;
        } else {
            uint32_t startGlyph = DCReadBigEndianUInt32(bytes, length, groupOffset + 8);
            if (format == 12) {
                return startGlyph + (scalar - start);
            }
            if (format == 13) {
                return startGlyph;
            }
            return 0;
        }
    }
    return 0;
}

static uint32_t DCInstalledAppleColorEmojiGlyphForScalar(uint32_t scalar) {
    CFDataRef cmapTable = DCInstalledAppleColorEmojiCmapTable();
    if (!cmapTable) return 0;

    const UInt8 *bytes = CFDataGetBytePtr(cmapTable);
    NSUInteger length = (NSUInteger)CFDataGetLength(cmapTable);
    if (!bytes || length < 4) return 0;

    uint16_t tableCount = DCReadBigEndianUInt16(bytes, length, 2);
    if ((uint64_t)tableCount * 8ULL > (uint64_t)(length - 4)) return 0;

    for (uint16_t i = 0; i < tableCount; i++) {
        NSUInteger recordOffset = 4 + ((NSUInteger)i * 8U);
        uint32_t subtableOffset32 = DCReadBigEndianUInt32(bytes, length, recordOffset + 4);
        NSUInteger subtableOffset = (NSUInteger)subtableOffset32;
        if (subtableOffset > length || length - subtableOffset < 2) continue;

        uint16_t format = DCReadBigEndianUInt16(bytes, length, subtableOffset);
        if (format != 12 && format != 13) continue;

        uint32_t glyph = DCGlyphFromCmapGroupSubtable(bytes,
                                                       length,
                                                       subtableOffset,
                                                       format,
                                                       scalar);
        if (glyph != 0) return glyph;
    }
    return 0;
}

static CFCharacterSetRef DCInstalledAppleColorEmojiCharacterSet(void) {
    static CFCharacterSetRef characterSet = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CTFontRef font = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 14.0f, NULL);
        if (!font) return;

        NSString *postScriptName = CFBridgingRelease(CTFontCopyPostScriptName(font));
        NSString *familyName = CFBridgingRelease(CTFontCopyFamilyName(font));
        BOOL isEmojiFont = ([postScriptName rangeOfString:@"Emoji"
                                                   options:NSCaseInsensitiveSearch].location != NSNotFound)
                        || ([familyName rangeOfString:@"Emoji"
                                               options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (isEmojiFont) {
            characterSet = CTFontCopyCharacterSet(font);
            DBGLOG(@"[UnicodeCompat] Installed emoji font %@ (%@)",
                   postScriptName ?: @"?", familyName ?: @"?");
        } else {
            DBGLOG(@"[UnicodeCompat] AppleColorEmoji name resolved to unexpected font %@ (%@); disabled",
                   postScriptName ?: @"?", familyName ?: @"?");
        }
        CFRelease(font);
    });
    return characterSet;
}

static CTFontRef DCCreateInstalledAppleColorEmojiFont(CGFloat pointSize) {
    if (!DCInstalledAppleColorEmojiCharacterSet()) return NULL;
    return CTFontCreateWithName(CFSTR("AppleColorEmoji"), pointSize, NULL);
}

static BOOL DCAttributedStringContainsModernEmojiCandidate(NSAttributedString *attributed) {
    NSString *plain = attributed.string;
    NSUInteger length = plain.length;
    for (NSUInteger i = 0; i + 1 < length; i++) {
        unichar high = [plain characterAtIndex:i];
        if (high < 0xD800 || high > 0xDBFF) continue;
        unichar low = [plain characterAtIndex:i + 1];
        if (low < 0xDC00 || low > 0xDFFF) continue;
        if (DCIsModernEmojiScalar(DCScalarFromSurrogatePair(high, low))) return YES;
        i++;
    }
    return NO;
}

static void DCApplyLegacyUnicodeCompatibility(DCMessage *message) {
    if (!DCNeedsLegacyUnicodeCompatibility() ||
        !message.attributedContent.length ||
        !DCAttributedStringContainsModernEmojiCandidate(message.attributedContent)) {
        return;
    }

    NSMutableAttributedString *rendered = [message.attributedContent mutableCopy];
    CFCharacterSetRef emojiCharacterSet = DCInstalledAppleColorEmojiCharacterSet();
    NSUInteger index = 0;

    while (index < rendered.length) {
        NSString *plain = rendered.string;
        NSRange cluster = [plain rangeOfComposedCharacterSequenceAtIndex:index];
        if (cluster.location == NSNotFound || cluster.length == 0) {
            index++;
            continue;
        }

        NSUInteger cursor = cluster.location;
        NSUInteger scalarCount = 0;
        NSUInteger modernEmojiScalarCount = 0;
        uint32_t firstModernEmojiScalar = 0;

        while (cursor < NSMaxRange(cluster)) {
            unichar ch = [plain characterAtIndex:cursor];
            uint32_t scalar = ch;

            if (ch >= 0xD800 && ch <= 0xDBFF && cursor + 1 < NSMaxRange(cluster)) {
                unichar low = [plain characterAtIndex:cursor + 1];
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    scalar = DCScalarFromSurrogatePair(ch, low);
                    cursor += 2;
                } else {
                    cursor++;
                }
            } else {
                cursor++;
            }

            scalarCount++;
            if (DCIsModernEmojiScalar(scalar)) {
                modernEmojiScalarCount++;
                if (!firstModernEmojiScalar) firstModernEmojiScalar = scalar;
            }
        }

        if (modernEmojiScalarCount == 0) {
            index = NSMaxRange(cluster);
            continue;
        }

        /*
         * Only a single supplementary scalar is safe to hand directly to the
         * old shaper.  Anything compositional gets a placeholder until the app
         * has a sequence-aware emoji renderer.
         */
        BOOL simpleSingleScalar = (scalarCount == 1 &&
                                   modernEmojiScalarCount == 1 &&
                                   cluster.length == 2);
        BOOL characterSetSupportsScalar = simpleSingleScalar &&
            emojiCharacterSet &&
            CFCharacterSetIsLongCharacterMember(emojiCharacterSet,
                                                  (UTF32Char)firstModernEmojiScalar);

        /* CTFontCopyCharacterSet can under-report upgraded emoji fonts. Fall
         * back to the cmap table and attach CTGlyphInfo when a glyph exists. */
        uint32_t cmapGlyph = 0;
        if (simpleSingleScalar && !characterSetSupportsScalar) {
            cmapGlyph = DCInstalledAppleColorEmojiGlyphForScalar(firstModernEmojiScalar);
        }

        BOOL canRouteScalar = characterSetSupportsScalar ||
                              (cmapGlyph > 0 && cmapGlyph <= 0xFFFFU);

        if (canRouteScalar) {
            id currentFontObject = [rendered attribute:(NSString *)kCTFontAttributeName
                                               atIndex:cluster.location
                                        effectiveRange:NULL];
            CGFloat pointSize = 14.0f;
            if (currentFontObject) {
                CTFontRef currentFont = (__bridge CTFontRef)currentFontObject;
                CGFloat existingSize = CTFontGetSize(currentFont);
                if (existingSize > 0.0f) pointSize = existingSize;
            }

            CTFontRef emojiFont = DCCreateInstalledAppleColorEmojiFont(pointSize);
            if (emojiFont) {
                if (!characterSetSupportsScalar && cmapGlyph != 0) {
                    NSString *baseString = [plain substringWithRange:cluster];
                    CTGlyphInfoRef glyphInfo = CTGlyphInfoCreateWithGlyph((CGGlyph)cmapGlyph,
                                                                           emojiFont,
                                                                           (__bridge CFStringRef)baseString);
                    if (glyphInfo) {
                        [rendered addAttribute:(NSString *)kCTFontAttributeName
                                         value:(__bridge id)emojiFont
                                         range:cluster];
                        [rendered addAttribute:(NSString *)kCTGlyphInfoAttributeName
                                         value:(__bridge id)glyphInfo
                                         range:cluster];
                        DBGLOG(@"[UnicodeCompat] %@ routed U+%04X via raw cmap glyph %u to AppleColorEmoji %.0fpt (charset miss)",
                               message.snowflake ?: @"?",
                               (unsigned int)firstModernEmojiScalar,
                               (unsigned int)cmapGlyph,
                               pointSize);
                        CFRelease(glyphInfo);
                        CFRelease(emojiFont);
                        index = NSMaxRange(cluster);
                        continue;
                    }
                    /* Do not risk the old fallback path without the override. */
                } else {
                    [rendered addAttribute:(NSString *)kCTFontAttributeName
                                     value:(__bridge id)emojiFont
                                     range:cluster];
                    DBGLOG(@"[UnicodeCompat] %@ routed U+%04X to AppleColorEmoji %.0fpt",
                           message.snowflake ?: @"?",
                           (unsigned int)firstModernEmojiScalar,
                           pointSize);
                    CFRelease(emojiFont);
                    index = NSMaxRange(cluster);
                    continue;
                }
                CFRelease(emojiFont);
            }
        }

        NSDictionary *attributes = [rendered attributesAtIndex:cluster.location
                                                  effectiveRange:NULL];
        NSAttributedString *placeholder = [[NSAttributedString alloc]
            initWithString:@"\u25A1"
                attributes:attributes];
        [rendered replaceCharactersInRange:cluster
                      withAttributedString:placeholder];

        DBGLOG(@"[UnicodeCompat] %@ replaced %@ emoji cluster starting U+%04X for legacy rendering (charset %d cmapGlyph %u)",
               message.snowflake ?: @"?",
               simpleSingleScalar ? @"unsupported" : @"complex",
               (unsigned int)firstModernEmojiScalar,
               characterSetSupportsScalar ? 1 : 0,
               (unsigned int)cmapGlyph);

        /* Replacement is one BMP code unit. */
        index = cluster.location + 1;
    }

    message.attributedContent = [rendered copy];
}

static NSString *DCSystemMessageDisplayContent(DCMessage *message, NSDictionary *jsonMessage) {
    NSInteger type = message.messageType;
    NSString *authorName = [message.author displayName] ?: @"Unknown User";
    id rawContentValue = [jsonMessage objectForKey:@"content"];
    NSString *rawContent = [rawContentValue isKindOfClass:[NSString class]] ? rawContentValue : @"";

    switch (type) {
        case DCMessageTypeRecipientAdd: {
            id mentionsValue = [jsonMessage objectForKey:@"mentions"];
            NSDictionary *mention = [mentionsValue isKindOfClass:[NSArray class]]
                ? [(NSArray *)mentionsValue firstObject] : nil;
            NSString *targetName = [mention objectForKey:@"global_name"];
            if (![targetName isKindOfClass:[NSString class]] || targetName.length == 0) {
                targetName = [mention objectForKey:@"username"];
            }
            if (![targetName isKindOfClass:[NSString class]] || targetName.length == 0) {
                targetName = @"Deleted User";
            }
            return [NSString stringWithFormat:@"%@ added %@ to the group conversation.",
                    authorName, targetName];
        }
        case DCMessageTypeRecipientRemove:
            return [NSString stringWithFormat:@"%@ left the group conversation.", authorName];
        case DCMessageTypeCall:
            return [NSString stringWithFormat:@"%@ started a call.", authorName];
        case DCMessageTypeChannelNameChange:
            return rawContent.length
                ? [NSString stringWithFormat:@"%@ changed the group name to %@.", authorName, rawContent]
                : [NSString stringWithFormat:@"%@ changed the group name.", authorName];
        case DCMessageTypeChannelIconChange:
            return [NSString stringWithFormat:@"%@ changed the group icon.", authorName];
        case DCMessageTypeChannelPinnedMessage:
            return [NSString stringWithFormat:@"%@ pinned a message to this channel.", authorName];
        case DCMessageTypeUserJoin: {
            static NSArray *joinMessages;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                joinMessages = @[
                    @"%@ joined the party.",
                    @"%@ is here.",
                    @"Welcome, %@. We hope you brought pizza.",
                    @"A wild %@ appeared.",
                    @"%@ just landed.",
                    @"%@ just slid into the server.",
                    @"%@ just showed up!",
                    @"Welcome %@. Say hi!",
                    @"%@ hopped into the server.",
                    @"Everyone welcome %@!",
                    @"Glad you're here, %@.",
                    @"Good to see you, %@.",
                    @"Yay you made it, %@!",
                ];
            });
            uint64_t time = message.timestamp
                ? (uint64_t)([message.timestamp timeIntervalSince1970] * 1000.0)
                : (uint64_t)message.snowflake.longLongValue;
            return [NSString stringWithFormat:joinMessages[time % joinMessages.count], authorName];
        }
        case DCMessageTypeGuildBoost:
            return [NSString stringWithFormat:@"%@ just boosted the server!", authorName];
        case DCMessageTypeGuildBoostTier1:
            return [NSString stringWithFormat:@"%@ just boosted the server to Level 1!", authorName];
        case DCMessageTypeGuildBoostTier2:
            return [NSString stringWithFormat:@"%@ just boosted the server to Level 2!", authorName];
        case DCMessageTypeGuildBoostTier3:
            return [NSString stringWithFormat:@"%@ just boosted the server to Level 3!", authorName];
        case DCMessageTypeChannelFollowAdd:
            return [NSString stringWithFormat:@"%@ added a channel follow.", authorName];
        case DCMessageTypeThreadCreated:
            return rawContent.length
                ? [NSString stringWithFormat:@"%@ started a thread: %@.", authorName, rawContent]
                : [NSString stringWithFormat:@"%@ started a thread.", authorName];
        default:
            return nil;
    }
}


static NSCache *DCGuildAvatarCompositeCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        DCResourceManager *resources = [DCResourceManager sharedManager];
        cache.totalCostLimit = MAX((NSUInteger)(512 * 1024),
                                   resources.chatThumbnailMemoryBudget / 3);
        cache.countLimit = MAX((NSUInteger)24,
                               resources.imageMemoryCacheCountLimit * 2);
    });
    return cache;
}

static NSMutableSet *DCGuildAvatarRequestKeys(void) {
    static NSMutableSet *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [[NSMutableSet alloc] init];
    });
    return keys;
}

static NSString *DCGuildAvatarStringValue(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0
        ? (NSString *)value : nil;
}

static NSString *DCGuildAvatarCacheKey(DCUser *user, DCGuild *guild) {
    if (!user.snowflake.length || !guild.snowflake.length) return nil;

    NSString *guildAvatarID = DCGuildAvatarStringValue(
        [user.guildAvatarIDs objectForKey:guild.snowflake]);
    NSString *guildDecorationID = DCGuildAvatarStringValue(
        [user.guildAvatarDecorationIDs objectForKey:guild.snowflake]);
    NSString *baseID = guildAvatarID ?: DCGuildAvatarStringValue(user.avatarID);
    NSString *decorationID =
        guildDecorationID ?: DCGuildAvatarStringValue(user.avatarDecorationID);

    if (!guildAvatarID.length && !guildDecorationID.length) return nil;

    NSString *baseToken = baseID.length
        ? baseID
        : [NSString stringWithFormat:@"default:%ld", (long)user.discriminator];
    return [NSString stringWithFormat:@"%@:%@:%@:%@",
        guild.snowflake,
        user.snowflake,
        baseToken,
        decorationID ?: @"-"];
}

static NSUInteger DCImageMemoryCost(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return 0;
    return (NSUInteger)CGImageGetBytesPerRow(cgImage) *
           (NSUInteger)CGImageGetHeight(cgImage);
}

@implementation DCTools

+ (BOOL)isOriginalIPad {
    static BOOL isOriginalIPad = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct utsname systemInfo;
        if (uname(&systemInfo) == 0) {
            NSString *machine = [NSString stringWithCString:systemInfo.machine
                                                   encoding:NSUTF8StringEncoding];
            isOriginalIPad = [machine isEqualToString:@"iPad1,1"];
        }
    });
    return isOriginalIPad;
}


// Returns a parsed NSDictionary from a json string or nil if something goes
// wrong
+ (NSDictionary *)parseJSON:(NSString *)json {
    if (![json isKindOfClass:[NSString class]] || json.length == 0) return nil;

    // Gateway JSON arrives on WSWebSocket's callback queue. NSJSONSerialization
    // does not require the main thread, and forcing large READY payloads there
    // creates a complete UI stall before Gateway reconciliation even begins.
    NSError *error = nil;
    NSData *encodedResponseString = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsedResponse =
        [NSJSONSerialization JSONObjectWithData:encodedResponseString
                                        options:0
                                          error:&error];
    if (error) {
        DBGLOG(@"[GatewayJSON] Parse failed: %@", error);
        return nil;
    }
    if ([parsedResponse isKindOfClass:NSDictionary.class]) {
        return parsedResponse;
    }
    return nil;
}

+ (void)alert:(NSString *)title withMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertView *alert = [UIAlertView.alloc initWithTitle:title
                                                      message:message
                                                     delegate:nil
                                            cancelButtonTitle:@"OK"
                                            otherButtonTitles:nil];
        [alert show];
    });
}

// Used when making synchronous http requests
+ (NSData *)checkData:(NSData *)response withError:(NSError *)error {
    if (!response) {
        [DCTools alert:error.localizedDescription
            withMessage:error.localizedRecoverySuggestion];
        return nil;
    }
    return response;
}

// Converts an NSDictionary created from json representing a user into a DCUser
// object Also keeps the user in DCServerCommunicator.loadedUsers if cache:YES
+ (DCUser *)convertJsonUser:(NSDictionary *)jsonUser cache:(BOOL)cache {
    NSString *snowflake = [jsonUser objectForKey:@"id"];
    if (![snowflake isKindOfClass:[NSString class]] || snowflake.length == 0)
        return nil;

    // Treat Discord user payloads as patches to one canonical DCUser object.
    // Gateway payloads such as PRESENCE_UPDATE may contain only a subset of
    // user fields, so an absent key must never erase an existing value.
    DCUser *user = cache
        ? [DCServerCommunicator.sharedInstance userForSnowflake:snowflake]
        : nil;
    BOOL createdUser = (user == nil);
    if (!user) user = [DCUser new];

    user.snowflake = snowflake;

    id value = [jsonUser objectForKey:@"username"];
    if ([value isKindOfClass:[NSString class]]) {
        user.username = value;
    }

    if ([jsonUser objectForKey:@"global_name"] != nil) {
        value = [jsonUser objectForKey:@"global_name"];
        user.globalName = [value isKindOfClass:[NSString class]] ? value : nil;
    }

    if ([jsonUser objectForKey:@"avatar"] != nil) {
        value = [jsonUser objectForKey:@"avatar"];
        NSString *newAvatarID = [value isKindOfClass:[NSString class]] ? value : nil;
        NSString *oldAvatarID = ([user.avatarID isKindOfClass:[NSString class]])
            ? (NSString *)user.avatarID
            : nil;
        BOOL avatarChanged = (oldAvatarID != newAvatarID) &&
            ![oldAvatarID isEqualToString:newAvatarID];

        if (avatarChanged) {
            user.avatarID = newAvatarID;
            // The CDN URL is hash-versioned. Clearing only the runtime images is
            // enough; the next request naturally uses the new avatar hash and
            // SDWebImage will either hit that URL on disk or fetch it.
            user.profileImage = nil;
            user.rawProfileImage = nil;
        } else if (createdUser) {
            user.avatarID = newAvatarID;
        }
    }

    if ([jsonUser objectForKey:@"avatar_decoration_data"] != nil) {
        id decorationData = [jsonUser objectForKey:@"avatar_decoration_data"];
        NSString *newDecorationID = nil;
        if ([decorationData isKindOfClass:[NSDictionary class]]) {
            id asset = [decorationData objectForKey:@"asset"];
            if ([asset isKindOfClass:[NSString class]]) newDecorationID = asset;
        }

        NSString *oldDecorationID =
            ([user.avatarDecorationID isKindOfClass:[NSString class]])
                ? (NSString *)user.avatarDecorationID
                : nil;
        BOOL decorationChanged = (oldDecorationID != newDecorationID) &&
            ![oldDecorationID isEqualToString:newDecorationID];
        if (decorationChanged) {
            user.avatarDecorationID = newDecorationID;
            user.avatarDecoration = nil;
            // profileImage may already contain the old decoration composite.
            // Rebuild it lazily from rawProfileImage when the new decoration is
            // requested.
            user.profileImage = nil;
        } else if (createdUser) {
            user.avatarDecorationID = newDecorationID;
        }
    }

    if ([jsonUser objectForKey:@"discriminator"] != nil) {
        value = [jsonUser objectForKey:@"discriminator"];
        if ([value respondsToSelector:@selector(integerValue)])
            user.discriminator = [value integerValue];
    }

    if (createdUser) {
        user.status = DCUserStatusOffline;
        user.guildNicknames = [NSMutableDictionary dictionary];
        user.guildAvatarIDs = [NSMutableDictionary dictionary];
        user.guildAvatarDecorationIDs = [NSMutableDictionary dictionary];
    } else {
        if (!user.guildNicknames)
            user.guildNicknames = [NSMutableDictionary dictionary];
        if (!user.guildAvatarIDs)
            user.guildAvatarIDs = [NSMutableDictionary dictionary];
        if (!user.guildAvatarDecorationIDs)
            user.guildAvatarDecorationIDs = [NSMutableDictionary dictionary];
    }

    if (cache) {
        [DCServerCommunicator.sharedInstance setUser:user forSnowflake:snowflake];
    }

    return user;
}

+ (void)getUserAvatar:(DCUser *)user {
    @autoreleasepool {
        // Bail if already downloading
        if (user.profileImage && user.profileImage.size.width == 0) {
            return; // placeholder is set, download already in flight
        }
        
        user.profileImage     = [UIImage new];
        user.avatarDecoration = [UIImage new];

        if (!user.avatarID || (NSNull *)user.avatarID == [NSNull null]) {
            int selector = 0;
            if (user.discriminator == 0) {
                NSNumber *longId = @([user.snowflake longLongValue]);
                selector = ([longId longLongValue] >> 22) % 6;
            } else {
                selector = user.discriminator % 5;
            }
            user.profileImage = [DCContentManager processedIcon:[DCUser defaultAvatars][selector] context:DCAssetContextChat];
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD USER DATA"
                                  object:user];
            });
            return;
        }

        SDWebImageManager *manager = [SDWebImageManager sharedManager];
        NSURL *avatarURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.discordapp.com/avatars/%@/%@.png?size=80",
            user.snowflake, user.avatarID]];

        [manager downloadImageWithURL:avatarURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *retrievedImage, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                @autoreleasepool {
                                    if (!retrievedImage || !finished) {
                                        int selector = 0;
                                        if (user.discriminator == 0) {
                                            NSNumber *longId = @([user.snowflake longLongValue]);
                                            selector = ([longId longLongValue] >> 22) % 6;
                                        } else {
                                            selector = user.discriminator % 5;
                                        }
                                        user.profileImage = [DCContentManager processedIcon:[DCUser defaultAvatars][selector] context:DCAssetContextChat];
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            [NSNotificationCenter.defaultCenter
                                                postNotificationName:@"RELOAD USER DATA"
                                                              object:user];
                                        });
                                        return;
                                    }

                                    // Process avatar — if decoration is already loaded, composite now
                                    // Otherwise just round and store, decoration will composite when it arrives
                                    if (user.avatarDecoration && [user.avatarDecoration isKindOfClass:[UIImage class]]
                                        && user.avatarDecoration.size.width > 0) {
                                        user.rawProfileImage = retrievedImage;
                                        user.profileImage = [DCContentManager processedAvatarForUser:user context:DCAssetContextChat];
                                    } else {
                                        // avatar completion block — store raw, then process
                                        user.rawProfileImage = retrievedImage;
                                        user.profileImage = [DCContentManager processedAvatarForUser:user context:DCAssetContextChat];
                                    }

                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        [NSNotificationCenter.defaultCenter
                                            postNotificationName:@"RELOAD USER DATA"
                                                          object:user];
                                    });
                                }
                            }];

        if (!user.avatarDecorationID || (NSNull *)user.avatarDecorationID == [NSNull null]) {
            return;
        }

        NSURL *avatarDecorationURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.discordapp.com/avatar-decoration-presets/%@.png?size=96&passthrough=false",
            user.avatarDecorationID]];

        [manager downloadImageWithURL:avatarDecorationURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *retrievedImage, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                if (!retrievedImage || !finished) {
                                    NSLog(@"Failed to download avatar decoration: %@", error);
                                    return;
                                }
                                user.avatarDecoration = retrievedImage;
                                // Only recomposite if the base avatar has already arrived
                                // If not, the avatar completion block will composite both when it finishes
                                if (!user.rawProfileImage || user.rawProfileImage.size.width == 0) {
                                    return;
                                }
                                user.profileImage = [DCContentManager processedAvatarForUser:user context:DCAssetContextChat];
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [NSNotificationCenter.defaultCenter
                                        postNotificationName:@"RELOAD USER DATA"
                                                      object:user];
                                });
                            }];
    }
}


+ (UIImage *)cachedUserAvatar:(DCUser *)user inGuild:(DCGuild *)guild {
    if (!user) return nil;
    if (!guild.snowflake.length) return user.profileImage;

    NSString *cacheKey = DCGuildAvatarCacheKey(user, guild);
    if (!cacheKey.length) return user.profileImage;
    return [DCGuildAvatarCompositeCache() objectForKey:cacheKey];
}

+ (void)getUserAvatar:(DCUser *)user inGuild:(DCGuild *)guild {
    if (!user || !user.snowflake.length) return;
    if (!guild.snowflake.length) {
        [self getUserAvatar:user];
        return;
    }

    NSString *guildID = guild.snowflake;
    NSString *guildAvatarID = DCGuildAvatarStringValue(
        [user.guildAvatarIDs objectForKey:guildID]);
    NSString *guildDecorationID = DCGuildAvatarStringValue(
        [user.guildAvatarDecorationIDs objectForKey:guildID]);

    if (!guildAvatarID.length && !guildDecorationID.length) {
        [self getUserAvatar:user];
        return;
    }

    NSString *cacheKey = DCGuildAvatarCacheKey(user, guild);
    if (!cacheKey.length || [DCGuildAvatarCompositeCache() objectForKey:cacheKey]) {
        return;
    }

    NSMutableSet *requestKeys = DCGuildAvatarRequestKeys();
    @synchronized(requestKeys) {
        if ([requestKeys containsObject:cacheKey]) return;
        [requestKeys addObject:cacheKey];
    }

    NSString *baseAvatarID =
        guildAvatarID ?: DCGuildAvatarStringValue(user.avatarID);
    NSString *decorationID =
        guildDecorationID ?: DCGuildAvatarStringValue(user.avatarDecorationID);

    __block UIImage *rawAvatar = nil;
    __block UIImage *decoration = nil;

    BOOL usesGuildAvatar = guildAvatarID.length > 0;
    BOOL usesGuildDecoration = guildDecorationID.length > 0;

    if (!usesGuildAvatar &&
        user.rawProfileImage &&
        user.rawProfileImage.size.width > 0) {
        rawAvatar = user.rawProfileImage;
    }

    if (!usesGuildDecoration && decorationID.length &&
        user.avatarDecoration &&
        user.avatarDecoration.size.width > 0) {
        decoration = user.avatarDecoration;
    }

    if (!baseAvatarID.length) {
        NSInteger selector = 0;
        if (user.discriminator == 0) {
            selector = (([user.snowflake longLongValue] >> 22) % 6);
        } else {
            selector = user.discriminator % 5;
        }
        rawAvatar = [[DCUser defaultAvatars] objectAtIndex:(NSUInteger)selector];
    }

    SDWebImageManager *manager = [SDWebImageManager sharedManager];
    dispatch_group_t group = dispatch_group_create();

    if (!rawAvatar && baseAvatarID.length) {
        NSURL *avatarURL = nil;
        if (usesGuildAvatar) {
            avatarURL = [NSURL URLWithString:[NSString stringWithFormat:
                @"https://cdn.discordapp.com/guilds/%@/users/%@/avatars/%@.png?size=80",
                guildID, user.snowflake, baseAvatarID]];
        } else {
            avatarURL = [NSURL URLWithString:[NSString stringWithFormat:
                @"https://cdn.discordapp.com/avatars/%@/%@.png?size=80",
                user.snowflake, baseAvatarID]];
        }

        dispatch_group_enter(group);
        [manager downloadImageWithURL:avatarURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *retrievedImage, NSError *error,
                                        SDImageCacheType cacheType, BOOL finished,
                                        NSURL *imageURL) {
            if (retrievedImage && finished) {
                rawAvatar = retrievedImage;
            } else if (user.rawProfileImage && user.rawProfileImage.size.width > 0) {
                rawAvatar = user.rawProfileImage;
            }
            dispatch_group_leave(group);
        }];
    }

    if (!decoration && decorationID.length) {
        NSURL *decorationURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.discordapp.com/avatar-decoration-presets/%@.png?size=96&passthrough=false",
            decorationID]];
        dispatch_group_enter(group);
        [manager downloadImageWithURL:decorationURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *retrievedImage, NSError *error,
                                        SDImageCacheType cacheType, BOOL finished,
                                        NSURL *imageURL) {
            if (retrievedImage && finished) {
                decoration = retrievedImage;
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            UIImage *avatar = rawAvatar;
            if (!avatar) {
                NSInteger selector = 0;
                if (user.discriminator == 0) {
                    selector = (([user.snowflake longLongValue] >> 22) % 6);
                } else {
                    selector = user.discriminator % 5;
                }
                avatar = [[DCUser defaultAvatars] objectAtIndex:(NSUInteger)selector];
            }

            UIImage *processed =
                [DCContentManager processedAvatarImage:avatar
                                            decoration:decoration
                                               context:DCAssetContextChat];
            if (processed) {
                [DCGuildAvatarCompositeCache() setObject:processed
                                                  forKey:cacheKey
                                                    cost:DCImageMemoryCost(processed)];
            }

            @synchronized(requestKeys) {
                [requestKeys removeObject:cacheKey];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"RELOAD USER DATA"
                                  object:user];
            });
        }
    });
}

+ (void)purgeGuildAvatarCache {
    [DCGuildAvatarCompositeCache() removeAllObjects];
}

// Converts an NSDictionary created from json representing a role into a DCRole
// object Also keeps the role in DCServerCommunicator.loadedUsers if cache:YES
+ (DCRole *)convertJsonRole:(NSDictionary *)jsonRole cache:(BOOL)cache {
    NSString *snowflake = [jsonRole objectForKey:@"id"];
    if (![snowflake isKindOfClass:[NSString class]] || snowflake.length == 0)
        return nil;

    // Preserve canonical role identity during READY/live guild refreshes just
    // like convertJsonEmoji: does. Besides avoiding thousands of short-lived
    // DCRole allocations, any object already holding a role reference observes
    // the refreshed metadata in place.
    DCRole *newRole = cache
        ? [DCServerCommunicator.sharedInstance roleForSnowflake:snowflake]
        : nil;
    if (!newRole) newRole = DCRole.new;

    newRole.snowflake    = snowflake;
    newRole.name         = [jsonRole objectForKey:@"name"];
    newRole.color        = [[jsonRole objectForKey:@"color"] intValue];
    newRole.hoist        = [[jsonRole objectForKey:@"hoist"] boolValue];
    newRole.iconID       = [jsonRole objectForKey:@"icon"];          // can be NSNull
    newRole.unicodeEmoji = [jsonRole objectForKey:@"unicode_emoji"]; // can be nil
    newRole.position     = [[jsonRole objectForKey:@"position"] intValue];
    newRole.permissions  = [jsonRole objectForKey:@"permissions"];
    newRole.managed      = [[jsonRole objectForKey:@"managed"] boolValue];
    newRole.mentionable  = [[jsonRole objectForKey:@"mentionable"] boolValue];

    if (cache)
        [DCServerCommunicator.sharedInstance setRole:newRole forSnowflake:snowflake];

    return newRole;
}

+ (void)getRoleIcon:(DCRole *)role {
    @autoreleasepool {
        role.icon = [UIImage new];

        if ((NSNull *)role.snowflake == [NSNull null] || (NSNull *)role.iconID == [NSNull null]) {
            return;
        }
        SDWebImageManager *manager = [SDWebImageManager sharedManager];
        NSURL *iconURL             = [NSURL URLWithString:[NSString
                                                  stringWithFormat:
                                                      @"https://cdn.discordapp.com/role-icons/%@/%@.png?size=80",
                                                      role.snowflake, role.iconID]];
        [manager downloadImageWithURL:iconURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *retrievedImage, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                @autoreleasepool {
                                    if (!retrievedImage || !finished) {
                                        NSLog(@"Failed to download role icon with URL %@: %@", iconURL, error);
                                        return;
                                    }
                                    role.icon = retrievedImage;
                                    dispatch_async(
                                        dispatch_get_main_queue(),
                                        ^{
                                            [NSNotificationCenter
                                                    .defaultCenter
                                                postNotificationName:
                                                    @"RELOAD MESSAGE DATA"
                                                              object:nil];
                                        }
                                    );
                                }
                            }];
    }
}

+ (UILazyImage *)scaledImageFromImage:(UIImage *)image withURL:(NSURL *)url {
    if (!image) return nil;

    // Keep chat media at source resolution; visible attachment views own scaling and rounding.
    UILazyImage *lazyImage = [UILazyImage new];
    lazyImage.image = image;
    lazyImage.imageURL = url;
    return lazyImage;
}

+ (DCEmoji *)convertJsonEmoji:(NSDictionary *)jsonEmoji cache:(BOOL)cache {
    NSString *snowflake = [jsonEmoji objectForKey:@"id"];
    if (![snowflake isKindOfClass:[NSString class]] || snowflake.length == 0)
        return nil;

    // READY and GUILD_EMOJIS_UPDATE are authoritative metadata snapshots.
    // Cached/custom-message parsing may already have created the canonical
    // emoji object, so patch that object instead of returning stale metadata.
    DCEmoji *emoji = cache
        ? [DCServerCommunicator.sharedInstance emojiForSnowflake:snowflake]
        : nil;
    if (!emoji) emoji = [DCEmoji new];

    emoji.snowflake = snowflake;
    id name = [jsonEmoji objectForKey:@"name"];
    if ([name isKindOfClass:[NSString class]]) emoji.name = name;
    id animated = [jsonEmoji objectForKey:@"animated"];
    if ([animated respondsToSelector:@selector(boolValue)])
        emoji.animated = [animated boolValue];

    if (cache)
        [DCServerCommunicator.sharedInstance setEmoji:emoji forSnowflake:snowflake];

    return emoji;
}

static void DCFillMissingUserFieldsFromJSON(DCUser *user, NSDictionary *jsonUser) {
    if (!user || ![jsonUser isKindOfClass:[NSDictionary class]]) return;

    id value = [jsonUser objectForKey:@"username"];
    if (!user.username.length && [value isKindOfClass:[NSString class]])
        user.username = value;

    value = [jsonUser objectForKey:@"global_name"];
    if (!user.globalName.length && [value isKindOfClass:[NSString class]])
        user.globalName = value;

    value = [jsonUser objectForKey:@"avatar"];
    if (!user.avatarID && [value isKindOfClass:[NSString class]])
        user.avatarID = value;

    if (!user.avatarDecorationID) {
        id decorationData = [jsonUser objectForKey:@"avatar_decoration_data"];
        if ([decorationData isKindOfClass:[NSDictionary class]]) {
            id asset = [decorationData objectForKey:@"asset"];
            if ([asset isKindOfClass:[NSString class]])
                user.avatarDecorationID = asset;
        }
    }

    value = [jsonUser objectForKey:@"discriminator"];
    if (user.discriminator == 0 &&
        [value respondsToSelector:@selector(integerValue)])
        user.discriminator = [value integerValue];
}

// Converts an NSDictionary created from json representing a message into a
// message object
+ (DCMessage *)convertJsonMessage:(NSDictionary *)jsonMessage {
    return [self convertJsonMessage:jsonMessage
                 deferLegacyLayout:NO
                           channel:DCServerCommunicator.sharedInstance.selectedChannel];
}

+ (DCMessage *)convertJsonMessage:(NSDictionary *)jsonMessage
                 deferLegacyLayout:(BOOL)deferLegacyLayout {
    return [self convertJsonMessage:jsonMessage
                 deferLegacyLayout:deferLegacyLayout
                           channel:DCServerCommunicator.sharedInstance.selectedChannel];
}

+ (DCMessage *)convertJsonMessage:(NSDictionary *)jsonMessage
                 deferLegacyLayout:(BOOL)deferLegacyLayout
                           channel:(DCChannel *)channel {
    DCChannel *contextChannel = channel;
    CFAbsoluteTime perfStart = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime perfIdentityEnd = perfStart;
    CFAbsoluteTime perfDatesEnd = perfStart;
    CFAbsoluteTime perfMediaEnd = perfStart;
    CFAbsoluteTime perfMentionsEnd = perfStart;
    CFAbsoluteTime perfEmojizeEnd = perfStart;
    CFAbsoluteTime perfMarkdownEnd = perfStart;
    CFAbsoluteTime perfLayoutEnd = perfStart;
    CFAbsoluteTime perfTailEnd = perfStart;
    NSString *measurementMode = @"none";

    DCMessage *newMessage = DCMessage.new;
    // The message-window cache persists this server payload verbatim and replays
    // it through this same converter on cold restore. Keep rendering logic here
    // as the single source of truth.
    if ([jsonMessage isKindOfClass:[NSDictionary class]]) {
        newMessage.sourceJSON = [NSDictionary dictionaryWithDictionary:jsonMessage];
    }
    @autoreleasepool {
        NSDictionary *author = [jsonMessage objectForKey:@"author"];
        NSString *authorId   = author ? [author objectForKey:@"id"] : nil;

        DCUser *authorUser = [DCServerCommunicator.sharedInstance userForSnowflake:authorId];
        if (!authorUser && authorId != nil && ![authorId isKindOfClass:[NSNull class]]) {
            authorUser = [DCTools convertJsonUser:[jsonMessage valueForKeyPath:@"author"] cache:YES];
        } else {
            DCFillMissingUserFieldsFromJSON(authorUser, author);
        }

        // Message member data is useful as an early display fallback, but it
        // must not override member state already resolved by live guild data.
        NSDictionary *memberDict = [jsonMessage objectForKey:@"member"];
        if (authorUser && [memberDict isKindOfClass:[NSDictionary class]]) {
            NSString *guildID = [jsonMessage objectForKey:@"guild_id"];
            if (![guildID isKindOfClass:[NSString class]] || guildID.length == 0)
                guildID = contextChannel.parentGuild.snowflake;
            [DCServerCommunicator.sharedInstance
                applyGuildProfileFromMember:memberDict
                                      toUser:authorUser
                                     guildID:guildID
                               authoritative:NO];
        }

        // load referenced message if it exists
        float contentWidth = UIScreen.mainScreen.bounds.size.width - 63;

        id rawType = [jsonMessage objectForKey:@"type"];

        if ([rawType respondsToSelector:@selector(integerValue)]) {
            newMessage.messageType = [rawType integerValue];
        } else {
            newMessage.messageType = DCMessageTypeDefault;
        }
        
        BOOL isReply = newMessage.messageType == DCMessageTypeReply;

        NSDictionary *referenceMetadata = nil;
        id rawReferenceMetadata = [jsonMessage objectForKey:@"message_reference"];

        if ([rawReferenceMetadata
                isKindOfClass:[NSDictionary class]]) {
            referenceMetadata = rawReferenceMetadata;
        }

        id rawReferencedMessage = [jsonMessage objectForKey:@"referenced_message"];

        NSString *referenceID = nil;

        if ([rawReferencedMessage
                isKindOfClass:[NSDictionary class]]) {
            referenceID = [(NSDictionary *)rawReferencedMessage objectForKey:@"id"];
        }

        if (!referenceID.length) {
            id metadataID =
                [referenceMetadata objectForKey:@"message_id"];

            if ([metadataID isKindOfClass:[NSString class]]) {
                referenceID = metadataID;
            }
        }

        if (isReply) {
            DCMessage *reference = [DCMessage new];
            reference.snowflake = referenceID;
            reference.authorNameWidth = 80.0f;

            if ([rawReferencedMessage
                    isKindOfClass:[NSDictionary class]]) {

                NSDictionary *referenceJSON =
                    rawReferencedMessage;

                NSDictionary *authorJSON =
                    [referenceJSON objectForKey:@"author"];

                NSString *authorID = nil;

                if ([authorJSON
                        isKindOfClass:[NSDictionary class]]) {
                    id rawAuthorID = [authorJSON objectForKey:@"id"];

                    if ([rawAuthorID
                            isKindOfClass:[NSString class]]) {
                        authorID = rawAuthorID;
                    }
                }

                DCUser *referenceAuthor = nil;

                if (authorID.length) {
                    referenceAuthor = [DCServerCommunicator.sharedInstance userForSnowflake:authorID];

                    if (!referenceAuthor) {
                        referenceAuthor = [DCTools convertJsonUser:authorJSON cache:YES];
                    } else {
                        DCFillMissingUserFieldsFromJSON(referenceAuthor, authorJSON);
                    }
                }

                NSString *content = [referenceJSON objectForKey:@"content"];

                if (![content isKindOfClass:[NSString class]]) {
                    content = nil;
                }

                if (referenceAuthor && referenceID.length) {
                    reference.author = referenceAuthor;

                    if (content.length) {
                        reference.content = content;
                    } else {
                        reference.content = @"Click to view attachment";
                    }

                    newMessage.referencedMessageState = DCMessageReferenceStateResolved;
                } else {
                    reference.content = @"Unable to load message";

                    newMessage.referencedMessageState = DCMessageReferenceStateUnavailable;
                }
            } else if (rawReferencedMessage ==
                       [NSNull null]) {
                reference.content = @"Message deleted";

                newMessage.referencedMessageState = DCMessageReferenceStateDeleted;
            } else {
                reference.content = @"Unable to load message";

                newMessage.referencedMessageState = DCMessageReferenceStateUnavailable;
            }

            newMessage.referencedMessage = reference;
        }

        newMessage.author          = authorUser;
        newMessage.content         = [jsonMessage objectForKey:@"content"];
        newMessage.rawContent      = newMessage.content;
        newMessage.snowflake       = [jsonMessage objectForKey:@"id"];
        NSString *messageChannelID = [[jsonMessage objectForKey:@"channel_id"]
            isKindOfClass:[NSString class]] ? [jsonMessage objectForKey:@"channel_id"] : nil;
        if (!messageChannelID.length) {
            messageChannelID = contextChannel.snowflake;
        }
        newMessage.attachments     = NSMutableArray.new;
        newMessage.attachmentCount = 0;
        perfIdentityEnd = CFAbsoluteTimeGetCurrent();

        /*
         * These formatters used to have their locale/dateFormat reset for every
         * message.  On iOS 5/6 NSDateFormatter setup is extremely expensive and
         * cold window restore runs this path up to 80 times in one main-thread
         * burst.  Keep two immutable input formatters instead: one for Discord's
         * fractional-second timestamps and one for the fallback whole-second
         * form.
         */
        static dispatch_once_t messageDateFormatOnceToken;
        static NSDateFormatter *fractionalDateFormatter;
        static NSDateFormatter *wholeSecondDateFormatter;
        static NSDateFormatter *prettyDateFormatter;
        dispatch_once(&messageDateFormatOnceToken, ^{
            NSLocale *posix = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

            fractionalDateFormatter = [NSDateFormatter new];
            fractionalDateFormatter.locale = posix;
            fractionalDateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ";

            wholeSecondDateFormatter = [NSDateFormatter new];
            wholeSecondDateFormatter.locale = posix;
            wholeSecondDateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";

            prettyDateFormatter = [NSDateFormatter new];
            prettyDateFormatter.dateStyle = NSDateFormatterShortStyle;
            prettyDateFormatter.timeStyle = NSDateFormatterShortStyle;
            prettyDateFormatter.doesRelativeDateFormatting = YES;
        });

        // Normalize timezone +HH:MM -> +HHMM for iOS 5 compatibility.
        NSString *rawTimestamp = [jsonMessage objectForKey:@"timestamp"];
        if (![rawTimestamp isKindOfClass:[NSString class]]) rawTimestamp = nil;
        if (rawTimestamp.length > 6) {
            NSString *tzPart = [rawTimestamp substringFromIndex:rawTimestamp.length - 6];
            if ([tzPart characterAtIndex:3] == ':') {
                rawTimestamp = [rawTimestamp stringByReplacingCharactersInRange:NSMakeRange(rawTimestamp.length - 3, 1) withString:@""];
            }
        }
        newMessage.timestamp = [fractionalDateFormatter dateFromString:rawTimestamp];
        if (newMessage.timestamp == nil && rawTimestamp.length) {
            newMessage.timestamp = [wholeSecondDateFormatter dateFromString:rawTimestamp];
        }

        id editedTimestampValue = [jsonMessage objectForKey:@"edited_timestamp"];
        if (editedTimestampValue != [NSNull null] &&
            [editedTimestampValue isKindOfClass:[NSString class]]) {
            NSString *rawEditedTimestamp = editedTimestampValue;
            if (rawEditedTimestamp.length > 6) {
                NSString *tzPart = [rawEditedTimestamp substringFromIndex:rawEditedTimestamp.length - 6];
                if ([tzPart characterAtIndex:3] == ':') {
                    rawEditedTimestamp = [rawEditedTimestamp stringByReplacingCharactersInRange:
                        NSMakeRange(rawEditedTimestamp.length - 3, 1) withString:@""];
                }
            }
            newMessage.editedTimestamp =
                [fractionalDateFormatter dateFromString:rawEditedTimestamp];
            if (newMessage.editedTimestamp == nil && rawEditedTimestamp.length) {
                newMessage.editedTimestamp =
                    [wholeSecondDateFormatter dateFromString:rawEditedTimestamp];
            }
        }

        newMessage.prettyTimestamp = newMessage.timestamp
            ? [prettyDateFormatter stringFromDate:newMessage.timestamp]
            : @"";

        NSString *systemContent = DCSystemMessageDisplayContent(newMessage, jsonMessage);
        if (systemContent.length) {
            newMessage.content = systemContent;
        }

        perfDatesEnd = CFAbsoluteTimeGetCurrent();
        // Load embeded images from both links and attatchments
        // ─── EMBEDS ───────────────────────────────────────────────────────────────────
        // Discord embeds are rich previews generated server-side from links in messages.
        // Image embeds use the image path, gifv embeds use GIF-like presentation when
        // Discord supplies a playable video rendition, and video embeds use video chrome.
        NSArray *embeds = [jsonMessage objectForKey:@"embeds"];
        if (embeds) {
            for (NSDictionary *embed in embeds) {
                NSString *embedType = [embed objectForKey:@"type"];
                NSString *originalEmbedURL = [[embed objectForKey:@"url"] isKindOfClass:[NSString class]]
                    ? [embed objectForKey:@"url"] : nil;
                NSURL *originalEmbedNSURL = [NSURL URLWithString:originalEmbedURL];
                NSString *originalPathExtension = originalEmbedNSURL.pathExtension.lowercaseString;
                BOOL isGifvEmbed = [embedType isEqualToString:@"gifv"];
                NSString *gifvProxyVideoURL = [[embed valueForKeyPath:@"video.proxy_url"] isKindOfClass:[NSString class]]
                    ? [embed valueForKeyPath:@"video.proxy_url"] : nil;
                NSString *gifvVideoURL = [[embed valueForKeyPath:@"video.url"] isKindOfClass:[NSString class]]
                    ? [embed valueForKeyPath:@"video.url"] : nil;
                NSString *gifvPlaybackURL = gifvProxyVideoURL.length ? gifvProxyVideoURL : gifvVideoURL;
                BOOL hasGifvPlayback = isGifvEmbed && gifvPlaybackURL.length > 0;
                BOOL hasGifvImageFallback = isGifvEmbed && [originalPathExtension isEqualToString:@"gif"];

                // gifv describes GIF-like presentation regardless of provider. Prefer the
                // supplied video rendition, with a direct GIF as a fallback when available.
                if ([embedType isEqualToString:@"image"] || hasGifvPlayback || hasGifvImageFallback) {
                    newMessage.attachmentCount++;

                    NSString *proxyImageURL = [[embed valueForKeyPath:@"image.proxy_url"] isKindOfClass:[NSString class]]
                        ? [embed valueForKeyPath:@"image.proxy_url"] : nil;
                    NSString *imageURL = [[embed valueForKeyPath:@"image.url"] isKindOfClass:[NSString class]]
                        ? [embed valueForKeyPath:@"image.url"] : nil;
                    NSString *proxyThumbnailURL = [[embed valueForKeyPath:@"thumbnail.proxy_url"] isKindOfClass:[NSString class]]
                        ? [embed valueForKeyPath:@"thumbnail.proxy_url"] : nil;
                    NSString *thumbnailURL = [[embed valueForKeyPath:@"thumbnail.url"] isKindOfClass:[NSString class]]
                        ? [embed valueForKeyPath:@"thumbnail.url"] : nil;
                    NSString *thumbnailSourceURL = proxyThumbnailURL.length
                        ? proxyThumbnailURL
                        : (thumbnailURL.length ? thumbnailURL : originalEmbedURL);
                    NSString *imageSourceURL = proxyImageURL.length
                        ? proxyImageURL
                        : (imageURL.length ? imageURL : thumbnailSourceURL);

                    if (DCMessageContentIsOnlyURL(newMessage.content, originalEmbedURL)) {
                        newMessage.content = @"";
                    }

                    BOOL isGif = isGifvEmbed || [originalPathExtension isEqualToString:@"gif"];
                    NSString *attachmentURL = [embedType isEqualToString:@"image"]
                        ? imageSourceURL
                        : thumbnailSourceURL;

                    BOOL videoBackedGif = hasGifvPlayback;
                    if (videoBackedGif) {
                        attachmentURL = gifvPlaybackURL;
                    } else if (hasGifvImageFallback) {
                        attachmentURL = originalEmbedURL;
                    }

                    NSInteger width = 0;
                    NSInteger height = 0;
                    if ([embedType isEqualToString:@"image"]) {
                        width = [[embed valueForKeyPath:@"image.width"] integerValue];
                        height = [[embed valueForKeyPath:@"image.height"] integerValue];
                    }
                    if (width <= 0 || height <= 0) {
                        width = [[embed valueForKeyPath:@"thumbnail.width"] integerValue];
                        height = [[embed valueForKeyPath:@"thumbnail.height"] integerValue];
                    }
                    if (width <= 0 || height <= 0) {
                        width = [[embed valueForKeyPath:@"video.width"] integerValue];
                        height = [[embed valueForKeyPath:@"video.height"] integerValue];
                    }
                    CGFloat aspectRatio = (width > 0 && height > 0)
                        ? (CGFloat)width / (CGFloat)height : 1.0f;

                    if (height > 1024) {
                        height = 1024;
                        width  = height * aspectRatio;
                        if (width > 1024) {
                            width  = 1024;
                            height = width / aspectRatio;
                        }
                    } else if (width > 1024) {
                        width  = 1024;
                        height = width / aspectRatio;
                        if (height > 1024) {
                            height = 1024;
                            width  = height * aspectRatio;
                        }
                    }

                    // Weed out webp images and request a png that iOS can present
                    // URL Construction
                    // Build the final download URL, requesting PNG format to ensure iOS compatibility.
                    // Some Discord CDN URLs already have width/height baked in — don't append them again.
                    // Always trim trailing & or ? before appending parameters to avoid malformed URLs.
                    NSURL *urlString = nil;
                    if (videoBackedGif) {
                        urlString = [NSURL URLWithString:thumbnailSourceURL];
                    } else {
                        BOOL alreadyHasDimensions = [attachmentURL rangeOfString:@"width="].location != NSNotFound;
                        if (alreadyHasDimensions) {
                            NSString *trimmedURL = [attachmentURL stringByTrimmingCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"&?"]];
                            urlString = [NSURL URLWithString:[NSString
                                stringWithFormat:@"%@%cformat=png", trimmedURL,
                                [trimmedURL rangeOfString:@"?"].location == NSNotFound ? '?' : '&']];
                        } else if (width != 0 || height != 0) {
                            NSString *trimmedURL = [attachmentURL stringByTrimmingCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"&?"]];
                            urlString = [NSURL URLWithString:[NSString
                                stringWithFormat:@"%@%cformat=png&width=%ld&height=%ld", trimmedURL,
                                [trimmedURL rangeOfString:@"?"].location == NSNotFound ? '?' : '&',
                                (long)width, (long)height]];
                        } else {
                            NSString *trimmedURL = [attachmentURL stringByTrimmingCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"&?"]];
                            urlString = [NSURL URLWithString:[NSString
                                stringWithFormat:@"%@%cformat=png", trimmedURL,
                                [trimmedURL rangeOfString:@"?"].location == NSNotFound ? '?' : '&']];
                        }
                    }

                    // Publish geometry/URLs only; visible attachment views own decoded pixels.
                    if (isGif) {
                        DCGifInfo *gif = [DCGifInfo new];
                        gif.gifURL = DCRegisterChatMediaURL([NSURL URLWithString:attachmentURL], messageChannelID, newMessage.snowflake);
                        gif.thumbnailURL = DCRegisterChatMediaURL(urlString, messageChannelID, newMessage.snowflake);
                        gif.naturalSize = CGSizeMake(width, height);
                        gif.videoBacked = videoBackedGif;
                        [newMessage.attachments addObject:gif];
                    } else {
                        UILazyImage *lazyImage = [UILazyImage new];
                        lazyImage.imageURL = DCRegisterChatMediaURL([NSURL URLWithString:attachmentURL], messageChannelID, newMessage.snowflake);
                        lazyImage.naturalSize = CGSizeMake(width, height);
                        [newMessage.attachments addObject:lazyImage];
                    }
                } else if ([embedType isEqualToString:@"video"] || isGifvEmbed) {
                    // Video Embed
                    // Handle normal video embeds and malformed gifv embeds that do not include
                    // a playable video rendition.
                    // videoURL = the actual playable video URL passed to MPMoviePlayerViewController.
                    // baseURL = the thumbnail image URL for the cell preview.
                    BOOL isYouTube = originalEmbedURL &&
                        ([originalEmbedURL hasPrefix:@"https://www.youtube.com"] ||
                         [originalEmbedURL hasPrefix:@"https://m.youtube.com"]   ||
                         [originalEmbedURL hasPrefix:@"https://youtube.com"]     ||
                         [originalEmbedURL hasPrefix:@"https://youtu.be"]);

                    NSURL *attachmentURL;

                    if (!isYouTube && DCMessageContentIsOnlyURL(newMessage.content, originalEmbedURL)) {
                        newMessage.content = @"";
                    }
                    if ([embed valueForKeyPath:@"video.proxy_url"] != nil &&
                        [[embed valueForKeyPath:@"video.proxy_url"]
                            isKindOfClass:[NSString class]]) {
                        attachmentURL = [NSURL URLWithString:[embed valueForKeyPath:@"video.proxy_url"]];
                    } else if ([embed valueForKeyPath:@"video.url"] != nil &&
                               [[embed valueForKeyPath:@"video.url"] isKindOfClass:[NSString class]]) {
                        attachmentURL = [NSURL URLWithString:[embed valueForKeyPath:@"video.url"]];
                    } else {
                        attachmentURL = [NSURL URLWithString:originalEmbedURL];
                    }
                    CFAbsoluteTime videoViewStart = CFAbsoluteTimeGetCurrent();
                    DCChatVideoAttachment *video = [[DCChatVideoAttachment alloc]
                        initMetadataOnly];
                    NSTimeInterval videoViewTime = CFAbsoluteTimeGetCurrent() - videoViewStart;
                    if (videoViewTime >= 0.008) {
                        NSLog(@"[MediaPerf] video view build %.1fms", videoViewTime * 1000.0);
                    }

                    video.videoURL = DCRegisterChatMediaURL(attachmentURL, messageChannelID, newMessage.snowflake);
                    // YouTube videos and shorts
                    if (isYouTube && originalEmbedURL) {
                        NSURL *ytURL = [NSURL URLWithString:originalEmbedURL];
                        NSString *finalURLString = originalEmbedURL;
                        NSArray *pathComponents = ytURL.pathComponents;
                        NSUInteger shortsIdx = [pathComponents indexOfObject:@"shorts"];
                        if (shortsIdx != NSNotFound && shortsIdx + 1 < pathComponents.count) {
                            NSString *videoID = pathComponents[shortsIdx + 1];
                            finalURLString = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", videoID];
                        }
                        video.linkURL = [NSURL URLWithString:finalURLString];
                    }

                    // baseURL resolution
                    // Resolve the best available thumbnail URL in priority order:
                    // 1. thumbnail.proxy_url (Discord CDN proxy — most reliable)
                    // 2. thumbnail.url (original source thumbnail)
                    // 3. video.proxy_url (Discord's external image proxy for third party sites)
                    // Falls back to the embed URL itself if none are available.
                    NSString *baseURL = [embed objectForKey:@"url"];

                    if ([embed valueForKeyPath:@"thumbnail.proxy_url"] != nil &&
                        [[embed valueForKeyPath:@"thumbnail.proxy_url"] isKindOfClass:[NSString class]]) {
                        baseURL = [embed valueForKeyPath:@"thumbnail.proxy_url"];
                    } else if ([embed valueForKeyPath:@"thumbnail.url"] != nil &&
                               [[embed valueForKeyPath:@"thumbnail.url"] isKindOfClass:[NSString class]]) {
                        baseURL = [embed valueForKeyPath:@"thumbnail.url"];
                    } else if ([embed valueForKeyPath:@"video.proxy_url"] != nil &&
                               [[embed valueForKeyPath:@"video.proxy_url"] isKindOfClass:[NSString class]]) {
                        baseURL = [embed valueForKeyPath:@"video.proxy_url"];
                    }

                    NSInteger width =
                        [[embed valueForKeyPath:@"video.width"] integerValue];
                    NSInteger height =
                        [[embed valueForKeyPath:@"video.height"] integerValue];
                    if (width <= 0 || height <= 0) {
                        width = [[embed valueForKeyPath:@"thumbnail.width"] integerValue];
                        height = [[embed valueForKeyPath:@"thumbnail.height"] integerValue];
                    }
                    if (width <= 0 || height <= 0) {
                        width = 16;
                        height = 9;
                    }
                    CGFloat aspectRatio = (width > 0 && height > 0)
                        ? (CGFloat)width / (CGFloat)height : 1.0f;

                    if (height > 1024) {
                        height = 1024;
                        width  = height * aspectRatio;
                        if (width > 1024) {
                            width  = 1024;
                            height = width / aspectRatio;
                        }
                    } else if (width > 1024) {
                        width  = 1024;
                        height = width / aspectRatio;
                        if (height > 1024) {
                            height = 1024;
                            width  = height * aspectRatio;
                        }
                    }

                    video.naturalSize = CGSizeMake(width, height);

                    // Keep the source thumbnail URL in the model; the media manager owns request rewriting.
                    NSURL *urlString = [baseURL isKindOfClass:[NSString class]]
                        ? [NSURL URLWithString:baseURL]
                        : nil;

                    // Publish lightweight video metadata immediately so layout has stable geometry.
                    video.thumbnailURL = DCRegisterChatMediaURL(urlString, messageChannelID, newMessage.snowflake);
                    [newMessage.attachments addObject:video];

                    // Decode video thumbnails only while the attachment is visible.
                    video.userInteractionEnabled = YES;
                    newMessage.attachmentCount++;
                } else {
                    continue;
                }
            }
        }

        // ─── DIRECT ATTACHMENTS ───────────────────────────────────────────────────────
        // Files directly uploaded by users — images, videos, audio etc.
        // Unlike embeds these come from Discord's CDN directly; content_type may be absent.
        NSArray *attachments = [jsonMessage objectForKey:@"attachments"];
        if (attachments) {
            for (NSDictionary *attachment in attachments) {
                id contentTypeValue = [attachment objectForKey:@"content_type"];
                NSString *fileType = [contentTypeValue isKindOfClass:[NSString class]]
                    ? [(NSString *)contentTypeValue lowercaseString]
                    : nil;
                // Image Attachments
                // Image attachments — includes PNG, JPG, WebP, and GIF.
                // WebP files need format=png appended so iOS can decode them.
                // GIF files are routed to DCGifInfo for tap-to-play behavior.
                if ([fileType hasPrefix:@"image/"]) {
                    newMessage.attachmentCount++;

                    NSString *originalURL = [[attachment objectForKey:@"url"] isKindOfClass:[NSString class]]
                        ? [attachment objectForKey:@"url"] : nil;
                    NSString *proxyURL = [[attachment objectForKey:@"proxy_url"] isKindOfClass:[NSString class]]
                        ? [attachment objectForKey:@"proxy_url"] : nil;
                    NSString *attachmentURL = proxyURL.length ? proxyURL : originalURL;
                    if (attachmentURL.length == 0) continue;
                    NSURL *attachmentNSURL = [NSURL URLWithString:attachmentURL];
                    NSString *pathExtension = [attachmentNSURL.path.lowercaseString pathExtension];
                    BOOL isGif = [fileType isEqualToString:@"image/gif"] || 
                                 [pathExtension isEqualToString:@"gif"];

                    NSInteger width     = [[attachment objectForKey:@"width"] integerValue];
                    NSInteger height    = [[attachment objectForKey:@"height"] integerValue];
                    CGFloat aspectRatio = (width > 0 && height > 0)
                        ? (CGFloat)width / (CGFloat)height : 1.0f;

                    if (height > 1024) {
                        height = 1024;
                        width  = height * aspectRatio;
                        if (width > 1024) {
                            width  = 1024;
                            height = width / aspectRatio;
                        }
                    } else if (width > 1024) {
                        width  = 1024;
                        height = width / aspectRatio;
                        if (height > 1024) {
                            height = 1024;
                            width  = height * aspectRatio;
                        }
                    }

                    // Attachment URL Construction
                    // Weed out webp images and request a png that iOS can present
                    // Build download URL — same logic as image embeds.
                    // proxy_url already has dimensions baked in for some attachments, avoid doubling them.
                    // Always request format=png to handle WebP content that iOS can't decode natively.
                    BOOL alreadyHasDimensions = [attachmentURL rangeOfString:@"width="].location != NSNotFound;
                    NSURL *urlString;
                    if (alreadyHasDimensions) {
                        NSString *trimmedURL = [attachmentURL stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@"&?"]];
                        urlString = [NSURL URLWithString:[NSString
                            stringWithFormat:@"%@%cformat=png", trimmedURL,
                            [trimmedURL rangeOfString:@"?"].location == NSNotFound ? '?' : '&']];
                    } else {
                        NSString *trimmedURL = [attachmentURL stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@"&?"]];
                        urlString = [NSURL URLWithString:[NSString
                            stringWithFormat:@"%@%cformat=png&width=%ld&height=%ld", trimmedURL,
                            [trimmedURL rangeOfString:@"?"].location == NSNotFound ? '?' : '&',
                            (long)width, (long)height]];
                    }

                    // Direct uploads follow the same metadata-only lifecycle as image embeds.
                    if (isGif) {
                        DCGifInfo *gif = [DCGifInfo new];
                        gif.gifURL = DCRegisterChatMediaURL([NSURL URLWithString:attachmentURL], messageChannelID, newMessage.snowflake);
                        gif.thumbnailURL = DCRegisterChatMediaURL(urlString, messageChannelID, newMessage.snowflake);
                        gif.naturalSize = CGSizeMake(width, height);
                        [newMessage.attachments addObject:gif];
                    } else {
                        UILazyImage *lazyImage = [UILazyImage new];
                        lazyImage.imageURL = DCRegisterChatMediaURL(attachmentNSURL, messageChannelID, newMessage.snowflake);
                        lazyImage.naturalSize = CGSizeMake(width, height);
                        [newMessage.attachments addObject:lazyImage];
                    }

                // Video Attachments
                // Directly uploaded video files — only formats natively supported by iOS MPMoviePlayer.
                // Other video formats (webm, avi etc.) fall through to the unknown handler below
                // which appends the raw URL to the message content as a fallback.
                } else if ([fileType isEqualToString:@"video/quicktime"] ||
                           [fileType isEqualToString:@"video/mp4"] ||
                           [fileType isEqualToString:@"video/mpv"] ||
                           [fileType isEqualToString:@"video/3gpp"]) {
                    // iOS only supports these video formats
                    newMessage.attachmentCount++;

                    NSURL *attachmentURL =
                        [NSURL URLWithString:[attachment objectForKey:@"url"]];

                    // Publish video metadata synchronously so layout cannot observe an empty attachment model.
                    CFAbsoluteTime videoViewStart = CFAbsoluteTimeGetCurrent();
                    DCChatVideoAttachment *video = [[DCChatVideoAttachment alloc]
                        initMetadataOnly];
                    NSTimeInterval videoViewTime = CFAbsoluteTimeGetCurrent() - videoViewStart;
                    if (videoViewTime >= 0.008) {
                        NSLog(@"[MediaPerf] video metadata build %.1fms", videoViewTime * 1000.0);
                    }

                    video.videoURL = DCRegisterChatMediaURL(attachmentURL, messageChannelID, newMessage.snowflake);

                    NSString *baseURL = [attachment objectForKey:@"proxy_url"];
                    if (![baseURL isKindOfClass:[NSString class]] || baseURL.length == 0) {
                        baseURL = [attachment objectForKey:@"url"];
                    }
                    NSInteger width = [[attachment objectForKey:@"width"] integerValue];
                    NSInteger height = [[attachment objectForKey:@"height"] integerValue];
                    if (width <= 0 || height <= 0) {
                        width = 16;
                        height = 9;
                    }
                    CGFloat aspectRatio = (CGFloat)width / (CGFloat)height;

                    if (height > 1024) {
                        height = 1024;
                        width = height * aspectRatio;
                        if (width > 1024) {
                            width = 1024;
                            height = width / aspectRatio;
                        }
                    } else if (width > 1024) {
                        width = 1024;
                        height = width / aspectRatio;
                        if (height > 1024) {
                            height = 1024;
                            width = height * aspectRatio;
                        }
                    }

                    video.naturalSize = CGSizeMake(width, height);

                    /* The media manager appends safe format/size parameters at
                     * display time.  Keeping this URL clean also fixes the old
                     * missing-? construction for direct video proxy thumbnails. */
                    video.thumbnailURL = [baseURL isKindOfClass:[NSString class]]
                        ? DCRegisterChatMediaURL([NSURL URLWithString:baseURL], messageChannelID, newMessage.snowflake)
                        : nil;

                    [newMessage.attachments addObject:video];

                    // Thumbnail pixels are resident only while the attachment is visible.
                    video.userInteractionEnabled = YES;
                } else {
                    NSString *rawAttachmentURL = [[attachment objectForKey:@"url"]
                        isKindOfClass:[NSString class]] ? [attachment objectForKey:@"url"] : nil;
                    NSURL *registeredAttachmentURL = rawAttachmentURL.length
                        ? DCRegisterChatMediaURL([NSURL URLWithString:rawAttachmentURL],
                                                 messageChannelID,
                                                 newMessage.snowflake)
                        : nil;
                    if (registeredAttachmentURL) {
                        NSString *filename = [[attachment objectForKey:@"filename"]
                            isKindOfClass:[NSString class]] ? [attachment objectForKey:@"filename"] : nil;
                        if (filename.length == 0) {
                            filename = registeredAttachmentURL.lastPathComponent.length
                                ? registeredAttachmentURL.lastPathComponent
                                : @"Attachment";
                        }

                        // Keep the display label safe for the lightweight Markdown link parser.
                        filename = [filename stringByReplacingOccurrencesOfString:@"]" withString:@"］"];
                        filename = [filename stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
                        filename = [filename stringByReplacingOccurrencesOfString:@"\n" withString:@" "];

                        NSString *fileTag = [NSString stringWithFormat:@"[📄 %@](%@)",
                            filename, registeredAttachmentURL.absoluteString];
                        newMessage.content = newMessage.content.length
                            ? [newMessage.content stringByAppendingFormat:@"\n%@", fileTag]
                            : fileTag;
                    }
                    continue;
                }
            }
        }
        // sticker_items is a flat array — each entry has "id", "name", "format_type"
        // format_type: 1=PNG, 2=APNG, 3=Lottie JSON, 4=GIF
        NSArray *stickerItems = [jsonMessage objectForKey:@"sticker_items"];
        if (stickerItems && [stickerItems isKindOfClass:[NSArray class]] && stickerItems.count > 0) {
            for (NSDictionary *sticker in stickerItems) {
                if (![sticker isKindOfClass:[NSDictionary class]]) continue;

                NSString *stickerId   = [sticker objectForKey:@"id"];
                NSString *stickerName = [sticker objectForKey:@"name"];
                int formatType        = [[sticker objectForKey:@"format_type"] intValue];

                if (!stickerId || [stickerId isKindOfClass:[NSNull class]]) continue;

                // Format 3 = Lottie JSON — no renderer on iOS 5/6.
                if (formatType == 3) {
                    NSString *fallback = [NSString stringWithFormat:@"[sticker: %@]",
                                          ([stickerName isKindOfClass:[NSString class]] ? stickerName : @"unknown")];
                    newMessage.content = newMessage.content.length > 0
                        ? [newMessage.content stringByAppendingFormat:@" %@", fallback]
                        : fallback;
                    continue;
                }

                // Format 1 = PNG, Format 2 = APNG (media.discordapp.net transcodes to GIF),
                // Format 4 = GIF.
                NSString *extension = (formatType == 1) ? @"png" : @"gif";

                NSURL *stickerURL = [NSURL URLWithString:[NSString stringWithFormat:
                    @"https://media.discordapp.net/stickers/%@.%@?size=320",
                    stickerId, extension]];

                newMessage.isSticker = YES;
                newMessage.attachmentCount++;

                // Stickers use the lazy thumbnail path while retaining fixed layout geometry.
                UILazyImage *lazyImage = [UILazyImage new];
                lazyImage.imageURL = stickerURL;
                lazyImage.naturalSize = CGSizeMake(160, 160);
                [newMessage.attachments addObject:lazyImage];
            }
        }

        perfMediaEnd = CFAbsoluteTimeGetCurrent();

        // Parse in-text mentions into readable @<username>
        NSArray *mentions     = [jsonMessage objectForKey:@"mentions"];
        NSArray *mentionRoles = [jsonMessage objectForKey:@"mention_roles"];

        if ([[jsonMessage objectForKey:@"mention_everyone"] boolValue]) {
            newMessage.pingingUser = true;
        }

        if (mentions.count || mentionRoles.count) {
            for (NSDictionary *mention in mentions) {
                if ([[mention objectForKey:@"id"] isEqualToString:
                                                      DCServerCommunicator.sharedInstance.snowflake]) {
                    newMessage.pingingUser = true;
                }
                if (![DCServerCommunicator.sharedInstance userForSnowflake:[mention objectForKey:@"id"]]) {
                    (void)[DCTools convertJsonUser:mention cache:true];
                }
            }
            // role ping check
            for (NSString *roleSnowflake in mentionRoles) {
                if ([contextChannel.parentGuild.userRoles containsObject:roleSnowflake]) {
                    newMessage.pingingUser = true;
                }
            }
        }

        perfMentionsEnd = CFAbsoluteTimeGetCurrent();

        NSString *content = [newMessage.content emojizedString];
        perfEmojizeEnd = CFAbsoluteTimeGetCurrent();

        content = [content stringByReplacingOccurrencesOfString:@"\u2122\uFE0F"
                                                     withString:@"™"];
        content = [content stringByReplacingOccurrencesOfString:@"\u00AE\uFE0F"
                                                     withString:@"®"];

        newMessage.content = content;

        // Calculate height of content to be used when showing messages in a
        // tableview contentHeight does NOT include height of the embeded images or
        // account for height of a grouped message

        CGSize authorNameSize = [[newMessage.author 
            displayNameInGuild:contextChannel.parentGuild]
                 sizeWithFont:[UIFont boldSystemFontOfSize:15]
            constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                lineBreakMode:(NSLineBreakMode)UILineBreakModeWordWrap];
        /*
         * Build the attributed string first, but do not lay it out yet.  The old
         * path measured plain UIKit text, laid the DTCoreText string out once,
         * optionally appended the edited marker, then laid it out a second time.
         * The first two measurements can never affect the final value.
         */
        CGSize contentSize = CGSizeMake(contentWidth, 0.0f);
        newMessage.attributedContent = nil;
        if ([newMessage.content length] > 0) {
            NSAttributedString *attributedText = [[DCMarkdownParser sharedParser]
                attributedStringFromMarkdown:newMessage.content];
            if (attributedText) {
                newMessage.attributedContent = attributedText;
                newMessage.content = attributedText.string;
            }
        }

        // Pretty "(edited)" tag — CoreText attributes for iOS 5 compatibility
        if (newMessage.editedTimestamp != nil) {
            if (!newMessage.attributedContent) {
                newMessage.attributedContent = [[NSAttributedString alloc]
                    initWithString:newMessage.content
                        attributes:@{
                            (NSString *)kCTFontAttributeName: CFBridgingRelease(
                                CTFontCreateWithName((__bridge CFStringRef)[UIFont systemFontOfSize:14].fontName, 14, NULL))
                        }];
            }
            NSMutableAttributedString *mutable = [newMessage.attributedContent mutableCopy];
            NSMutableDictionary *editedAttrs = [@{
                (NSString *)kCTFontAttributeName: CFBridgingRelease(
                    CTFontCreateWithName((__bridge CFStringRef)[UIFont systemFontOfSize:10].fontName, 10, NULL)),
                (NSString *)kCTForegroundColorAttributeName: (__bridge id)[UIColor colorWithRed:128/255.0f
                                                                                          green:128/255.0f
                                                                                           blue:128/255.0f
                                                                                          alpha:1.0f].CGColor,
                DTShadowsAttribute: @[ @{
                    @"Offset": [NSValue valueWithCGSize:CGSizeMake(0, 1)],
                    @"Blur":   @(0.0f),
                    @"Color":  [UIColor blackColor]
                }]
            } mutableCopy];
            [mutable appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" (edited)"
                    attributes:editedAttrs]];
            newMessage.attributedContent = mutable;
        }

        /*
         * Resolve newer supplementary emoji before any DTCoreText measurement.
         * This is intentionally render-only: newMessage.content/rawContent stay
         * unchanged even when an unsupported cluster needs a placeholder.
         */
        DCApplyLegacyUnicodeCompatibility(newMessage);

        perfMarkdownEnd = CFAbsoluteTimeGetCurrent();

        // REST/history callers may defer measurement so layout runs once at the actual table width.
        if (deferLegacyLayout) {
            measurementMode = @"deferred";
            newMessage.textHeight = 0.0f;
        } else {
            if (newMessage.attributedContent) {
                measurementMode = @"dtcoretext";
                DTCoreTextLayouter *layouter = [[DTCoreTextLayouter alloc]
                    initWithAttributedString:newMessage.attributedContent];
                CGRect layoutRect = CGRectMake(0, 0, contentWidth, CGFLOAT_HEIGHT_UNKNOWN);
                DTCoreTextLayoutFrame *layoutFrame = [layouter layoutFrameWithRect:layoutRect
                                                                             range:NSMakeRange(0, 0)];
                contentSize.height = ceil(CGRectGetHeight(layoutFrame.frame));
            } else if ([newMessage.content length] > 0) {
                measurementMode = @"uikit-fallback";
                CGSize measured = [newMessage.content
                     sizeWithFont:[UIFont systemFontOfSize:14]
                constrainedToSize:CGSizeMake(contentWidth, MAXFLOAT)
                    lineBreakMode:(NSLineBreakMode)UILineBreakModeWordWrap];
                contentSize.height = ceil(measured.height);
            }
            newMessage.textHeight = ceil(contentSize.height) + 2;
        }
        perfLayoutEnd = CFAbsoluteTimeGetCurrent();



        // Message types with specialized presentation.
        BOOL cond = (
            newMessage.messageType == 6 
            || (newMessage.messageType != 18 
                && (
                    newMessage.messageType < 1 
                    || newMessage.messageType > 8
                )
            )
        );
        // Calculate minimum cell height — author name + at least one line of text + padding
        NSCharacterSet *invisibleChars = [NSCharacterSet characterSetWithCharactersInString:@"\u00A0\u200B\n\r\t "];
        BOOL hasVisibleContent = [[newMessage.content stringByTrimmingCharactersInSet:invisibleChars] length] > 0
            || newMessage.emojis.count > 0;
        CGFloat minHeight = (cond ? authorNameSize.height : 0) + (hasVisibleContent ? [UIFont systemFontOfSize:14].lineHeight : 0) + 10;
        if (deferLegacyLayout) {
            // DCMessageLayoutBuilder owns the real per-width geometry for this path.
            newMessage.contentHeight = 0;
        } else {
            newMessage.contentHeight = MAX(
                (cond ? authorNameSize.height : 0)
                    + (newMessage.attachmentCount ? (hasVisibleContent ? contentSize.height : 0) : MAX(contentSize.height, 18))
                    + 10
                    + (newMessage.referencedMessage != nil ? 16 : 0),
                minHeight
            );
        }
        newMessage.authorNameWidth = 60 + authorNameSize.width;
        perfTailEnd = CFAbsoluteTimeGetCurrent();
    }

    CFAbsoluteTime perfTotal = perfTailEnd - perfStart;
    NSTimeInterval perfMedia = perfMediaEnd - perfDatesEnd;
    if (perfTotal >= 0.075 || perfMedia >= 0.010 || (deferLegacyLayout && perfTotal >= 0.015)) {
        NSString *perfID = [newMessage.snowflake isKindOfClass:[NSString class]]
            ? newMessage.snowflake : @"?";
        NSString *rawPerfContent = [newMessage.rawContent isKindOfClass:[NSString class]]
            ? newMessage.rawContent : @"";
        NSUInteger nonASCII = 0;
        NSUInteger newlines = 0;
        BOOL hasZWJ = NO;
        BOOL hasVariationSelector = NO;
        for (NSUInteger i = 0; i < rawPerfContent.length; i++) {
            unichar ch = [rawPerfContent characterAtIndex:i];
            if (ch > 0x7F) nonASCII++;
            if (ch == '\n') newlines++;
            if (ch == 0x200D) hasZWJ = YES;
            if (ch == 0xFE0F) hasVariationSelector = YES;
        }
        BOOL hasCustomEmojiSyntax =
            [rawPerfContent rangeOfString:@"<:"].location != NSNotFound ||
            [rawPerfContent rangeOfString:@"<a:"].location != NSNotFound;
        BOOL hasMentionSyntax = [rawPerfContent rangeOfString:@"<@"].location != NSNotFound;

        NSLog(@"[MessagePerf] convert %@ total %.1fms identity %.1f dates %.1f media %.1f mentions %.1f emojize %.1f markdown %.1f layout %.1f tail %.1f measure %@ shape len %lu nonascii %lu nl %lu customEmoji %d mention %d zwj %d vs16 %d",
              perfID,
              perfTotal * 1000.0,
              (perfIdentityEnd - perfStart) * 1000.0,
              (perfDatesEnd - perfIdentityEnd) * 1000.0,
              (perfMediaEnd - perfDatesEnd) * 1000.0,
              (perfMentionsEnd - perfMediaEnd) * 1000.0,
              (perfEmojizeEnd - perfMentionsEnd) * 1000.0,
              (perfMarkdownEnd - perfEmojizeEnd) * 1000.0,
              (perfLayoutEnd - perfMarkdownEnd) * 1000.0,
              (perfTailEnd - perfLayoutEnd) * 1000.0,
              measurementMode,
              (unsigned long)rawPerfContent.length,
              (unsigned long)nonASCII,
              (unsigned long)newlines,
              hasCustomEmojiSyntax,
              hasMentionSyntax,
              hasZWJ,
              hasVariationSelector);
    }

    return newMessage;
}

+ (DCGuild *)convertJsonGuild:(NSDictionary *)jsonGuild withMembers:(NSArray *)members {
    DCGuild *newGuild = DCGuild.new;

    newGuild.snowflake = [jsonGuild objectForKey:@"id"];
    newGuild.name = [jsonGuild objectForKey:@"name"];
    id ownerID = [jsonGuild objectForKey:@"owner_id"];
    if ([ownerID isKindOfClass:[NSString class]]) newGuild.ownerID = ownerID;

    id memberCount = [jsonGuild objectForKey:@"member_count"];
    if ([memberCount respondsToSelector:@selector(integerValue)])
        newGuild.memberCount = [memberCount integerValue];

    newGuild.userRoles = NSMutableArray.new;
    newGuild.roles = NSMutableDictionary.new;
    newGuild.members = NSMutableArray.new;
    newGuild.emojis = NSMutableDictionary.new;

    // Get emojis
    for (NSDictionary *emoji in [jsonGuild objectForKey:@"emojis"]) {
        [newGuild.emojis setObject:[DCTools convertJsonEmoji:emoji cache:true]
                            forKey:[emoji objectForKey:@"id"]];
    }

    // Get @everyone role
    for (NSDictionary *guildRole in [jsonGuild objectForKey:@"roles"]) {
        if ([[guildRole objectForKey:@"name"] isEqualToString:@"@everyone"]) {
            [newGuild.userRoles addObject:[guildRole objectForKey:@"id"]];
        }
        [newGuild.roles
            setObject:[DCTools convertJsonRole:guildRole cache:true]
               forKey:[guildRole objectForKey:@"id"]];
    }

    // Get roles of the current user
    if (members && members.count > 0 && [members[0] objectForKey:@"user_id"]) {
        // READY merged_members
        for (NSDictionary *member in members) {
            if ([[member objectForKey:@"user_id"] isEqualToString:DCServerCommunicator.sharedInstance.snowflake]) {
                [newGuild.userRoles addObjectsFromArray:[member objectForKey:@"roles"]];
            }
            DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:[member objectForKey:@"user_id"]];
            if (user && newGuild.snowflake && (NSNull *)newGuild.snowflake != [NSNull null]) {
                [DCServerCommunicator.sharedInstance
                    applyGuildProfileFromMember:member
                                          toUser:user
                                         guildID:newGuild.snowflake
                                   authoritative:YES];
            }
        }
    } else {
        // GUILD_CREATE
        for (NSDictionary *member in [jsonGuild objectForKey:@"members"]) {
            DCUser *user = [DCTools convertJsonUser:[member objectForKey:@"user"] cache:true];
            [DCServerCommunicator.sharedInstance setUser:user
                                            forSnowflake:[member valueForKeyPath:@"user.id"]];
            if ([[member valueForKeyPath:@"user.id"] isEqualToString:DCServerCommunicator.sharedInstance.snowflake]) {
                [newGuild.userRoles addObjectsFromArray:[member objectForKey:@"roles"]];
            }
            if (user && newGuild.snowflake) {
                [DCServerCommunicator.sharedInstance
                    applyGuildProfileFromMember:member
                                          toUser:user
                                         guildID:newGuild.snowflake
                                   authoritative:YES];
            }
        }
    }

    // add new types here.
    newGuild.channels  = NSMutableArray.new;

    NSNumber *longId = @([newGuild.snowflake longLongValue]);

    int selector = (int)(([longId longLongValue] >> 22) % 6);

    newGuild.icon = [DCUser defaultAvatars][selector];
    /*CGSize itemSize = CGSizeMake(40, 40);
     UIGraphicsBeginImageContextWithOptions(itemSize, NO,
     UIScreen.mainScreen.scale); CGRect imageRect = CGRectMake(0.0, 0.0,
     itemSize.width, itemSize.height); [newGuild.icon  drawInRect:imageRect];
     newGuild.icon = UIGraphicsGetImageFromCurrentImageContext();
     UIGraphicsEndImageContext();*/

    SDWebImageManager *manager = [SDWebImageManager sharedManager];

    id guildIconHash = [jsonGuild objectForKey:@"icon"];
    if ([guildIconHash isKindOfClass:[NSString class]]) {
        newGuild.iconID = guildIconHash;
        NSURL *iconURL = [NSURL URLWithString:[NSString
                                                  stringWithFormat:@"https://cdn.discordapp.com/icons/%@/%@.png?size=80",
                                                                   newGuild.snowflake, guildIconHash]];
        newGuild.iconURL = [iconURL absoluteString];
        [manager downloadImageWithURL:iconURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *icon, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                @autoreleasepool {
                                    if (!icon || !finished) {
                                        NSLog(@"Failed to load guild icon with URL %@: %@", iconURL, error);
                                        return;
                                    }
                                    dispatch_async(dispatch_get_global_queue(
                                        DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                        CGSize itemSize = CGSizeMake(40.0f, 40.0f);
                                        UIGraphicsBeginImageContextWithOptions(
                                            itemSize, NO, UIScreen.mainScreen.scale
                                        );
                                        CGRect imageRect = CGRectMake(
                                            0.0f, 0.0f, itemSize.width,
                                            itemSize.height
                                        );
                                        [icon drawInRect:imageRect];
                                        UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
                                        UIGraphicsEndImageContext();
                                        UIImage *source = resized ?: icon;
                                        [DCContentManager processedGuildIcon:source];

                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            // The source-associated composite is already warm,
                                            // so the DCGuild setter performs no bitmap work here.
                                            newGuild.icon = source;
                                            [NSNotificationCenter.defaultCenter
                                                postNotificationName:@"RELOAD GUILD"
                                                              object:newGuild];
                                        });
                                    });
                                }
                            }];
    }

    id guildBannerHash = [jsonGuild objectForKey:@"banner"];
    if ([guildBannerHash isKindOfClass:[NSString class]]) {
        newGuild.bannerID = guildBannerHash;
        NSURL *bannerURL = [NSURL URLWithString:[NSString
                                                    stringWithFormat:@"https://cdn.discordapp.com/banners/%@/%@.png?size=320",
                                                                     newGuild.snowflake, guildBannerHash]];
        [manager downloadImageWithURL:bannerURL
                              options:SDWebImageRetryFailed
                             progress:nil
                            completed:^(UIImage *banner, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
                                @autoreleasepool {
                                    if (!banner || !finished) {
                                        NSLog(@"Failed to load guild banner with URL %@: %@", bannerURL, error);
                                        return;
                                    }
                                    newGuild.banner = banner;
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        UIGraphicsEndImageContext();
                                    });
                                }
                            }];
    }

    NSMutableArray *categories = NSMutableArray.new;

    id rawGuildChannels = [jsonGuild objectForKey:@"channels"];
    id rawGuildThreads  = [jsonGuild objectForKey:@"threads"];
    NSArray *guildChannels = [rawGuildChannels isKindOfClass:[NSArray class]]
        ? rawGuildChannels : [NSArray array];
    NSArray *guildThreads = [rawGuildThreads isKindOfClass:[NSArray class]]
        ? rawGuildThreads : [NSArray array];
    NSArray *combined = [guildChannels arrayByAddingObjectsFromArray:guildThreads];
    NSMutableDictionary *channels = NSMutableDictionary.new;
    for (NSDictionary *jsonChannel in combined) {
        // regardless of implementation or permissions, add to channels list so they're visible in <#snowflake>
        DCChannel *newChannel = DCChannel.new;

        newChannel.snowflake = [jsonChannel objectForKey:@"id"];
        id parentID = [jsonChannel objectForKey:@"parent_id"];
        newChannel.parentID  = [parentID isKindOfClass:[NSString class]] ? parentID : nil;
        newChannel.name      = [jsonChannel objectForKey:@"name"];
        newChannel.lastMessageId =
            [jsonChannel objectForKey:@"last_message_id"];
        newChannel.parentGuild = newGuild;
        newChannel.type        = [[jsonChannel objectForKey:@"type"] intValue];
        NSString *rawPosition  = [jsonChannel objectForKey:@"position"];
        newChannel.position    = rawPosition ? [rawPosition intValue] : 0;
        newChannel.readable    = true;
        newChannel.writeable   = true;

        // check if channel is muted
        if ([DCServerCommunicator.sharedInstance.userChannelSettings
                objectForKey:newChannel.snowflake]) {
            newChannel.muted = true;
        }

        // Make sure jsonChannel is a text channel or a category
        // Exclude voice channels from the text-channel list.
        if ([[jsonChannel objectForKey:@"type"] isEqual:@(DCChannelTypeGuildText)] ||         // text channel
            [[jsonChannel objectForKey:@"type"] isEqual:@(DCChannelTypeGuildAnnouncement)] || // announcements
            [[jsonChannel objectForKey:@"type"] isEqual:@(DCChannelTypeGuildCategory)]) {     // category
            // Allow code is used to determine if the user should see the
            // channel in question.
            /*
             0 - No overrides. Channel should be created

             1 - Hidden by role. Channel should not be created unless another
             role contradicts (code 2)

             2 - Shown by role. Channel should be created unless hidden by
             member overwrite (code 3)

             3 - Hidden by member. Channel should not be created

             4 - Shown by member. Channel should be created

             3 & 4 are mutually exclusive
             */
            int allowCode = 0;
            BOOL canWrite = true;

            // Calculate permissions
            NSArray *rawOverwrites =
                [jsonChannel objectForKey:@"permission_overwrites"];
            newChannel.permissionOverwrites = [rawOverwrites isKindOfClass:[NSArray class]]
                ? [NSArray arrayWithArray:rawOverwrites] : [NSArray array];
            // sort with role priority
            NSArray *overwrites = [rawOverwrites sortedArrayUsingComparator:
                                                     ^NSComparisonResult(NSDictionary *perm1, NSDictionary *perm2) {
                                                         DCRole *role1 = [newGuild.roles objectForKey:[perm1 objectForKey:@"id"]];
                                                         DCRole *role2 = [newGuild.roles objectForKey:[perm2 objectForKey:@"id"]];
                                                         return role1.position < role2.position ? NSOrderedAscending : NSOrderedDescending;
                                                     }];
            for (NSDictionary *permission in overwrites) {
                uint64_t type     = [[permission objectForKey:@"type"] longLongValue];
                NSString *idValue = [permission objectForKey:@"id"];
                uint64_t deny     = [[permission objectForKey:@"deny"] longLongValue];
                uint64_t allow    = [[permission objectForKey:@"allow"] longLongValue];

                if (type == 0) { // Role overwrite
                    if ([newGuild.userRoles containsObject:idValue]) {
                        if ((deny & DCPermissionSendMessages) == DCPermissionSendMessages) {
                            canWrite = false;
                        }
                        if ((deny & DCPermissionViewChannel) == DCPermissionViewChannel) {
                            allowCode = 1;
                        }
                        if ((allow & DCPermissionSendMessages) == DCPermissionSendMessages) {
                            canWrite = true;
                        }
                        if ((allow & DCPermissionViewChannel) == DCPermissionViewChannel) {
                            allowCode = 2;
                        }
                    }
                } else if (type == 1) { // Member overwrite, break on these
                    if ([idValue isEqualToString:
                                     DCServerCommunicator.sharedInstance.snowflake]) {
                        if ((deny & DCPermissionSendMessages) == DCPermissionSendMessages) {
                            canWrite = false;
                        }
                        if ((deny & DCPermissionViewChannel) == DCPermissionViewChannel) {
                            allowCode = 3;
                        }
                        if ((allow & DCPermissionSendMessages) == DCPermissionSendMessages) {
                            canWrite = true;
                        }
                        if ((allow & DCPermissionViewChannel) == DCPermissionViewChannel) {
                            allowCode = 4;
                        }
                        break;
                    }
                }
            }

            BOOL isOwner = [[jsonGuild objectForKey:@"owner_id"]
                isEqualToString:DCServerCommunicator.sharedInstance.snowflake];
            newChannel.readable = isOwner || (allowCode != 1 && allowCode != 3);
            newChannel.writeable = isOwner || (newChannel.readable && canWrite);
            // ignore perms for guild categories
            if (newChannel.type == DCChannelTypeGuildCategory) { // category
                [categories addObject:newChannel];
            } else if (newChannel.readable) {
                [newGuild.channels addObject:newChannel];
            }
        }
        [channels setObject:newChannel forKey:newChannel.snowflake];
    }

    // refer to https://github.com/Rapptz/discord.py/issues/2392#issuecomment-707455919
    [newGuild.channels sortUsingComparator:^NSComparisonResult(
                           DCChannel *channel1, DCChannel *channel2
    ) {
        if ([channel1.parentID isKindOfClass:[NSString class]] && ![channel2.parentID isKindOfClass:[NSString class]]) {
            return NSOrderedDescending;
        } else if (![channel1.parentID isKindOfClass:[NSString class]] && [channel2.parentID isKindOfClass:[NSString class]]) {
            return NSOrderedAscending;
        } else if ([channel1.parentID isKindOfClass:[NSString class]] && [channel2.parentID isKindOfClass:[NSString class]] && ![channel1.parentID isEqualToString:channel2.parentID]) {
            NSUInteger idx1 = [categories indexOfObjectPassingTest:^BOOL(DCChannel *category, NSUInteger idx, BOOL *stop) {
                return [category.snowflake isEqualToString:channel1.parentID];
            }],
                       idx2 = [categories indexOfObjectPassingTest:^BOOL(DCChannel *category, NSUInteger idx, BOOL *stop) {
                           return [category.snowflake isEqualToString:channel2.parentID];
                       }];
            if (idx1 != NSNotFound && idx2 != NSNotFound) {
                DCChannel *parent1 = [categories objectAtIndex:idx1];
                DCChannel *parent2 = [categories objectAtIndex:idx2];
                if (parent1.position < parent2.position) {
                    return NSOrderedAscending;
                } else if (parent1.position > parent2.position) {
                    return NSOrderedDescending;
                }
            }
        }

#warning TODO: voice channels at the bottom
        if (channel1.position < channel2.position) {
            return NSOrderedAscending;
        } else if (channel1.position > channel2.position) {
            return NSOrderedDescending;
        } else {
            return [channel1.snowflake compare:channel2.snowflake];
        }
    }];

    // Add categories to the guild
    for (DCChannel *category in categories) {
        int i = 0;
        for (DCChannel *channel in newGuild.channels) {
            if (channel.type == DCChannelTypeGuildCategory
                || channel.parentID == nil
                || (NSNull *)channel.parentID == [NSNull null]) {
                // If the channel is a category or has no parent, skip it
                i++;
                continue;
            }
            if ([channel.parentID isEqualToString:category.snowflake]) {
                [newGuild.channels insertObject:category atIndex:i];
                break;
            }
            i++;
        }
    }

    [DCServerCommunicator.sharedInstance.channels addEntriesFromDictionary:channels];

    return newGuild;
}

+ (NSString *)parseMessage:(NSString *)messageString withGuild:(DCGuild *)guild {
    // convert :emoji: to <a:emoji:snowflake> or <emoji:snowflake>
    {
        static dispatch_once_t onceToken;
        static NSRegularExpression *regex;
        dispatch_once(&onceToken, ^{
            regex = [NSRegularExpression
                regularExpressionWithPattern:@":(\\w+):"
                                     options:NSRegularExpressionCaseInsensitive
                                       error:NULL];
        });
        NSTextCheckingResult *embeddedMention = [regex
            firstMatchInString:messageString
                       options:0
                         range:NSMakeRange(0, messageString.length)];

        while (embeddedMention) {
            NSString *emojiName = [messageString substringWithRange:[embeddedMention rangeAtIndex:1]];
            DCEmoji *emoji      = nil;
            if (guild) {
                emoji = [guild.emojis.allValues
                            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCEmoji *obj, NSDictionary *bindings) {
                                return [obj.name isEqualToString:emojiName];
                            }]]
                            .firstObject;
            }
            if (!emoji) {
                __block DCEmoji *foundEmoji = nil;
                dispatch_sync(DCServerCommunicator.sharedInstance.accessQueue, ^{
                    foundEmoji = [DCServerCommunicator.sharedInstance.loadedEmojis.allValues
                        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCEmoji *obj, NSDictionary *bindings) {
                            return [obj.name isEqualToString:emojiName];
                        }]].firstObject;
                });
                emoji = foundEmoji;
            }
            if (emoji) {
                NSString *replacement = [NSString stringWithFormat:@"<%@:%@:%@>",
                                                                   emoji.animated ? @"a" : @"", emojiName, emoji.snowflake];
                messageString         = [messageString stringByReplacingCharactersInRange:embeddedMention.range withString:replacement];
            } else {
                DBGLOG(@"Missing emoji: %@", emojiName);
            }
            embeddedMention = [regex firstMatchInString:messageString
                                                options:0
                                                  range:NSMakeRange(
                                                            embeddedMention.range.location + embeddedMention.range.length,
                                                            messageString.length - (embeddedMention.range.location + embeddedMention.range.length)
                                                        )];
        }
    }

    // convert @username/@role to <@{!,&}snowflake>
    {
        static dispatch_once_t onceToken;
        static NSRegularExpression *regex;
        dispatch_once(&onceToken, ^{
            regex = [NSRegularExpression
                regularExpressionWithPattern:@"@(\\w+)"
                                     options:NSRegularExpressionCaseInsensitive
                                       error:NULL];
        });
        NSTextCheckingResult *embeddedMention = [regex
            firstMatchInString:messageString
                       options:0
                         range:NSMakeRange(0, messageString.length)];

        while (embeddedMention) {
            NSString *mentionName  = [messageString substringWithRange:[embeddedMention rangeAtIndex:1]];
            DCSnowflake *snowflake = nil;
            BOOL isUser            = YES;
            {
                __block id obj = nil;
                dispatch_sync(DCServerCommunicator.sharedInstance.accessQueue, ^{
                    obj = [DCServerCommunicator.sharedInstance.loadedUsers.allValues
                        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCUser *obj, NSDictionary *bindings) {
                            return [obj.username isEqualToString:mentionName] || [obj.globalName isEqualToString:mentionName];
                        }]].firstObject;
                });
                if (!obj && guild) {
                    isUser = NO;
                    obj    = [guild.roles.allValues
                              filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCRole *obj, NSDictionary *bindings) {
                                  return [obj.name isEqualToString:mentionName];
                              }]]
                              .firstObject;
                }
                if (obj) {
                    if (isUser) {
                        snowflake = ((DCUser *)obj).snowflake;
                    } else {
                        snowflake = ((DCRole *)obj).snowflake;
                    }
                }
            }
            if (snowflake) {
                NSString *replacement = [NSString stringWithFormat:@"<@%c%@>", isUser ? '!' : '&', snowflake];
                messageString         = [messageString stringByReplacingCharactersInRange:embeddedMention.range
                                                                       withString:replacement];
            } else {
                DBGLOG(@"Missing mention: %@", mentionName);
            }
            embeddedMention = [regex firstMatchInString:messageString
                                                options:0
                                                  range:NSMakeRange(
                                                            embeddedMention.range.location + embeddedMention.range.length,
                                                            messageString.length - (embeddedMention.range.location + embeddedMention.range.length)
                                                        )];
        }
    }

    // convert #channel to <#snowflake>
    if (guild) {
        static dispatch_once_t onceToken;
        static NSRegularExpression *regex;
        dispatch_once(&onceToken, ^{
            regex = [NSRegularExpression
                regularExpressionWithPattern:@"#(\\w+)"
                                     options:NSRegularExpressionCaseInsensitive
                                       error:NULL];
        });
        NSTextCheckingResult *embeddedMention = [regex
            firstMatchInString:messageString
                       options:0
                         range:NSMakeRange(0, messageString.length)];

        while (embeddedMention) {
            NSString *channelName = [messageString substringWithRange:[embeddedMention rangeAtIndex:1]];
            DCChannel *channel    = [guild.channels
                                     filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DCChannel *obj, NSDictionary *bindings) {
                                         return [obj.name isEqualToString:channelName];
                                     }]]
                                     .firstObject;
            if (channel) {
                NSString *replacement = [NSString stringWithFormat:@"<#%@>", channel.snowflake];
                messageString         = [messageString stringByReplacingCharactersInRange:embeddedMention.range withString:replacement];
            } else {
                DBGLOG(@"Missing channel: %@", channelName);
            }
            embeddedMention = [regex firstMatchInString:messageString
                                                options:0
                                                  range:NSMakeRange(
                                                            embeddedMention.range.location + embeddedMention.range.length,
                                                            messageString.length - (embeddedMention.range.location + embeddedMention.range.length)
                                                        )];
        }
    }
    return messageString;
}


+ (void)joinGuild:(NSString *)inviteCode {
    NSMutableURLRequest *urlRequest = [DCServerCommunicator
                                       requestWithPath:[NSString stringWithFormat:@"/invite/%@", inviteCode]
                                       token:DCServerCommunicator.sharedInstance.token];
    urlRequest.HTTPMethod = @"POST";
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    });
    [NSURLConnection
     sendAsynchronousRequest:urlRequest
     queue:[NSOperationQueue currentQueue]
     completionHandler:^(NSURLResponse *response, NSData *data, NSError *connError) {
         dispatch_sync(dispatch_get_main_queue(), ^{
             [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
         });
     }];
}


+ (void)checkForAppUpdate {
    // this is just via the "XML Update Server"
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^{
            NSURL *randomEndpoint = [NSURL
                URLWithString:[NSString
                                  stringWithFormat:
                                      @"http://5.230.249.85:8814/update?v=%@",
                                      appVersion]];
            NSURLResponse *response;
            NSError *error;

            NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
            request.URL                  = randomEndpoint;
            request.HTTPMethod           = @"GET";
            [request setValue:@"application/json"
                forHTTPHeaderField:@"Content-Type"];
            request.timeoutInterval = 10;

            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&error];

            if (data) {
                NSDictionary *response =
                    [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:&error];
                NSNumber *update  = response[@"outdated"];
                NSString *message = response[@"message"];

                if ([update intValue] == 1) {
                    [self alert:@"Update Available" withMessage:message];
                } else {
                    return;
                }
            } else {
                return;
            }
        }
    );
    return;
}

@end
