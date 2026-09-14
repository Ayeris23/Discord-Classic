//
//  DCMultiAttachmentPickerController.m
//  Discord Classic
//
//  Created by Ayeris on 9/13/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCMultiAttachmentPickerController.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@class DCMultiAttachmentPickerController;

@interface DCMultiAttachmentAssetButton : UIButton
@property (nonatomic, assign) NSUInteger assetIndex;
@end

@implementation DCMultiAttachmentAssetButton
@end

@interface DCMultiAttachmentSelectionBadgeSource : NSObject <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DCMultiAttachmentSelectionBadgeSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;

    UIView *selectedBackground = [[UIView alloc] initWithFrame:cell.bounds];
    selectedBackground.backgroundColor = [UIColor clearColor];
    cell.selectedBackgroundView = selectedBackground;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

@end

static UIView *DCMultiAttachmentFindEditControl(UIView *view) {
    NSString *className = NSStringFromClass([view class]);
    if ([className rangeOfString:@"EditControl"].location != NSNotFound) {
        return view;
    }

    for (UIView *subview in view.subviews) {
        UIView *match = DCMultiAttachmentFindEditControl(subview);
        if (match) return match;
    }
    return nil;
}

static UIImage *DCMultiAttachmentFallbackSelectionBadgeImage(void) {
    CGSize size = CGSizeMake(25.0f, 25.0f);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();

    CGRect circleRect = CGRectInset(CGRectMake(0.0f, 0.0f, size.width, size.height), 1.0f, 1.0f);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.05f green:0.42f blue:0.92f alpha:1.0f].CGColor);
    CGContextFillEllipseInRect(context, circleRect);
    CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(context, 2.4f);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextMoveToPoint(context, 6.5f, 12.5f);
    CGContextAddLineToPoint(context, 10.5f, 16.5f);
    CGContextAddLineToPoint(context, 18.5f, 8.0f);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *DCMultiAttachmentNativeSelectionBadgeImage(void) {
    static UIImage *badgeImage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DCMultiAttachmentSelectionBadgeSource *source =
            [[DCMultiAttachmentSelectionBadgeSource alloc] init];
        UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 90.0f, 44.0f)
                                                              style:UITableViewStylePlain];
        tableView.dataSource = source;
        tableView.delegate = source;
        tableView.rowHeight = 44.0f;
        tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        tableView.backgroundColor = [UIColor clearColor];
        tableView.allowsMultipleSelectionDuringEditing = YES;
        [tableView setEditing:YES animated:NO];
        [tableView reloadData];
        [tableView layoutIfNeeded];

        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:0];
        [tableView selectRowAtIndexPath:indexPath
                              animated:NO
                        scrollPosition:UITableViewScrollPositionNone];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        [cell setSelected:YES animated:NO];
        [cell setNeedsLayout];
        [cell layoutIfNeeded];
        [tableView layoutIfNeeded];

        UIView *editControl = DCMultiAttachmentFindEditControl(cell);
        if (editControl && !CGRectIsEmpty(editControl.bounds)) {
            UIGraphicsBeginImageContextWithOptions(editControl.bounds.size, NO, 0.0f);
            [editControl.layer renderInContext:UIGraphicsGetCurrentContext()];
            badgeImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }

        if (!badgeImage) {
            badgeImage = DCMultiAttachmentFallbackSelectionBadgeImage();
        }
    });
    return badgeImage;
}

static NSString *DCFormattedAttachmentByteCount(unsigned long long byteCount) {
    double value = (double)byteCount;
    if (byteCount < 1024ULL) {
        return [NSString stringWithFormat:@"%llu bytes", byteCount];
    }
    if (byteCount < 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f KB", value / 1024.0];
    }
    if (byteCount < 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f MB", value / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.2f GB", value / (1024.0 * 1024.0 * 1024.0)];
}

@interface DCMultiAttachmentAlbumListController : UITableViewController
@property (nonatomic, assign) DCMultiAttachmentPickerController *pickerController;
@property (nonatomic, retain) NSMutableArray *assetGroups;
@end

@interface DCMultiAttachmentAssetGridController : UITableViewController
@property (nonatomic, assign) DCMultiAttachmentPickerController *pickerController;
@property (nonatomic, retain) ALAssetsGroup *assetGroup;
@property (nonatomic, retain) NSMutableArray *assets;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
- (id)initWithAssetGroup:(ALAssetsGroup *)assetGroup;
@end

