//
//  DCSettingsViewController.m
//  Discord Classic
//
//  Created by Trevir on 3/18/18.
//  Copyright (c) 2018 bag.xml. All rights reserved.
//

#import "DCSettingsViewController.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"

@implementation DCSettingsViewController


- (void)viewDidLoad {
    [super viewDidLoad];
    self.experimentalToggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"experimentalMode"];
    self.dataSaverToggle.on    = [[NSUserDefaults standardUserDefaults] boolForKey:@"dataSaver"];

    NSString *token =
        [NSUserDefaults.standardUserDefaults stringForKey:@"token"];

    // Show current token in text field if one has previously been entered
    if (token) {
        [self.tokenInputField setText:token];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [NSUserDefaults.standardUserDefaults setObject:self.tokenInputField.text
                                            forKey:@"token"];

    // Save the entered values and reauthenticate if the token has been changed
    if (![DCServerCommunicator.sharedInstance.token
            isEqual:[NSUserDefaults.standardUserDefaults
                        objectForKey:@"token"]]) {
        DCServerCommunicator.sharedInstance.token = self.tokenInputField.text;
        [DCServerCommunicator.sharedInstance reconnect];
    }
}

- (IBAction)openTutorial:(id)sender {
    // Link to video describing how to enter your token
    [UIApplication.sharedApplication
        openURL:[NSURL URLWithString:
                           @"https://www.youtube.com/watch?v=NWB3fGafJwk"]];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 1 && indexPath.section == 1) {
        [DCTools joinGuild:@"9WjXhTPyRf"];
        [self performSegueWithIdentifier:@"Settings to Test Channel"
                                  sender:self];
    }
}

- (IBAction)experimentalSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"experimentalMode"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:@"Restart Required"
              message:@"Toggling Experimental Mode requires an app restart. Would you like to restart now?"
             delegate:self
    cancelButtonTitle:@"No"
    otherButtonTitles:@"Yes", nil];
    [alert show];
}

- (IBAction)dataSaverSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"dataSaver"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:@"Restart Required"
              message:@"Toggling Data Saver Mode requires an app restart. Would you like to restart now?"
             delegate:self
    cancelButtonTitle:@"No"
    otherButtonTitles:@"Yes", nil];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 1) {
        exit(0);
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"Settings to Test Channel"]) {
        DCChatViewController *chatViewController =
            [segue destinationViewController];

        if ([chatViewController isKindOfClass:DCChatViewController.class]) {
            DCServerCommunicator.sharedInstance.selectedChannel =
                [DCServerCommunicator.sharedInstance.channels
                    objectForKey:@"1184464173795651594"];

            // Initialize messages
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"NUKE CHAT DATA"
                              object:nil];

            [chatViewController.navigationItem
                setTitle:@"Discord Classic #general"];

            // Populate the message view with the last 50 messages
            // dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH,
            // 0), ^{
            [chatViewController getMessages:50 beforeMessage:nil];
            //});

            // Chat view is watching the present conversation (auto scroll with
            // new messages)
            [chatViewController setViewingPresentTime:YES];
        }
    }
}

@end
