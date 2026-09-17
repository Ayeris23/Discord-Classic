//
//  DCConnectionPopup.m
//  Discord Classic
//
//  Created by Ayeris on 9/16/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCConnectionPopup.h"
#import "DCInterfaceStyle.h"
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>

static CGFloat const DCConnectionPopupHeight = 34.0f;
static CGFloat const DCConnectionPopupShadowHeight = 3.0f;

@interface DCConnectionPopupBannerView : UIView
@property (strong, nonatomic) CAGradientLayer *bottomShadow;
@end

@implementation DCConnectionPopupBannerView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;

        CAGradientLayer *shadow = [CAGradientLayer layer];
        shadow.colors = @[(id)[UIColor colorWithWhite:0.0f alpha:0.15f].CGColor,
                          (id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor];
        [self.layer addSublayer:shadow];
        self.bottomShadow = shadow;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.bottomShadow.frame = CGRectMake(0.0f,
                                         self.bounds.size.height,
                                         self.bounds.size.width,
                                         DCConnectionPopupShadowHeight);
}

@end

@interface DCConnectionPopup ()
@property (strong, nonatomic) DCConnectionPopupBannerView *popupView;
@property (strong, nonatomic) UILabel *titleLabel;
@property (strong, nonatomic) UIActivityIndicatorView *spinner;
@property (copy, nonatomic) NSString *title;
@property (assign, nonatomic) BOOL requestedVisible;
@property (assign, nonatomic) BOOL popupVisible;
@property (weak, nonatomic) UIView *activeHostView;
@end

@implementation DCConnectionPopup

+ (DCConnectionPopup *)sharedPopup {
    static DCConnectionPopup *sharedPopup = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedPopup = [[DCConnectionPopup alloc] init];
    });
    return sharedPopup;
}

- (void)buildPopupIfNeeded {
    if (self.popupView) return;

    DCConnectionPopupBannerView *popupView =
        [[DCConnectionPopupBannerView alloc] initWithFrame:CGRectMake(0.0f,
                                                                       0.0f,
                                                                       0.0f,
                                                                       DCConnectionPopupHeight)];
    popupView.backgroundColor =
        [UIColor colorWithPatternImage:[DCInterfaceStyle notificationBackgroundImage]];
    popupView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = [UIColor colorWithRed:168.0f / 255.0f
                                      green:168.0f / 255.0f
                                       blue:168.0f / 255.0f
                                      alpha:1.0f];
    label.font = [UIFont boldSystemFontOfSize:15.0f];
    label.textAlignment = (NSTextAlignment)UITextAlignmentLeft;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0.0f, 1.0f);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                               UIViewAutoresizingFlexibleTopMargin |
                               UIViewAutoresizingFlexibleBottomMargin;
    [spinner startAnimating];

    [popupView addSubview:label];
    [popupView addSubview:spinner];

    self.popupView = popupView;
    self.titleLabel = label;
    self.spinner = spinner;
}

- (void)layoutPopup {
    UIView *hostView = self.activeHostView;
    if (!hostView) return;

    CGFloat width = hostView.bounds.size.width;
    self.popupView.frame = CGRectMake(0.0f,
                                      0.0f,
                                      width,
                                      DCConnectionPopupHeight);
    self.titleLabel.frame = CGRectMake(12.0f,
                                       0.0f,
                                       MAX(0.0f, width - 54.0f),
                                       DCConnectionPopupHeight);
    self.spinner.center = CGPointMake(MAX(22.0f, width - 22.0f),
                                      DCConnectionPopupHeight / 2.0f);
    [self.popupView setNeedsLayout];
}

- (void)presentIfPossible {
    if (!self.requestedVisible || !self.activeHostView || !self.activeHostView.window) return;

    [self buildPopupIfNeeded];
    self.titleLabel.text = self.title;

    UIView *hostView = self.activeHostView;
    BOOL alreadyVisible = self.popupVisible && self.popupView.superview == hostView;

    if (self.popupView.superview != hostView) {
        [self.popupView removeFromSuperview];
        [hostView addSubview:self.popupView];
        alreadyVisible = NO;
    } else {
        [hostView bringSubviewToFront:self.popupView];
    }

    if (alreadyVisible) {
        [self layoutPopup];
        return;
    }

    CGFloat width = hostView.bounds.size.width;
    self.popupView.frame = CGRectMake(0.0f,
                                      -DCConnectionPopupHeight,
                                      width,
                                      DCConnectionPopupHeight);
    self.titleLabel.frame = CGRectMake(12.0f,
                                       0.0f,
                                       MAX(0.0f, width - 54.0f),
                                       DCConnectionPopupHeight);
    self.spinner.center = CGPointMake(MAX(22.0f, width - 22.0f),
                                      DCConnectionPopupHeight / 2.0f);
    [self.popupView setNeedsLayout];
    self.popupVisible = YES;

    [UIView animateWithDuration:0.25
                     animations:^{
                         [self layoutPopup];
                     }];
}

- (void)showWithTitle:(NSString *)title {
    if (title.length == 0) return;

    void (^showBlock)(void) = ^{
        self.title = title;
        self.requestedVisible = YES;
        [self buildPopupIfNeeded];
        self.titleLabel.text = title;
        [self presentIfPossible];
    };

    if ([NSThread isMainThread]) {
        showBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), showBlock);
    }
}

- (void)dismiss {
    void (^dismissBlock)(void) = ^{
        self.requestedVisible = NO;

        if (!self.popupView.superview) {
            self.popupVisible = NO;
            return;
        }

        UIView *popupView = self.popupView;
        [UIView animateWithDuration:0.20
                         animations:^{
                             CGRect frame = popupView.frame;
                             frame.origin.y = -DCConnectionPopupHeight;
                             popupView.frame = frame;
                         }
                         completion:^(BOOL finished) {
                             if (!self.requestedVisible && self.popupView == popupView) {
                                 [popupView removeFromSuperview];
                                 self.popupVisible = NO;
                             }
                         }];
    };

    if ([NSThread isMainThread]) {
        dismissBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), dismissBlock);
    }
}

- (void)setHostView:(UIView *)hostView {
    void (^hostBlock)(void) = ^{
        if (self.activeHostView == hostView) {
            [self presentIfPossible];
            return;
        }

        [self.popupView removeFromSuperview];
        self.popupVisible = NO;
        self.activeHostView = hostView;
        [self presentIfPossible];
    };

    if ([NSThread isMainThread]) {
        hostBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), hostBlock);
    }
}

- (void)clearHostView:(UIView *)hostView {
    void (^clearBlock)(void) = ^{
        if (self.activeHostView != hostView) return;

        [self.popupView removeFromSuperview];
        self.popupVisible = NO;
        self.activeHostView = nil;
    };

    if ([NSThread isMainThread]) {
        clearBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), clearBlock);
    }
}

@end
