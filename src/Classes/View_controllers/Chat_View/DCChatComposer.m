//
//  DCChatComposer.m
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCChatComposer.h"
#import "DCInterfaceStyle.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface DCChatComposer ()
@property (nonatomic, strong, readwrite) UIView *view;
@property (nonatomic, strong, readwrite) UIImageView *backgroundImageView;
@property (nonatomic, strong, readwrite) UIView *fieldContainer;
@property (nonatomic, strong, readwrite) UIImageView *fieldBackgroundView;
@property (nonatomic, strong, readwrite) UITextView *textView;
@property (nonatomic, strong, readwrite) UILabel *placeholderLabel;
@property (nonatomic, strong, readwrite) UIButton *sendButton;
@property (nonatomic, strong, readwrite) UIButton *photoButton;
@property (nonatomic, strong) CAGradientLayer *topShadow;
@property (nonatomic, assign) BOOL standalone;
@end

@implementation DCChatComposer

- (id)initWithExistingToolbar:(UIView *)toolbar
                backgroundView:(UIImageView *)background
              fieldBackground:(UIImageView *)fieldBackground
                    textView:(UITextView *)textView
                  placeholder:(UILabel *)placeholder
                   sendButton:(UIButton *)sendButton
                  photoButton:(UIButton *)photoButton {
    self = [super init];
    if (!self) return nil;
    _view = toolbar;
    _backgroundImageView = background;
    _fieldBackgroundView = fieldBackground;
    _fieldContainer = fieldBackground.superview;
    _textView = textView;
    _placeholderLabel = placeholder;
    _sendButton = sendButton;
    _photoButton = photoButton;
    _showsPhotoButton = YES;
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super init];
    if (!self) return nil;
    _standalone = YES;
    _showsPhotoButton = YES;

    UIView *toolbar = [[UIView alloc] initWithFrame:frame];
    toolbar.backgroundColor = [UIColor clearColor];
    toolbar.clipsToBounds = NO;
    toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _view = toolbar;

    UIImageView *background = [[UIImageView alloc] initWithFrame:toolbar.bounds];
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [toolbar addSubview:background];
    _backgroundImageView = background;

    UIView *field = [[UIView alloc] initWithFrame:CGRectMake(43.0f, 7.0f,
        MAX(0.0f, CGRectGetWidth(frame) - 86.0f), 31.0f)];
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [toolbar addSubview:field];
    _fieldContainer = field;

    UIImageView *fieldBackground = [[UIImageView alloc] initWithFrame:field.bounds];
    fieldBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [field addSubview:fieldBackground];
    _fieldBackgroundView = fieldBackground;

    UILabel *placeholder = [[UILabel alloc] initWithFrame:CGRectMake(14.0f, 7.0f,
        MAX(0.0f, CGRectGetWidth(field.bounds) - 28.0f), 18.0f)];
    placeholder.backgroundColor = [UIColor clearColor];
    placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    placeholder.font = [UIFont systemFontOfSize:13.0f];
    placeholder.textColor = [UIColor colorWithRed:128.0f / 255.0f
                                            green:132.0f / 255.0f
                                             blue:143.0f / 255.0f alpha:1.0f];
    placeholder.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.74f];
    placeholder.shadowOffset = CGSizeMake(0, 1);
    placeholder.text = @"Message";
    [field addSubview:placeholder];
    _placeholderLabel = placeholder;

    UITextView *text = [[UITextView alloc] initWithFrame:CGRectMake(4.0f, -1.0f,
        MAX(0.0f, CGRectGetWidth(field.bounds) - 8.0f), 28.0f)];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    text.backgroundColor = [UIColor clearColor];
    text.textColor = [UIColor whiteColor];
    text.font = [UIFont systemFontOfSize:14.0f];
    text.keyboardAppearance = UIKeyboardAppearanceAlert;
    text.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    text.showsHorizontalScrollIndicator = NO;
    text.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    text.bounces = NO;
    text.scrollEnabled = NO;
    [field addSubview:text];
    _textView = text;

    UIButton *photo = [UIButton buttonWithType:UIButtonTypeCustom];
    photo.frame = CGRectMake(6.0f, 7.0f, 31.0f, 31.0f);
    photo.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [toolbar addSubview:photo];
    _photoButton = photo;

    UIButton *send = [UIButton buttonWithType:UIButtonTypeCustom];
    send.frame = CGRectMake(MAX(0.0f, CGRectGetWidth(frame) - 37.0f),
                            7.0f, 31.0f, 31.0f);
    send.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleTopMargin;
    [toolbar addSubview:send];
    _sendButton = send;

    [self applyDefaultAppearance];
    return self;
}