@interface DCMultiAttachmentOrderController : UITableViewController
@property (nonatomic, assign) DCMultiAttachmentPickerController *pickerController;
@end

@interface DCMultiAttachmentPickerController () <UINavigationControllerDelegate>
@property (nonatomic, retain) ALAssetsLibrary *assetLibrary;
@property (nonatomic, retain) NSMutableArray *selectedAssets;
@property (nonatomic, retain) NSMutableSet *selectedAssetKeys;
- (NSString *)keyForAsset:(ALAsset *)asset;
- (BOOL)isAssetSelected:(ALAsset *)asset;
- (BOOL)toggleAssetSelection:(ALAsset *)asset;
- (void)removeSelectedAssetAtIndex:(NSUInteger)index;
- (void)installNavigationItemsForViewController:(UIViewController *)viewController;
- (void)ensureToolbarVisible;
- (void)refreshToolbar;
- (unsigned long long)selectedAssetByteCount;
- (void)nextPressed:(id)sender;
- (void)deselectPressed:(id)sender;
- (void)donePressed:(id)sender;
@end

@implementation DCMultiAttachmentPickerController

- (id)init {
    return [self initWithSelectedAssets:nil];
}

- (id)initWithSelectedAssets:(NSArray *)assets {
    return [self initWithSelectedAssets:assets assetLibrary:nil];
}

- (id)initWithSelectedAssets:(NSArray *)assets
                  assetLibrary:(ALAssetsLibrary *)assetLibrary {
    DCMultiAttachmentAlbumListController *albums =
        [[DCMultiAttachmentAlbumListController alloc] initWithStyle:UITableViewStylePlain];

    // UINavigationController's iOS 5 implementation of initWithRootViewController:
    // re-enters -init on subclasses. Initialize the navigation controller first,
    // then install the root controller to avoid recursive construction.
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    [self setViewControllers:[NSArray arrayWithObject:albums] animated:NO];

    _maximumSelectionCount = 10;
    _assetLibrary = assetLibrary ?: [[ALAssetsLibrary alloc] init];
    _selectedAssets = [NSMutableArray array];
    _selectedAssetKeys = [NSMutableSet set];
    albums.pickerController = self;
    self.delegate = self;

    for (id object in assets) {
        if (![object isKindOfClass:[ALAsset class]] || _selectedAssets.count >= _maximumSelectionCount) {
            continue;
        }
        ALAsset *asset = (ALAsset *)object;
        NSString *key = [self keyForAsset:asset];
        if (key.length && ![_selectedAssetKeys containsObject:key]) {
            [_selectedAssets addObject:asset];
            [_selectedAssetKeys addObject:key];
        }
    }

    self.navigationBar.barStyle = UIBarStyleBlackTranslucent;
    self.navigationBar.translucent = YES;
    self.toolbar.barStyle = UIBarStyleBlackTranslucent;
    self.toolbar.translucent = YES;
    [self ensureToolbarVisible];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationBar.barStyle = UIBarStyleBlackTranslucent;
    self.navigationBar.translucent = YES;
    self.toolbar.barStyle = UIBarStyleBlackTranslucent;
    self.toolbar.translucent = YES;
    [self ensureToolbarVisible];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ensureToolbarVisible];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self ensureToolbarVisible];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self ensureToolbarVisible];
}

- (void)ensureToolbarVisible {
    [self setToolbarHidden:NO animated:NO];
    self.toolbar.hidden = NO;
    self.toolbar.alpha = 1.0f;
    self.toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    CGFloat toolbarHeight = 44.0f;
    CGRect bounds = self.view.bounds;
    self.toolbar.frame = CGRectMake(0.0f,
                                    CGRectGetHeight(bounds) - toolbarHeight,
                                    CGRectGetWidth(bounds),
                                    toolbarHeight);
    [self.view bringSubviewToFront:self.toolbar];
}

- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    [self installNavigationItemsForViewController:viewController];
}

- (NSString *)keyForAsset:(ALAsset *)asset {
    if (!asset) return nil;

    ALAssetRepresentation *representation = [asset defaultRepresentation];
    NSURL *URL = [representation url];
    if ([URL isKindOfClass:[NSURL class]] && URL.absoluteString.length) {
        return URL.absoluteString;
    }
    return [NSString stringWithFormat:@"%p", asset];
}

