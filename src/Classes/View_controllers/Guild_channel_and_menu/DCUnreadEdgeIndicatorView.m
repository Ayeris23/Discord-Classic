//  DCUnreadEdgeIndicatorView.m
//  Discord Classic

#import "DCUnreadEdgeIndicatorView.h"
#import "DCInterfaceStyle.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@implementation DCUnreadEdgeOverlayView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01f || !self.userInteractionEnabled ||
        ![self pointInside:point withEvent:event]) return nil;

    for (UIView *child in [self.subviews reverseObjectEnumerator]) {
        UIView *hit = [child hitTest:[self convertPoint:point toView:child]
                               withEvent:event];
        if (hit) return hit;
    }
    return nil;
}

@end

@interface DCUnreadEdgeIndicatorView ()
@property (nonatomic, retain) UIView *gradientView;
@property (nonatomic, retain) CAGradientLayer *gradientLayer;
@property (nonatomic, copy) NSArray *gradientOcclusionRanges;
@property (nonatomic, retain) UIButton *badgeButton;
@property (nonatomic, assign) DCUnreadEdge edge;
@property (nonatomic, assign) CGFloat badgeWidth;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSUInteger transitionGeneration;
@property (nonatomic, assign) BOOL firstEntrancePending;
@property (nonatomic, assign) BOOL firstEntranceCompleted;
@end

static const CGFloat DCUnreadEdgeBadgeTravel = 28.0f;
static const CGFloat DCUnreadEdgeGradientTravel = 42.0f;
static const CGFloat DCUnreadEdgeVisibleHeight = 35.0f;

@implementation DCUnreadEdgeIndicatorView

+ (CGFloat)animationOverflow {
    return MAX(DCUnreadEdgeBadgeTravel, DCUnreadEdgeGradientTravel);
}

- (id)initWithEdge:(DCUnreadEdge)edge {
    return [self initWithEdge:edge title:@"New" horizontalTextInset:0.0f];
}

