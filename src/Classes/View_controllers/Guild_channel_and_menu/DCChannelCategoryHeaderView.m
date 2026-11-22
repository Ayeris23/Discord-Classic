//
//  DCChannelCategoryHeaderView.m
//  Discord Classic
//

#import "DCChannelCategoryHeaderView.h"

@interface DCChannelDisclosureTriangle : UIView
@property (nonatomic, assign) BOOL collapsed;
@end

@implementation DCChannelDisclosureTriangle

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.userInteractionEnabled = NO;
    return self;
}

- (void)setCollapsed:(BOOL)collapsed {
    if (_collapsed == collapsed) return;
    _collapsed = collapsed;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context,
        [UIColor colorWithRed:0.66f green:0.66f blue:0.66f alpha:1.0f].CGColor);
    if (self.collapsed) {
        CGContextMoveToPoint(context, 2.0f, 0.5f);
        CGContextAddLineToPoint(context, 8.0f, 4.5f);
        CGContextAddLineToPoint(context, 2.0f, 8.5f);
    } else {
        CGContextMoveToPoint(context, 0.5f, 2.0f);
        CGContextAddLineToPoint(context, 8.5f, 2.0f);
        CGContextAddLineToPoint(context, 4.5f, 8.0f);
    }
    CGContextClosePath(context);
    CGContextFillPath(context);
}

@end

@interface DCChannelCategoryHeaderView ()
@property (nonatomic, strong) DCChannelDisclosureTriangle *triangle;
@end

@implementation DCChannelCategoryHeaderView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.titleInset = 26.0f;
    DCChannelDisclosureTriangle *triangle = [[DCChannelDisclosureTriangle alloc]
        initWithFrame:CGRectMake(9.0f, 6.5f, 9.0f, 9.0f)];
    [self addSubview:triangle];
    self.triangle = triangle;
    return self;
}

- (void)setCollapsed:(BOOL)collapsed {
    _collapsed = collapsed;
    self.triangle.collapsed = collapsed;
}

@end
