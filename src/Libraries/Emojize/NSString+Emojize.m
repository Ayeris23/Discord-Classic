//
//  NSString+Emojize.m
//  Field Recorder
//
//  Created by Jonathan Beilin on 11/5/12.
//  Copyright (c) 2014 DIY. All rights reserved.
//

#import "NSString+Emojize.h"

static NSRegularExpression *DCEmojizeShortcodeRegex(void) {
    static dispatch_once_t onceToken;
    static NSRegularExpression *regex = nil;
    dispatch_once(&onceToken, ^{
        regex = [[NSRegularExpression alloc]
            initWithPattern:@"(:[a-z0-9-+_]+:)"
                    options:NSRegularExpressionCaseInsensitive
                      error:NULL];
    });
    return regex;
}

static NSDictionary *DCEmojizeLookup(void) {
    static dispatch_once_t onceToken;
    static NSDictionary *lookup = nil;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *flat = [NSMutableDictionary dictionary];
        NSDictionary *aliases = [NSString emojiAliases];
        for (NSString *type in aliases) {
            NSArray *objects = [aliases objectForKey:type];
            if (![objects isKindOfClass:[NSArray class]]) continue;
            for (NSDictionary *emojiObject in objects) {
                if (![emojiObject isKindOfClass:[NSDictionary class]]) continue;
                NSString *unicode = [emojiObject objectForKey:@"surrogates"];
                NSArray *names = [emojiObject objectForKey:@"names"];
                if (![unicode isKindOfClass:[NSString class]] ||
                    ![names isKindOfClass:[NSArray class]]) continue;
                for (NSString *name in names) {
                    if (![name isKindOfClass:[NSString class]]) continue;
                    NSString *key = [NSString stringWithFormat:@":%@:", name];
                    if (![flat objectForKey:key]) [flat setObject:unicode forKey:key];
                }
            }
        }
        lookup = [flat copy];
    });
    return lookup;
}

@implementation NSString (Emojize)

- (NSString *)emojizedString {
    return [NSString emojizedStringWithString:self];
}

+ (NSString *)emojizedStringWithString:(NSString *)text {
    if (!text.length) return text;

    // Avoid even entering the regex engine for the overwhelmingly common case.
    NSRange firstColon = [text rangeOfString:@":"];
    if (firstColon.location == NSNotFound || firstColon.location + 1 >= text.length) {
        return text;
    }
    NSRange secondColon = [text rangeOfString:@":"
                                      options:0
                                        range:NSMakeRange(firstColon.location + 1,
                                                          text.length - firstColon.location - 1)];
    if (secondColon.location == NSNotFound) return text;

    NSRegularExpression *regex = DCEmojizeShortcodeRegex();

    NSArray *matches = [regex matchesInString:text
                                      options:0
                                        range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return text;

    // Discord custom-emoji tokens are handled by DCMarkdownParser, not the legacy alias table.
    NSMutableArray *legacyMatches = [NSMutableArray arrayWithCapacity:matches.count];
    for (NSTextCheckingResult *match in matches) {
        NSUInteger start = match.range.location;
        NSUInteger end = NSMaxRange(match.range);
        BOOL customPrefix = NO;
        if (start >= 1 && [text characterAtIndex:start - 1] == '<') {
            customPrefix = YES; // <:name:id>
        } else if (start >= 2 &&
                   [text characterAtIndex:start - 2] == '<' &&
                   [text characterAtIndex:start - 1] == 'a') {
            customPrefix = YES; // <a:name:id>
        }

        BOOL customSuffix = NO;
        if (customPrefix && end < text.length) {
            NSUInteger cursor = end;
            BOOL sawDigit = NO;
            while (cursor < text.length) {
                unichar ch = [text characterAtIndex:cursor];
                if (ch >= '0' && ch <= '9') {
                    sawDigit = YES;
                    cursor++;
                    continue;
                }
                if (ch == '>' && sawDigit) customSuffix = YES;
                break;
            }
        }

        if (!(customPrefix && customSuffix)) {
            [legacyMatches addObject:match];
        }
    }
    if (legacyMatches.count == 0) return text;

    // Flatten aliases once so shortcode replacement is O(1).
    NSDictionary *lookup = DCEmojizeLookup();

    NSMutableString *result = [text mutableCopy];
    for (NSTextCheckingResult *match in [legacyMatches reverseObjectEnumerator]) {
        if (match.range.location == NSNotFound || NSMaxRange(match.range) > text.length) continue;
        NSString *code = [text substringWithRange:match.range];
        NSString *unicode = [lookup objectForKey:code];
        if (unicode && NSMaxRange(match.range) <= result.length) {
            [result replaceCharactersInRange:match.range withString:unicode];
        }
    }
    return result;
}

+ (void)prewarmEmojizeLookup {
    (void)DCEmojizeShortcodeRegex();
    (void)DCEmojizeLookup();
}

+ (NSDictionary *)emojiAliases {
    static NSDictionary *_emojiAliases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"emoji"
                                                         ofType:@"json"];
        NSData *data   = [NSData dataWithContentsOfFile:path];
        _emojiAliases  = [NSJSONSerialization JSONObjectWithData:data
                                                        options:kNilOptions
                                                          error:nil];
    });
    return _emojiAliases;
}

@end
