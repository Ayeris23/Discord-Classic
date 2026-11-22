//
//  DCMemberListSectionHeaderView.m
//  Discord Classic
//

#import "DCMemberListSectionHeaderView.h"
#import "DCInterfaceStyle.h"

static const CGFloat DCMemberListHeaderHeight = 22.0f;

@interface DCMemberListSectionHeaderView ()
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation DCMemberListSectionHeaderView

@synthesize title = _title;

+ (CGFloat)headerHeight {
    return DCMemberListHeaderHeight;
}

- (id)initWithFrame:(CGRect)frame {
    frame.size.height = DCMemberListHeaderHeight;
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _titleInset = 10.0f;
    self.backgroundColor = [UIColor colorWithPatternImage:
                            [DCInterfaceStyle notificationBackgroundImage]];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(
        10.0f, 0.0f, MAX(0.0f, frame.size.width - 20.0f), DCMemberListHeaderHeight)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:12.0f];
    if (!label.font) label.font = [UIFont boldSystemFontOfSize:12.0f];
    label.textColor = [UIColor colorWithRed:168.0f / 255.0f
                                      green:168.0f / 255.0f
                                       blue:168.0f / 255.0f alpha:1.0f];
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0.0f, 1.0f);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:label];
    self.titleLabel = label;

    return self;
}

- (void)setTitleInset:(CGFloat)titleInset {
    _titleInset = titleInset;
    CGRect frame = self.titleLabel.frame;
    frame.origin.x = titleInset;
    frame.size.width = MAX(0.0f, self.bounds.size.width - titleInset - 10.0f);
    self.titleLabel.frame = frame;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect frame = self.titleLabel.frame;
    frame.origin.x = self.titleInset;
    frame.size.width = MAX(0.0f, self.bounds.size.width - self.titleInset - 10.0f);
    if (!CGRectEqualToRect(self.titleLabel.frame, frame)) self.titleLabel.frame = frame;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.titleLabel.text = _title;
}

@end
