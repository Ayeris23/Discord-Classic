//
//  DCInfoPageViewController.m
//  Discord Classic
//
//  Created by Trevir on 11/24/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCInfoPageViewController.h"

@interface DCInfoPageViewController ()
@property NSArray *creditLinks;
@end

@implementation DCInfoPageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.creditLinks = [NSArray arrayWithObjects:
        [NSArray array],
        [NSArray arrayWithObjects:@"https://bag-xml.com/me/", @"https://github.com/ndcube",
            [NSNull null], [NSNull null], nil],
        [NSArray arrayWithObjects:@"https://github.com/apploft/APLSlideMenu",
            @"https://github.com/nicklockwood", [NSNull null], @"https://github.com/instructure",
            @"https://www.webmproject.org", @"https://diy.org",
            @"https://github.com/SDWebImage/SDWebImage", [NSNull null],
            @"https://bag-xml.com/me/", @"https://github.com/mayoff",
            [NSNull null], @"https://discord.com",
            @"https://github.com/Cocoanetics/DTFoundation",
            @"https://github.com/Cocoanetics/DTCoreText", nil],
        [NSArray arrayWithObjects:@"https://twitter.com/trev3d",
            @"https://twitter.com/torutheredfox", nil], nil];
    
    NSString *version = [[NSUserDefaults standardUserDefaults] stringForKey:@"version"];
    self.versionLabel.text = [NSString stringWithFormat:@"%@", version];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.section >= self.creditLinks.count) return;
    NSArray *sectionLinks = [self.creditLinks objectAtIndex:indexPath.section];
    if (indexPath.row >= sectionLinks.count) return;
    id urlString = [sectionLinks objectAtIndex:indexPath.row];
    if ([urlString isKindOfClass:[NSString class]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlString]];
    }
}

@end