- (BOOL)isAssetSelected:(ALAsset *)asset {
    return [self.selectedAssetKeys containsObject:[self keyForAsset:asset]];
}

- (BOOL)toggleAssetSelection:(ALAsset *)asset {
    if (!asset) return NO;

    NSString *key = [self keyForAsset:asset];
    if ([self.selectedAssetKeys containsObject:key]) {
        [self.selectedAssetKeys removeObject:key];
        NSUInteger index = NSNotFound;
        for (NSUInteger i = 0; i < self.selectedAssets.count; i++) {
            if ([[self keyForAsset:[self.selectedAssets objectAtIndex:i]] isEqualToString:key]) {
                index = i;
                break;
            }
        }
        if (index != NSNotFound) {
            [self.selectedAssets removeObjectAtIndex:index];
        }
        [self refreshToolbar];
        return YES;
    }

    if (self.selectedAssets.count >= self.maximumSelectionCount) {
        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:@"Too Many Attachments"
                  message:[NSString stringWithFormat:@"You can select up to %lu attachments per message.",
                                                     (unsigned long)self.maximumSelectionCount]
                 delegate:nil
        cancelButtonTitle:@"OK"
        otherButtonTitles:nil];
        [alert show];
        return NO;
    }

    [self.selectedAssets addObject:asset];
    [self.selectedAssetKeys addObject:key];
    [self refreshToolbar];
    return YES;
}

- (void)removeSelectedAssetAtIndex:(NSUInteger)index {
    if (index >= self.selectedAssets.count) return;

    ALAsset *asset = [self.selectedAssets objectAtIndex:index];
    [self.selectedAssetKeys removeObject:[self keyForAsset:asset]];
    [self.selectedAssets removeObjectAtIndex:index];
    [self refreshToolbar];
}

- (unsigned long long)selectedAssetByteCount {
    unsigned long long total = 0;
    for (ALAsset *asset in self.selectedAssets) {
        ALAssetRepresentation *representation = [asset defaultRepresentation];
        if (representation && representation.size > 0) {
            total += (unsigned long long)representation.size;
        }
    }
    return total;
}

- (void)installNavigationItemsForViewController:(UIViewController *)viewController {
    BOOL orderingAttachments =
        [viewController isKindOfClass:[DCMultiAttachmentOrderController class]];

    UIBarButtonItem *cancelItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(cancelPressed:)];
    viewController.navigationItem.rightBarButtonItem = cancelItem;

    UIView *summaryView = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 150.0f, 40.0f)];
    summaryView.backgroundColor = [UIColor clearColor];
    summaryView.hidden = self.selectedAssets.count == 0;

    UILabel *countLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, 2.0f, 150.0f, 19.0f)];
    countLabel.backgroundColor = [UIColor clearColor];
    countLabel.textColor = [UIColor whiteColor];
    countLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    countLabel.textAlignment = UITextAlignmentCenter;
    countLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.7f];
    countLabel.shadowOffset = CGSizeMake(0.0f, -1.0f);
    countLabel.text = [NSString stringWithFormat:@"%lu of %lu selected",
                       (unsigned long)self.selectedAssets.count,
                       (unsigned long)self.maximumSelectionCount];
    [summaryView addSubview:countLabel];

    UILabel *sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, 20.0f, 150.0f, 16.0f)];
    sizeLabel.backgroundColor = [UIColor clearColor];
    sizeLabel.textColor = [UIColor colorWithWhite:0.72f alpha:1.0f];
    sizeLabel.font = [UIFont systemFontOfSize:10.0f];
    sizeLabel.textAlignment = UITextAlignmentCenter;
    sizeLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
    sizeLabel.shadowOffset = CGSizeMake(0.0f, -1.0f);
    unsigned long long selectedBytes = [self selectedAssetByteCount];
    sizeLabel.text = self.selectedAssets.count > 0
        ? [NSString stringWithFormat:@"%@ total", DCFormattedAttachmentByteCount(selectedBytes)]
        : @"";
    [summaryView addSubview:sizeLabel];

    UIBarButtonItem *leftFlex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil
                             action:nil];
    UIBarButtonItem *summary = [[UIBarButtonItem alloc] initWithCustomView:summaryView];
    UIBarButtonItem *rightFlex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil
                             action:nil];

    if (orderingAttachments) {
        UIBarButtonItem *doneItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                 target:self
                                 action:@selector(donePressed:)];
        doneItem.enabled = YES;
        viewController.toolbarItems = @[ leftFlex, summary, rightFlex, doneItem ];
    } else {
        UIBarButtonItem *deselectItem = [[UIBarButtonItem alloc] initWithTitle:@"Deselect"
                                                                        style:UIBarButtonItemStyleBordered
                                                                       target:self
                                                                       action:@selector(deselectPressed:)];
        deselectItem.enabled = self.selectedAssets.count > 0;

        UIBarButtonItem *nextItem = [[UIBarButtonItem alloc] initWithTitle:@"Next"
                                                                     style:UIBarButtonItemStyleDone
                                                                    target:self
                                                                    action:@selector(nextPressed:)];
        nextItem.enabled = self.selectedAssets.count > 0;

        viewController.toolbarItems = @[ deselectItem, leftFlex, summary, rightFlex, nextItem ];
    }
    [self.toolbar setItems:viewController.toolbarItems animated:NO];
    [self ensureToolbarVisible];
}

