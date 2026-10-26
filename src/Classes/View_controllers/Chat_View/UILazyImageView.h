#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

@class DCChatSpoilerView;

@interface UILazyImageView : UIImageView
@property (nonatomic, strong) DCChatSpoilerView *spoilerView;
@property (nonatomic, strong) NSURL *imageURL;
- (void)prepareChatThumbnailForDisplaySize:(CGSize)displaySize;
- (void)prepareChatThumbnailForDisplaySize:(CGSize)displaySize
                              allowLoading:(BOOL)allowLoading;
- (void)releaseChatThumbnailForResidency;
@end