- (void)applyDefaultAppearance {
    UIImage *background = [DCInterfaceStyle toolbarBackgroundImage];
    if ([background respondsToSelector:@selector(resizableImageWithCapInsets:resizingMode:)]) {
        background = [background resizableImageWithCapInsets:
            UIEdgeInsetsMake(23, 0, 20, 0) resizingMode:UIImageResizingModeStretch];
    } else {
        background = [background stretchableImageWithLeftCapWidth:0 topCapHeight:10];
    }
    self.backgroundImageView.image = background;
    self.view.clipsToBounds = NO;

    if (!self.topShadow) {
        CAGradientLayer *shadow = [CAGradientLayer layer];
        shadow.frame = CGRectMake(0, -3, CGRectGetWidth(self.view.bounds), 3);
        shadow.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                          (id)[UIColor colorWithWhite:0 alpha:0.15f].CGColor];
        [self.view.layer insertSublayer:shadow atIndex:0];
        self.topShadow = shadow;
    }

    UIImage *field = [DCInterfaceStyle messageFieldBackgroundImage];
    if ([field respondsToSelector:@selector(resizableImageWithCapInsets:resizingMode:)]) {
        field = [field resizableImageWithCapInsets:UIEdgeInsetsMake(15, 15, 15, 15)
                                      resizingMode:UIImageResizingModeStretch];
    } else {
        field = [field stretchableImageWithLeftCapWidth:15 topCapHeight:15];
    }
    self.fieldBackgroundView.image = field;

    [self.sendButton setBackgroundImage:[DCInterfaceStyle sendButtonBackgroundImage]
                               forState:UIControlStateNormal];
    [self.sendButton setBackgroundImage:[DCInterfaceStyle sendButtonPressedBackgroundImage]
                               forState:UIControlStateHighlighted];
    [self.sendButton setBackgroundImage:[DCInterfaceStyle sendButtonDisabledBackgroundImage]
                               forState:UIControlStateDisabled];
    [self.photoButton setBackgroundImage:[DCInterfaceStyle cameraButtonBackgroundImage]
                                forState:UIControlStateNormal];
    [self.photoButton setBackgroundImage:[DCInterfaceStyle cameraButtonPressedBackgroundImage]
                                forState:UIControlStateHighlighted];
}

- (void)updatePlaceholder {
    self.placeholderLabel.hidden = self.textView.text.length > 0;
}

- (void)setShowsPhotoButton:(BOOL)showsPhotoButton {
    _showsPhotoButton = showsPhotoButton;
    self.photoButton.hidden = !showsPhotoButton;
    if (self.standalone) [self layoutStandaloneContents];
}

- (CGFloat)preferredHeightWithMaximumLines:(NSUInteger)maximumLines {
    if (!self.textView) return 44.0f;
    CGFloat lineHeight = self.textView.font.lineHeight;
    CGFloat maximum = 34.0f + ((MAX((NSUInteger)1, maximumLines) - 1) * lineHeight);
    CGFloat measured = ceilf([self.textView sizeThatFits:CGSizeMake(
        MAX(1.0f, CGRectGetWidth(self.textView.bounds)), CGFLOAT_MAX)].height);
    self.textView.scrollEnabled = measured > maximum;
    CGFloat fieldHeight = measured <= 34.0f ? 28.0f : MAX(28.0f, MIN(measured, maximum));
    return 44.0f + fieldHeight - 28.0f;
}

- (void)layoutStandaloneContents {
    if (!self.standalone) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    self.backgroundImageView.frame = self.view.bounds;
    self.topShadow.frame = CGRectMake(0, -3, width, 3);

    CGFloat left = self.showsPhotoButton ? 43.0f : 6.0f;
    CGFloat fieldWidth = MAX(0.0f, width - left - 43.0f);
    CGFloat growth = MAX(0.0f, height - 44.0f);
    self.fieldContainer.frame = CGRectMake(left, 7, fieldWidth, 31.0f + growth);
    self.fieldBackgroundView.frame = self.fieldContainer.bounds;
    self.textView.frame = CGRectMake(4.0f, -1.0f,
        MAX(0.0f, fieldWidth - 8.0f), 28.0f + growth);
    self.placeholderLabel.frame = CGRectMake(14.0f, 7.0f,
        MAX(0.0f, fieldWidth - 28.0f), 18.0f);
    self.photoButton.frame = CGRectMake(6.0f, height - 37.0f, 31.0f, 31.0f);
    self.sendButton.frame = CGRectMake(MAX(0.0f, width - 37.0f),
        height - 37.0f, 31.0f, 31.0f);
}

@end