- (void)refreshToolbar {
    UIViewController *top = self.topViewController;
    if (top) [self installNavigationItemsForViewController:top];
}

- (void)cancelPressed:(id)sender {
    if ([self.pickerDelegate respondsToSelector:@selector(multiAttachmentPickerControllerDidCancel:)]) {
        [self.pickerDelegate multiAttachmentPickerControllerDidCancel:self];
    }
}

- (void)nextPressed:(id)sender {
    if (self.selectedAssets.count == 0 ||
        [self.topViewController isKindOfClass:[DCMultiAttachmentOrderController class]]) {
        return;
    }

    DCMultiAttachmentOrderController *orderController =
        [[DCMultiAttachmentOrderController alloc] initWithStyle:UITableViewStylePlain];
    orderController.pickerController = self;
    [self pushViewController:orderController animated:YES];
}

- (void)deselectPressed:(id)sender {
    if (self.selectedAssets.count == 0) return;

    [self.selectedAssets removeAllObjects];
    [self.selectedAssetKeys removeAllObjects];
    [self refreshToolbar];

    UIViewController *top = self.topViewController;
    if ([top isKindOfClass:[UITableViewController class]]) {
        [[(UITableViewController *)top tableView] reloadData];
    }
}

- (void)donePressed:(id)sender {
    if ([self.pickerDelegate respondsToSelector:@selector(multiAttachmentPickerController:didFinishWithAssets:)]) {
        [self.pickerDelegate multiAttachmentPickerController:self
                                        didFinishWithAssets:[NSArray arrayWithArray:self.selectedAssets]];
    }
}

@end

@implementation DCMultiAttachmentOrderController

- (id)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:style];
    if (!self) return nil;
    self.title = @"Order Attachments";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 64.0f;
    self.tableView.backgroundColor = [UIColor whiteColor];
    self.tableView.allowsSelection = NO;
    [self setEditing:YES animated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.pickerController installNavigationItemsForViewController:self];
    [self.tableView reloadData];
    [self setEditing:YES animated:NO];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.pickerController.selectedAssets.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"DCMultiAttachmentOrderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.showsReorderControl = YES;
    }

    ALAsset *asset = [self.pickerController.selectedAssets objectAtIndex:indexPath.row];
    ALAssetRepresentation *representation = [asset defaultRepresentation];
    NSString *filename = [representation filename];
    if (!filename.length) {
        filename = [NSString stringWithFormat:@"Attachment %ld", (long)indexPath.row + 1];
    }

    cell.textLabel.text = filename;
    CGImageRef thumbnail = [asset thumbnail];
    cell.imageView.image = thumbnail ? [UIImage imageWithCGImage:thumbnail] : nil;
    cell.showsReorderControl = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= self.pickerController.selectedAssets.count) return;

    [self.pickerController removeSelectedAssetAtIndex:indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) return;

    ALAsset *asset = [self.pickerController.selectedAssets objectAtIndex:sourceIndexPath.row];
    [self.pickerController.selectedAssets removeObjectAtIndex:sourceIndexPath.row];
    [self.pickerController.selectedAssets insertObject:asset atIndex:destinationIndexPath.row];
}

@end

@implementation DCMultiAttachmentAlbumListController

- (id)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:style];
    if (!self) return nil;
    _assetGroups = [NSMutableArray array];
    self.title = @"Photos";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 58.0f;
    self.tableView.backgroundColor = [UIColor whiteColor];
    [self loadAssetGroups];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.pickerController installNavigationItemsForViewController:self];
    [self.tableView reloadData];
}

