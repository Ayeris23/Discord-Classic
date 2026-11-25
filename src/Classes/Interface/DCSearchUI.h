//
//  DCSearchUI.h
//  Discord Classic
//
//  Created by Ayeris on 11/24/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <UIKit/UIKit.h>

@interface DCSearchUI : NSObject

+ (UISearchBar *)searchBarWithPlaceholder:(NSString *)placeholder
                                 delegate:(id<UISearchBarDelegate>)delegate;
+ (void)styleCancelButtonInSearchBar:(UISearchBar *)searchBar;

@end
