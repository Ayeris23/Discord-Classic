//
//  DCFontManager.h
//  Discord Classic
//
//  Created by Ayeris on 11/25/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCFontManager : NSObject

+ (DCFontManager *)sharedManager;

// Call on the main thread. Completion is delivered on the main thread.
- (void)prepareBundledFontsWithCompletion:(void (^)(void))completion;
- (void)setText:(NSString *)text forLabel:(UILabel *)label baseFont:(UIFont *)baseFont;

@end