- (id)initWithEdge:(DCUnreadEdge)edge title:(NSString *)title horizontalTextInset:(CGFloat)inset {
    CGFloat overflow = [DCUnreadEdgeIndicatorView animationOverflow];
    self = [super initWithFrame:CGRectMake(0, 0, 60,
                                           DCUnreadEdgeVisibleHeight + 2.0f * overflow)];
    if (!self) return nil;

    self.edge = edge;
    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = YES;
    self.hidden = YES;

    UIView *gradient = [[UIView alloc] initWithFrame:
        CGRectMake(0.0f, overflow, self.bounds.size.width, DCUnreadEdgeVisibleHeight)];
    gradient.backgroundColor = [UIColor clearColor];
    gradient.userInteractionEnabled = NO;
    CAGradientLayer *layer = [CAGradientLayer layer];
    if (edge == DCUnreadEdgeBottom) {
        layer.startPoint = CGPointMake(0.5f, 1.0f);
        layer.endPoint = CGPointMake(0.5f, 0.0f);
    } else {
        layer.startPoint = CGPointMake(0.5f, 0.0f);
        layer.endPoint = CGPointMake(0.5f, 1.0f);
    }
    [gradient.layer addSublayer:layer];
    [self addSubview:gradient];
    self.gradientView = gradient;
    self.gradientLayer = layer;
    self.gradientPeakOpacity = 1.0f;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *badge = [[DCInterfaceStyle mentionBadgeImage]
        resizableImageWithCapInsets:UIEdgeInsetsMake(0.0f, 9.0f, 0.0f, 9.0f)];
    [button setBackgroundImage:badge forState:UIControlStateNormal];
    NSString *badgeTitle = title.length ? title : @"New";
    UIFont *font = [UIFont boldSystemFontOfSize:14.0f];
    CGFloat labelWidth = [badgeTitle sizeWithFont:font].width;
    self.badgeWidth = MAX(56.0f, ceilf(labelWidth) + 2.0f * MAX(0.0f, inset));
    [button setTitle:badgeTitle forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = font;
    button.adjustsImageWhenHighlighted = NO;
    button.frame = CGRectMake(2.0f,
                              overflow + (edge == DCUnreadEdgeTop ? 3.0f : 6.0f),
                              self.badgeWidth, 26.0f);
    [self addSubview:button];
    self.badgeButton = button;
    return self;
}

- (void)updateGradientColors {
    NSMutableArray *spans = [NSMutableArray array];
    for (NSValue *value in self.gradientOcclusionRanges) {
        CGRect rect = [value CGRectValue];
        CGFloat first = MAX(0.0f, MIN(1.0f, CGRectGetMinY(rect) / DCUnreadEdgeVisibleHeight));
        CGFloat last = MAX(0.0f, MIN(1.0f, CGRectGetMaxY(rect) / DCUnreadEdgeVisibleHeight));
        if (last <= first) continue;
        if (self.edge == DCUnreadEdgeBottom) {
            CGFloat reversedFirst = 1.0f - last;
            last = 1.0f - first;
            first = reversedFirst;
        }
        [spans addObject:[NSValue valueWithCGRect:CGRectMake(first, 0.0f, last - first, 1.0f)]];
    }
    [spans sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGFloat firstA = [a CGRectValue].origin.x;
        CGFloat firstB = [b CGRectValue].origin.x;
        return firstA < firstB ? NSOrderedAscending :
               (firstA > firstB ? NSOrderedDescending : NSOrderedSame);
    }];

    NSMutableArray *mergedSpans = [NSMutableArray array];
    for (NSValue *value in spans) {
        CGRect span = [value CGRectValue];
        NSValue *previous = [mergedSpans lastObject];
        if (previous && CGRectGetMaxX([previous CGRectValue]) >= span.origin.x) {
            CGRect united = CGRectUnion([previous CGRectValue], span);
            [mergedSpans replaceObjectAtIndex:mergedSpans.count - 1
                                   withObject:[NSValue valueWithCGRect:united]];
        } else {
            [mergedSpans addObject:value];
        }
    }

    NSMutableArray *colors = [NSMutableArray array];
    NSMutableArray *locations = [NSMutableArray array];
    [colors addObject:(id)[UIColor colorWithWhite:0.0f alpha:self.gradientPeakOpacity].CGColor];
    [locations addObject:[NSNumber numberWithFloat:0.0f]];
    for (NSValue *value in mergedSpans) {
        CGRect span = [value CGRectValue];
        CGFloat first = span.origin.x;
        CGFloat last = CGRectGetMaxX(span);
        CGFloat alphaBefore = self.gradientPeakOpacity * (1.0f - first);
        [colors addObject:(id)[UIColor colorWithWhite:0.0f alpha:alphaBefore].CGColor];
        [locations addObject:[NSNumber numberWithFloat:first]];
        [colors addObject:(id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor];
        [locations addObject:[NSNumber numberWithFloat:first]];
        [colors addObject:(id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor];
        [locations addObject:[NSNumber numberWithFloat:last]];
        [colors addObject:(id)[UIColor colorWithWhite:0.0f
                                                  alpha:self.gradientPeakOpacity * (1.0f - last)].CGColor];
        [locations addObject:[NSNumber numberWithFloat:last]];
    }
    [colors addObject:(id)[UIColor colorWithWhite:0.0f alpha:0.0f].CGColor];
    [locations addObject:[NSNumber numberWithFloat:1.0f]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gradientLayer.colors = colors;
    self.gradientLayer.locations = locations;
    [CATransaction commit];
}

- (void)setGradientPeakOpacity:(CGFloat)gradientPeakOpacity {
    _gradientPeakOpacity = MIN(1.0f, MAX(0.0f, gradientPeakOpacity));
    [self updateGradientColors];
}

- (void)setGradientOcclusionRanges:(NSArray *)ranges {
    if ([self.gradientOcclusionRanges isEqualToArray:ranges] ||
        (!self.gradientOcclusionRanges.count && !ranges.count)) return;
    _gradientOcclusionRanges = [ranges copy];
    [self updateGradientColors];
}

- (void)addTarget:(id)target action:(SEL)action {
    [self.badgeButton addTarget:target action:action
              forControlEvents:UIControlEventTouchUpInside];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGSize size = self.bounds.size;
    CGFloat overflow = [DCUnreadEdgeIndicatorView animationOverflow];
    CGSize gradientSize = CGSizeMake(size.width, DCUnreadEdgeVisibleHeight);
    if (!CGSizeEqualToSize(self.gradientView.bounds.size, gradientSize))
        self.gradientView.bounds = CGRectMake(0.0f, 0.0f,
                                             gradientSize.width, gradientSize.height);
    CGPoint gradientCenter = CGPointMake(size.width * 0.5f,
                                         overflow + DCUnreadEdgeVisibleHeight * 0.5f);
    if (!CGPointEqualToPoint(self.gradientView.center, gradientCenter))
        self.gradientView.center = gradientCenter;
    if (!CGRectEqualToRect(self.gradientLayer.frame, self.gradientView.bounds))
        self.gradientLayer.frame = self.gradientView.bounds;

    CGPoint badgeCenter = CGPointMake(floorf((size.width - self.badgeWidth) * 0.5f) +
                                      self.badgeWidth * 0.5f,
                                      overflow + (self.edge == DCUnreadEdgeTop ? 16.0f : 19.0f));
    if (!CGPointEqualToPoint(self.badgeButton.center, badgeCenter))
        self.badgeButton.center = badgeCenter;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self scheduleFirstEntranceIfNeeded];
}

- (void)scheduleFirstEntranceIfNeeded {
    if (!self.firstEntrancePending || !self.window) return;
    NSUInteger generation = self.transitionGeneration;

    // Commit the initial invisible position before beginning the first animation.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.035 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.transitionGeneration ||
            !self.firstEntrancePending || !self.active || !self.window) return;

        [self layoutIfNeeded];
        self.firstEntrancePending = NO;
        self.firstEntranceCompleted = YES;
        [UIView animateWithDuration:0.15f delay:0.0f
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.badgeButton.transform = CGAffineTransformIdentity;
            self.gradientView.transform = CGAffineTransformIdentity;
            self.badgeButton.alpha = 1.0f;
            self.gradientView.alpha = 1.0f;
        } completion:nil];
    });
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.active || self.hidden) return NO;
    CGPoint buttonPoint = [self convertPoint:point toView:self.badgeButton];
    return [self.badgeButton pointInside:buttonPoint withEvent:event];
}

