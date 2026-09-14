//
//  DCMultiAttachmentPickerController.h
//  Discord Classic
//
//  Created by Ayeris on 9/13/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import <AssetsLibrary/AssetsLibrary.h>
#import <UIKit/UIKit.h>

@class DCMultiAttachmentPickerController;

@protocol DCMultiAttachmentPickerControllerDelegate <NSObject>
- (void)multiAttachmentPickerController:(DCMultiAttachmentPickerController *)picker
                    didFinishWithAssets:(NSArray *)assets;
- (void)multiAttachmentPickerControllerDidCancel:(DCMultiAttachmentPickerController *)picker;
@end

@interface DCMultiAttachmentPickerController : UINavigationController

- (id)initWithSelectedAssets:(NSArray *)assets;
- (id)initWithSelectedAssets:(NSArray *)assets
                  assetLibrary:(ALAssetsLibrary *)assetLibrary;

@property (nonatomic, assign) id<DCMultiAttachmentPickerControllerDelegate> pickerDelegate;
@property (nonatomic, assign) NSUInteger maximumSelectionCount;

@end