- (void)loadAssetGroups {
    [self.assetGroups removeAllObjects];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [spinner startAnimating];
    self.tableView.backgroundView = spinner;

    __weak DCMultiAttachmentAlbumListController *weakSelf = self;
    NSMutableArray *loadedGroups = [NSMutableArray array];
    [self.pickerController.assetLibrary
        enumerateGroupsWithTypes:(ALAssetsGroupAll | ALAssetsGroupLibrary)
        usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
            if (group) {
                [group setAssetsFilter:[ALAssetsFilter allAssets]];
                if ([group numberOfAssets] > 0) {
                    [loadedGroups insertObject:group atIndex:0];
                }
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                DCMultiAttachmentAlbumListController *strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.assetGroups = loadedGroups;
                strongSelf.tableView.backgroundView = nil;
                [strongSelf.tableView reloadData];
            });
        }
        failureBlock:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DCMultiAttachmentAlbumListController *strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.tableView.backgroundView = nil;

                UIAlertView *alert = [[UIAlertView alloc]
                    initWithTitle:@"Photos Unavailable"
                          message:error.localizedDescription ?: @"Discord Classic could not access your photo library."
                         delegate:nil
                cancelButtonTitle:@"OK"
                otherButtonTitles:nil];
                [alert show];
            });
        }];

}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.assetGroups.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"DCMultiAttachmentAlbumCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
    }

    ALAssetsGroup *group = [self.assetGroups objectAtIndex:indexPath.row];
    NSString *name = [group valueForProperty:ALAssetsGroupPropertyName];
    cell.textLabel.text = name.length ? name : @"Album";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)[group numberOfAssets]];
    CGImageRef posterImage = [group posterImage];
    cell.imageView.image = posterImage ? [UIImage imageWithCGImage:posterImage] : nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ALAssetsGroup *group = [self.assetGroups objectAtIndex:indexPath.row];
    DCMultiAttachmentAssetGridController *grid =
        [[DCMultiAttachmentAssetGridController alloc] initWithAssetGroup:group];
    grid.pickerController = self.pickerController;
    [self.navigationController pushViewController:grid animated:YES];
}

@end

@implementation DCMultiAttachmentAssetGridController

- (id)initWithAssetGroup:(ALAssetsGroup *)assetGroup {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self) return nil;
    _assetGroup = assetGroup;
    _assets = [NSMutableArray array];
    _lastLayoutWidth = 0.0f;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor whiteColor];
    self.tableView.allowsSelection = NO;
    self.title = [self.assetGroup valueForProperty:ALAssetsGroupPropertyName] ?: @"Photos";
    [self loadAssets];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.pickerController installNavigationItemsForViewController:self];
    [self.tableView reloadData];
}

- (NSUInteger)columnCount {
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0.0f) width = self.view.bounds.size.width;

    CGFloat spacing = 4.0f;
    CGFloat targetSide = 75.0f;
    NSUInteger columns = (NSUInteger)floorf((width - spacing) / (targetSide + spacing));
    if (columns < 4) columns = 4;
    if (columns > 7) columns = 7;
    return columns;
}

- (CGFloat)thumbnailSide {
    NSUInteger columns = [self columnCount];
    CGFloat spacing = 4.0f;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0.0f) width = self.view.bounds.size.width;
    return floorf((width - spacing * (columns + 1)) / columns);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = self.tableView.bounds.size.width;
    if (fabs(width - self.lastLayoutWidth) > 0.5f) {
        self.lastLayoutWidth = width;
        [self.tableView reloadData];
    }
}