- (void)setActive:(BOOL)active animated:(BOOL)animated {
    if (self.active == active) return;
    self.active = active;
    self.transitionGeneration++;
    NSUInteger generation = self.transitionGeneration;

    CGFloat badgeExit = self.edge == DCUnreadEdgeTop ? DCUnreadEdgeBadgeTravel : -DCUnreadEdgeBadgeTravel;
    CGFloat gradientExit = self.edge == DCUnreadEdgeTop ? -DCUnreadEdgeGradientTravel : DCUnreadEdgeGradientTravel;
    BOOL shouldAnimate = animated && self.window != nil;

    if (active) {
        BOOL wasHidden = self.hidden;
        if (animated && !self.firstEntranceCompleted && wasHidden) {
            self.hidden = NO;
            [self.badgeButton.layer removeAllAnimations];
            [self.gradientView.layer removeAllAnimations];
            self.badgeButton.transform = CGAffineTransformMakeTranslation(0.0f, badgeExit);
            self.gradientView.transform = CGAffineTransformMakeTranslation(0.0f, gradientExit);
            self.badgeButton.alpha = 0.0f;
            self.gradientView.alpha = 0.0f;
            self.firstEntrancePending = YES;
            [self scheduleFirstEntranceIfNeeded];
            return;
        }
        self.hidden = NO;
        if (!shouldAnimate) {
            self.firstEntranceCompleted = YES;
            [self.badgeButton.layer removeAllAnimations];
            [self.gradientView.layer removeAllAnimations];
            self.badgeButton.transform = CGAffineTransformIdentity;
            self.gradientView.transform = CGAffineTransformIdentity;
            self.badgeButton.alpha = 1.0f;
            self.gradientView.alpha = 1.0f;
            return;
        }
        self.firstEntranceCompleted = YES;
        if (wasHidden) {
            self.badgeButton.transform = CGAffineTransformMakeTranslation(0.0f, badgeExit);
            self.gradientView.transform = CGAffineTransformMakeTranslation(0.0f, gradientExit);
            self.badgeButton.alpha = 0.0f;
            self.gradientView.alpha = 0.0f;
        }
        [UIView animateWithDuration:0.15f delay:0.0f
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.badgeButton.transform = CGAffineTransformIdentity;
            self.gradientView.transform = CGAffineTransformIdentity;
            self.badgeButton.alpha = 1.0f;
            self.gradientView.alpha = 1.0f;
        } completion:nil];
        return;
    }

    if (self.firstEntrancePending) {
        self.firstEntrancePending = NO;
        self.hidden = YES;
        return;
    }

    if (!shouldAnimate) {
        [self.badgeButton.layer removeAllAnimations];
        [self.gradientView.layer removeAllAnimations];
        self.hidden = YES;
        self.badgeButton.transform = CGAffineTransformMakeTranslation(0.0f, badgeExit);
        self.gradientView.transform = CGAffineTransformMakeTranslation(0.0f, gradientExit);
        self.badgeButton.alpha = 0.0f;
        self.gradientView.alpha = 0.0f;
        return;
    }

    [UIView animateWithDuration:0.15f delay:0.0f
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.badgeButton.transform = CGAffineTransformMakeTranslation(0.0f, badgeExit);
        self.gradientView.transform = CGAffineTransformMakeTranslation(0.0f, gradientExit);
        self.badgeButton.alpha = 0.0f;
        self.gradientView.alpha = 0.0f;
    } completion:^(BOOL finished) {
        if (generation == self.transitionGeneration && !self.active)
            self.hidden = YES;
    }];
}

@end
