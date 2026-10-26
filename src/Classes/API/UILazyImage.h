#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface UILazyImage: NSObject
@property (strong, nonatomic) UIImage *image;
@property (strong, nonatomic) NSURL *imageURL;
@property (assign, nonatomic) BOOL spoiler;
@property (copy, nonatomic) NSString *spoilerKey;
@property (copy, nonatomic) NSString *spoilerPlaceholder;
@property (assign, nonatomic) CGSize naturalSize;
@end
