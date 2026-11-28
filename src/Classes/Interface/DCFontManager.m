//
//  DCFontManager.m
//  Discord Classic
//
//  Created by Ayeris on 11/25/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCFontManager.h"
#import <CoreText/CoreText.h>
#import <dispatch/dispatch.h>

@interface DCFontManager ()
@property (nonatomic, assign) BOOL preparing;
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, strong) NSMutableArray *preparationCompletions;
@property (nonatomic, strong) NSArray *fallbackFontNames;
@property (nonatomic, strong) NSDictionary *fontCoverage;
@property (nonatomic, strong) NSCache *fallbackCache;
@property (nonatomic, strong) NSMutableSet *reportedFonts;
@end

@implementation DCFontManager

+ (DCFontManager *)sharedManager {
    static DCFontManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[DCFontManager alloc] init];
    });
    return manager;
}

- (id)init {
    self = [super init];
    if (self) {
        _preparationCompletions = [[NSMutableArray alloc] init];
        _fallbackCache = [[NSCache alloc] init];
        _fallbackCache.countLimit = 512;
        _reportedFonts = [[NSMutableSet alloc] init];
    }
    return self;
}

- (NSURL *)bundleURLForFont:(NSString *)fileName {
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *url = [bundle URLForResource:fileName withExtension:@"ttf"];
    if (!url) {
        url = [bundle URLForResource:fileName withExtension:@"ttf" subdirectory:@"Fonts"];
    }
    if (!url) {
        url = [bundle URLForResource:fileName withExtension:@"ttf" subdirectory:@"Assets/Fonts"];
    }
    return url;
}

- (NSString *)registerFontAtURL:(NSURL *)url {
    CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
    if (!provider) return nil;
    CGFontRef graphicsFont = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!graphicsFont) return nil;

    NSString *name = CFBridgingRelease(CGFontCopyPostScriptName(graphicsFont));
    CGFontRelease(graphicsFont);
    if (!name.length) return nil;

    CFErrorRef error = NULL;
    BOOL registered = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                                       kCTFontManagerScopeProcess, &error);
    if (!registered && (!error || CFErrorGetCode(error) != kCTFontManagerErrorAlreadyRegistered)) {
        NSLog(@"[Fonts] Registration failed for %@: %@", [url lastPathComponent],
              (__bridge NSError *)error);
        if (error) CFRelease(error);
        return nil;
    }
    if (error) CFRelease(error);
    return name;
}

- (void)prepareBundledFontsWithCompletion:(void (^)(void))completion {
    if (self.prepared) {
        if (completion) completion();
        return;
    }
    if (![UILabel instancesRespondToSelector:@selector(setAttributedText:)]) {
        self.prepared = YES;
        NSLog(@"[Fonts] Attributed labels unavailable; using system fonts");
        if (completion) completion();
        return;
    }
    if (completion) [self.preparationCompletions addObject:[completion copy]];
    if (self.preparing) return;
    self.preparing = YES;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            NSArray *files = @[@"NotoSansMath-Regular", @"NotoSansSymbols-Regular",
                               @"NotoSansSymbols2-Regular"];
            NSMutableArray *names = [NSMutableArray arrayWithCapacity:files.count];
            NSMutableDictionary *coverage = [NSMutableDictionary dictionaryWithCapacity:files.count];
            for (NSString *file in files) {
                NSURL *url = [self bundleURLForFont:file];
                if (!url) {
                    NSLog(@"[Fonts] Missing bundle resource: %@.ttf", file);
                    continue;
                }
                NSString *name = [self registerFontAtURL:url];
                if (!name) {
                    NSLog(@"[Fonts] Could not load %@.ttf", file);
                    continue;
                }
                CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)name, 12.0, NULL);
                if (!font) continue;
                NSString *actualName = CFBridgingRelease(CTFontCopyPostScriptName(font));
                NSCharacterSet *characters = CFBridgingRelease(CTFontCopyCharacterSet(font));
                CFRelease(font);
                if (![actualName isEqualToString:name] || !characters) {
                    NSLog(@"[Fonts] Core Text could not resolve %@", name);
                    continue;
                }
                [names addObject:name];
                [coverage setObject:characters forKey:name];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableArray *available = [NSMutableArray arrayWithCapacity:names.count];
                for (NSString *name in names) {
                    UIFont *font = [UIFont fontWithName:name size:12.0];
                    if (font) {
                        [available addObject:name];
                        NSLog(@"[Fonts] Registered %@", name);
                    } else {
                        NSLog(@"[Fonts] UIKit could not resolve %@", name);
                    }
                }
                self.fallbackFontNames = [available copy];
                self.fontCoverage = [coverage copy];
                self.preparing = NO;
                self.prepared = YES;
                NSLog(@"[Fonts] Ready: %lu/%lu fonts", (unsigned long)available.count,
                      (unsigned long)files.count);

                NSArray *completions = [self.preparationCompletions copy];
                [self.preparationCompletions removeAllObjects];
                for (void (^block)(void) in completions) block();
            });
        }
    });
}

