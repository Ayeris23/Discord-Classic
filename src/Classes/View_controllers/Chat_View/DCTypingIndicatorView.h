//
//  DCTypingIndicatorView.h
//  Discord Classic
//

#import <UIKit/UIKit.h>

@class DCChannel;
@class DCTypingIndicatorView;

@protocol DCTypingIndicatorViewDelegate <NSObject>
- (BOOL)typingIndicatorShouldFollowLiveTail:(DCTypingIndicatorView *)indicator;
@end

@interface DCTypingIndicatorView : UIView

@property (nonatomic, weak) id<DCTypingIndicatorViewDelegate> delegate;
@property (nonatomic, weak) UITableView *chatTableView;
@property (nonatomic, assign, readonly, getter=isPresented) BOOL presented;

+ (CGFloat)bannerHeight;
- (id)initWithFrame:(CGRect)frame tableView:(UITableView *)tableView;
- (void)userStartedTypingWithID:(NSString *)userID inChannel:(DCChannel *)channel;
- (void)userStoppedTypingWithID:(NSString *)userID;
- (void)positionAboveComposerAtY:(CGFloat)composerTop;
- (void)resetForChannelChange;
- (void)invalidateTypingTimers;

@end
