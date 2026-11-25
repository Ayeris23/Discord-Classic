//
//  DCSearchUI.m
//  Discord Classic
//
//  Created by Ayeris on 11/24/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCSearchUI.h"
#import "DCInterfaceStyle.h"

@implementation DCSearchUI

+ (UISearchBar *)searchBarWithPlaceholder:(NSString *)placeholder
                                 delegate:(id<UISearchBarDelegate>)delegate {
    UISearchBar *searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 44.0f)];
    searchBar.delegate = delegate;
    searchBar.placeholder = placeholder;
    searchBar.barStyle = UIBarStyleBlack;
    searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    searchBar.backgroundImage = [UIImage imageNamed:@"SearchBarBackground"];
    [searchBar layoutIfNeeded];
    [self configureKeyboardAppearanceInView:searchBar];
    return searchBar;
}

+ (void)configureKeyboardAppearanceInView:(UIView *)view {
    if ([view isKindOfClass:[UITextField class]]) {
        ((UITextField *)view).keyboardAppearance = UIKeyboardAppearanceAlert;
    }
    for (UIView *subview in view.subviews) {
        [self configureKeyboardAppearanceInView:subview];
    }
}

+ (void)styleCancelButtonInView:(UIView *)view {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        if ([title isEqualToString:NSLocalizedString(@"Cancel", nil)] ||
            [title isEqualToString:@"Cancel"]) {
            UIImage *normal = [[DCInterfaceStyle barButtonBackgroundImage]
                resizableImageWithCapInsets:UIEdgeInsetsMake(0.0f, 5.0f, 0.0f, 5.0f)];
            UIImage *pressed = [[DCInterfaceStyle barButtonPressedBackgroundImage]
                resizableImageWithCapInsets:UIEdgeInsetsMake(0.0f, 5.0f, 0.0f, 5.0f)];
            [button setBackgroundImage:normal forState:UIControlStateNormal];
            [button setBackgroundImage:pressed forState:UIControlStateHighlighted];
            [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [button setTitleShadowColor:[UIColor blackColor] forState:UIControlStateNormal];
            button.titleLabel.shadowOffset = CGSizeMake(0.0f, -1.0f);
        }
    }
    for (UIView *subview in view.subviews) [self styleCancelButtonInView:subview];
}

+ (void)styleCancelButtonInSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;
    [searchBar layoutIfNeeded];
    [self configureKeyboardAppearanceInView:searchBar];
    [self styleCancelButtonInView:searchBar];
}

@end