// A single Unicode scalar may occupy two UTF-16 code units.
static UTF32Char DCFontScalarForRange(NSString *text, NSRange range) {
    if (range.length == 1) {
        unichar value = [text characterAtIndex:range.location];
        if (value < 0xD800 || value > 0xDFFF) return value;
    } else if (range.length == 2) {
        unichar high = [text characterAtIndex:range.location];
        unichar low = [text characterAtIndex:range.location + 1];
        if (high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) {
            return 0x10000 + (((UTF32Char)high - 0xD800) << 10) + ((UTF32Char)low - 0xDC00);
        }
    }
    return 0;
}

- (NSString *)fallbackNameForScalar:(UTF32Char)scalar
                             text:(NSString *)text
                            range:(NSRange)range
                         baseFont:(UIFont *)baseFont {
    NSString *key = [NSString stringWithFormat:@"%@:%lX", baseFont.fontName,
                     (unsigned long)scalar];
    id cached = [self.fallbackCache objectForKey:key];
    if (cached) return cached == [NSNull null] ? nil : cached;

    NSString *candidate = nil;
    for (NSString *name in self.fallbackFontNames) {
        NSCharacterSet *characters = [self.fontCoverage objectForKey:name];
        if ([characters longCharacterIsMember:scalar]) {
            candidate = name;
            break;
        }
    }
    if (candidate) {
        CTFontRef base = CTFontCreateWithName((__bridge CFStringRef)baseFont.fontName,
                                             baseFont.pointSize, NULL);
        if (base) {
            CTFontRef system = CTFontCreateForString(base, (__bridge CFStringRef)text,
                                                     CFRangeMake(range.location, range.length));
            if (system) {
                NSString *name = CFBridgingRelease(CTFontCopyPostScriptName(system));
                NSCharacterSet *characters = CFBridgingRelease(CTFontCopyCharacterSet(system));
                BOOL isLastResort = name && [name rangeOfString:@"LastResort" options:NSCaseInsensitiveSearch].location != NSNotFound;
                if (!isLastResort && [characters longCharacterIsMember:scalar]) {
                    // Keep native fallback unless Core Text already chose one of our fonts.
                    candidate = [self.fallbackFontNames containsObject:name] ? name : nil;
                }
                CFRelease(system);
            }
            CFRelease(base);
        }
    }
    [self.fallbackCache setObject:(candidate ?: (id)[NSNull null]) forKey:key];
    return candidate;
}

- (void)setText:(NSString *)text forLabel:(UILabel *)label baseFont:(UIFont *)baseFont {
    if (!label) return;
    baseFont = baseFont ?: label.font;
    label.text = text;
    if (baseFont && ![label.font isEqual:baseFont]) label.font = baseFont;

    if (!self.prepared || !self.fallbackFontNames.count || !text.length || !baseFont ||
        ![label respondsToSelector:@selector(setAttributedText:)] ||
        [text canBeConvertedToEncoding:NSASCIIStringEncoding]) return;

    NSMutableAttributedString *styled = nil;
    NSUInteger index = 0;
    while (index < text.length) {
        NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:index];
        index = NSMaxRange(range);
        UTF32Char scalar = DCFontScalarForRange(text, range);
        // Leave combining sequences and emoji clusters to the system shaper.
        if (scalar < 0x80) continue;

        NSString *name = [self fallbackNameForScalar:scalar text:text range:range baseFont:baseFont];
        if (!name) continue;
        UIFont *font = [UIFont fontWithName:name size:baseFont.pointSize];
        if (!font) continue;

        if (!styled) {
            NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
            paragraph.alignment = label.textAlignment;
            paragraph.lineBreakMode = label.lineBreakMode;
            NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                baseFont, NSFontAttributeName, paragraph, NSParagraphStyleAttributeName, nil];
            if (label.textColor) [attributes setObject:label.textColor forKey:NSForegroundColorAttributeName];
            if (label.shadowColor) {
                NSShadow *shadow = [[NSShadow alloc] init];
                shadow.shadowColor = label.shadowColor;
                shadow.shadowOffset = label.shadowOffset;
                [attributes setObject:shadow forKey:NSShadowAttributeName];
            }
            styled = [[NSMutableAttributedString alloc] initWithString:text attributes:attributes];
        }
        [styled addAttribute:NSFontAttributeName value:font range:range];
        if (![self.reportedFonts containsObject:name]) {
            [self.reportedFonts addObject:name];
            NSLog(@"[Fonts] Explicit fallback U+%04lX: %@", (unsigned long)scalar, name);
        }
    }
    if (styled) label.attributedText = styled;
}

@end
