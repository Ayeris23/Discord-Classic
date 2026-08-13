#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

@interface UILazyImageView : UIImageView
@property (nonatomic, strong) NSURL *imageURL;
- (void)prepareChatThumbnailForDisplaySize:(CGSize)displaySize;
- (void)prepareChatThumbnailForDisplaySize:(CGSize)displaySize
                              allowLoading:(BOOL)allowLoading;
- (void)releaseChatThumbnailForResidency;
@end
