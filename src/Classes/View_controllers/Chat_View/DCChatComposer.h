//
//  DCChatComposer.h
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

// Owns the common chat composer presentation. Existing storyboard toolbars can
// be adopted without changing their outlet geometry or input behavior.
@interface DCChatComposer : NSObject

@property (nonatomic, strong, readonly) UIView *view;
@property (nonatomic, strong, readonly) UIImageView *backgroundImageView;
@property (nonatomic, strong, readonly) UIView *fieldContainer;
@property (nonatomic, strong, readonly) UIImageView *fieldBackgroundView;
@property (nonatomic, strong, readonly) UITextView *textView;
@property (nonatomic, strong, readonly) UILabel *placeholderLabel;
@property (nonatomic, strong, readonly) UIButton *sendButton;
@property (nonatomic, strong, readonly) UIButton *photoButton;
@property (nonatomic, assign) BOOL showsPhotoButton;

- (id)initWithFrame:(CGRect)frame;
- (id)initWithExistingToolbar:(UIView *)toolbar
                backgroundView:(UIImageView *)background
                fieldBackground:(UIImageView *)fieldBackground
                     textView:(UITextView *)textView
                   placeholder:(UILabel *)placeholder
                    sendButton:(UIButton *)sendButton
                   photoButton:(UIButton *)photoButton;

- (void)applyDefaultAppearance;
- (void)updatePlaceholder;

// Used by standalone composers; storyboard chat keeps its established sizing path.
- (CGFloat)preferredHeightWithMaximumLines:(NSUInteger)maximumLines;
- (void)layoutStandaloneContents;

@end
