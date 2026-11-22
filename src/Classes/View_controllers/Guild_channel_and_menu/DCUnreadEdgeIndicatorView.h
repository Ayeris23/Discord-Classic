//  DCUnreadEdgeIndicatorView.h
//  Discord Classic

#import <UIKit/UIKit.h>

typedef enum {
    DCUnreadEdgeTop = 0,
    DCUnreadEdgeBottom = 1
} DCUnreadEdge;

// A clipped, touch-through viewport for indicators layered over a scrolling list.
@interface DCUnreadEdgeOverlayView : UIView
@end

@interface DCUnreadEdgeIndicatorView : UIView

+ (CGFloat)animationOverflow;
- (id)initWithEdge:(DCUnreadEdge)edge;
- (id)initWithEdge:(DCUnreadEdge)edge title:(NSString *)title horizontalTextInset:(CGFloat)inset;
- (void)addTarget:(id)target action:(SEL)action;
@property (nonatomic, assign) CGFloat gradientPeakOpacity;
- (void)setGradientOcclusionRanges:(NSArray *)ranges;
- (void)setActive:(BOOL)active animated:(BOOL)animated;

@end
