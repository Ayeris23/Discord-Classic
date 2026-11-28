//
//  DCLabel.m
//  Discord Classic
//
//  Created by Ayeris on 11/28/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCLabel.h"
#import <CoreText/CoreText.h>
#import <math.h>

@implementation DCLabel {
    CTLineRef _fallbackLine;
    CTLineRef _truncatedLine;
    CGFloat _truncatedWidth;
}

- (void)clearFallbackLine {
    if (_truncatedLine) CFRelease(_truncatedLine);
    if (_fallbackLine) CFRelease(_fallbackLine);
    _truncatedLine = NULL;
    _fallbackLine = NULL;
    _truncatedWidth = -1.0f;
}

- (void)dealloc {
    [self clearFallbackLine];
}

- (void)setText:(NSString *)text {
    BOOL hadFallback = _fallbackLine != NULL;
    if (hadFallback) [self clearFallbackLine];
    [super setText:text];
    if (hadFallback) [self setNeedsDisplay];
}

- (void)setCoreTextFallback:(NSAttributedString *)text {
    [self clearFallbackLine];
    if (text.length) {
        _fallbackLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    }
    [self setNeedsDisplay];
}

- (void)setFrame:(CGRect)frame {
    if (!_fallbackLine) {
        [super setFrame:frame];
        return;
    }
    CGSize oldSize = self.bounds.size;
    [super setFrame:frame];
    if (_fallbackLine && !CGSizeEqualToSize(oldSize, self.bounds.size)) [self setNeedsDisplay];
}

- (void)setBounds:(CGRect)bounds {
    if (!_fallbackLine) {
        [super setBounds:bounds];
        return;
    }
    CGRect oldBounds = self.bounds;
    [super setBounds:bounds];
    if (_fallbackLine && !CGRectEqualToRect(oldBounds, bounds)) [self setNeedsDisplay];
}

- (CTLineRef)fallbackLineForWidth:(CGFloat)width {
    if (CTLineGetTypographicBounds(_fallbackLine, NULL, NULL, NULL) <= width)
        return _fallbackLine;
    if (self.lineBreakMode != UILineBreakModeTailTruncation) return _fallbackLine;
    if (_truncatedWidth == width) return _truncatedLine;
    if (_truncatedLine) CFRelease(_truncatedLine);
    _truncatedLine = NULL;
    _truncatedWidth = width;

    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)self.font.fontName,
                                         self.font.pointSize, NULL);
    if (!font) return _fallbackLine;
    NSDictionary *attributes = @{
        (__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
        (__bridge NSString *)kCTForegroundColorFromContextAttributeName: @YES
    };
    NSAttributedString *ellipsis = [[NSAttributedString alloc] initWithString:@"\u2026"
                                                                  attributes:attributes];
    CTLineRef token = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)ellipsis);
    if (token) {
        _truncatedLine = CTLineCreateTruncatedLine(_fallbackLine, width,
                                                   kCTLineTruncationEnd, token);
        CFRelease(token);
    }
    CFRelease(font);
    return _truncatedLine;
}

- (void)drawTextInRect:(CGRect)rect {
    if (!_fallbackLine || self.numberOfLines != 1 || self.adjustsFontSizeToFitWidth) {
        [super drawTextInRect:rect];
        return;
    }
    CGRect bounds = self.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    if (width <= 0.0f || CGRectGetHeight(bounds) <= 0.0f) return;
    CTLineRef line = [self fallbackLineForWidth:width];
    if (!line) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    static BOOL reportedDraw = NO;
    if (!reportedDraw) {
        reportedDraw = YES;
        NSLog(@"[Fonts] DCLabel Core Text draw active");
    }

    CGFloat ascent = 0.0f, descent = 0.0f;
    CGFloat lineWidth = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    CGFloat x = 0.0f;
    if (self.textAlignment == UITextAlignmentCenter) x = (width - lineWidth) * 0.5f;
    else if (self.textAlignment == UITextAlignmentRight) x = width - lineWidth;
    CGFloat y = (CGRectGetHeight(bounds) - ascent - descent) * 0.5f + descent;
    CGFloat scale = self.contentScaleFactor;
    if (scale <= 0.0f) scale = 1.0f;
    x = roundf(x * scale) / scale;
    y = roundf(y * scale) / scale;
    UIColor *color = (self.highlighted ? self.highlightedTextColor : nil)
        ?: self.textColor ?: [UIColor blackColor];

    CGContextSaveGState(context);
    CGContextClipToRect(context, bounds);
    CGContextTranslateCTM(context, CGRectGetMinX(bounds), CGRectGetMaxY(bounds));
    CGContextScaleCTM(context, 1.0f, -1.0f);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextDrawingMode(context, kCGTextFill);
    if (self.shadowColor) {
        CGContextSetFillColorWithColor(context, self.shadowColor.CGColor);
        CGContextSetTextPosition(context, x + self.shadowOffset.width, y - self.shadowOffset.height);
        CTLineDraw(line, context);
    }
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextSetTextPosition(context, x, y);
    CTLineDraw(line, context);
    CGContextRestoreGState(context);
}

@end