- (void)loadAssets {
    [self.assets removeAllObjects];
    [self.assetGroup setAssetsFilter:[ALAssetsFilter allAssets]];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [spinner startAnimating];
    self.tableView.backgroundView = spinner;

    __weak DCMultiAttachmentAssetGridController *weakSelf = self;
    NSMutableArray *loadedAssets = [NSMutableArray array];
    [self.assetGroup enumerateAssetsUsingBlock:^(ALAsset *asset, NSUInteger index, BOOL *stop) {
        if (asset) {
            [loadedAssets addObject:asset];
            return;
        }

        DCMultiAttachmentAssetGridController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.assets = loadedAssets;
        strongSelf.tableView.backgroundView = nil;
        [strongSelf.tableView reloadData];

        NSInteger rowCount = [strongSelf.tableView numberOfRowsInSection:0];
        if (rowCount > 0) {
            NSIndexPath *lastRow = [NSIndexPath indexPathForRow:rowCount - 1 inSection:0];
            [strongSelf.tableView scrollToRowAtIndexPath:lastRow
                                         atScrollPosition:UITableViewScrollPositionBottom
                                                 animated:NO];
        }
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSUInteger columns = [self columnCount];
    return (self.assets.count + columns - 1) / columns;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self thumbnailSide] + 4.0f;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"DCMultiAttachmentAssetCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor whiteColor];
        cell.contentView.backgroundColor = [UIColor whiteColor];

        for (NSUInteger i = 0; i < 7; i++) {
            DCMultiAttachmentAssetButton *button = [DCMultiAttachmentAssetButton buttonWithType:UIButtonTypeCustom];
            button.tag = 100 + i;
            button.clipsToBounds = YES;
            button.imageView.contentMode = UIViewContentModeScaleAspectFill;
            [button addTarget:self
                       action:@selector(assetButtonTapped:)
             forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:button];

            UILabel *videoBadge = [[UILabel alloc] initWithFrame:CGRectZero];
            videoBadge.tag = 200 + i;
            videoBadge.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.55f];
            videoBadge.textColor = [UIColor whiteColor];
            videoBadge.font = [UIFont boldSystemFontOfSize:10.0f];
            videoBadge.textAlignment = UITextAlignmentCenter;
            videoBadge.hidden = YES;
            [button addSubview:videoBadge];

            UIImageView *checkmark = [[UIImageView alloc] initWithImage:DCMultiAttachmentNativeSelectionBadgeImage()];
            checkmark.tag = 300 + i;
            checkmark.contentMode = UIViewContentModeCenter;
            checkmark.hidden = YES;
            [button addSubview:checkmark];
        }
    }

    NSUInteger columns = [self columnCount];
    CGFloat spacing = 4.0f;
    CGFloat side = [self thumbnailSide];
    NSUInteger firstIndex = indexPath.row * columns;

    for (NSUInteger i = 0; i < 7; i++) {
        DCMultiAttachmentAssetButton *button = (DCMultiAttachmentAssetButton *)[cell.contentView viewWithTag:100 + i];
        if (i >= columns || firstIndex + i >= self.assets.count) {
            button.hidden = YES;
            continue;
        }

        button.hidden = NO;
        button.frame = CGRectMake(spacing + i * (side + spacing), 2.0f, side, side);
        button.assetIndex = firstIndex + i;

        ALAsset *asset = [self.assets objectAtIndex:firstIndex + i];
        CGImageRef thumbnailRef = [asset thumbnail];
        [button setImage:thumbnailRef ? [UIImage imageWithCGImage:thumbnailRef] : nil
                forState:UIControlStateNormal];

        UILabel *videoBadge = (UILabel *)[button viewWithTag:200 + i];
        UIImageView *checkmark = (UIImageView *)[button viewWithTag:300 + i];

        NSString *type = [asset valueForProperty:ALAssetPropertyType];
        BOOL isVideo = [type isEqualToString:ALAssetTypeVideo];
        videoBadge.hidden = !isVideo;
        if (isVideo) {
            NSTimeInterval duration = [[asset valueForProperty:ALAssetPropertyDuration] doubleValue];
            NSUInteger totalSeconds = (NSUInteger)round(duration);
            videoBadge.text = [NSString stringWithFormat:@"▶ %lu:%02lu",
                               (unsigned long)(totalSeconds / 60),
                               (unsigned long)(totalSeconds % 60)];
            videoBadge.frame = CGRectMake(0.0f, side - 18.0f, side, 18.0f);
        }

        checkmark.hidden = ![self.pickerController isAssetSelected:asset];
        checkmark.frame = CGRectMake(side - 31.0f, 2.0f, 29.0f, 29.0f);
    }

    return cell;
}

- (void)assetButtonTapped:(DCMultiAttachmentAssetButton *)sender {
    NSUInteger index = sender.assetIndex;
    if (index >= self.assets.count) return;

    ALAsset *asset = [self.assets objectAtIndex:index];
    if ([self.pickerController toggleAssetSelection:asset]) {
        [self.tableView reloadData];
    }
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                         duration:(NSTimeInterval)duration {
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.tableView reloadData];
}

@end
