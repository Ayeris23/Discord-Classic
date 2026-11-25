//
//  DCThreadCreateViewController.m
//  Discord Classic
//
//  Created by Ayeris on 11/23/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCThreadCreateViewController.h"
#import "DCChannel.h"
#import "DCChatLookupView.h"
#import "DCChatComposer.h"
#import "DCUser.h"
#import "DCGuild.h"
#import "DCInterfaceStyle.h"
#import "DCServerCommunicator.h"
#import "DCTools.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static UIColor *DCThreadCreateBackground(void) {
    return [UIColor colorWithRed:40.0f / 255.0f green:41.0f / 255.0f
                            blue:46.0f / 255.0f alpha:1.0f];
}

static UIColor *DCThreadCreateAlternateBackground(void) {
    return [UIColor colorWithRed:33.0f / 255.0f green:34.0f / 255.0f
                            blue:38.0f / 255.0f alpha:1.0f];
}

static NSString *DCThreadTrimmedString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return @"";
    return [string stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@interface DCThreadTitleTextField : UITextField
@end

@implementation DCThreadTitleTextField

- (void)drawPlaceholderInRect:(CGRect)rect {
    NSString *placeholder = self.placeholder;
    if (!placeholder.length) return;

    UIFont *font = self.font ?: [UIFont systemFontOfSize:16.0f];
    CGSize size = [placeholder sizeWithFont:font];
    CGRect textRect = CGRectMake(floorf(rect.origin.x),
        floorf(rect.origin.y + (rect.size.height - size.height) * 0.5f),
        floorf(rect.size.width), ceilf(size.height));

    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0.0f, 1.0f), 0.0f,
        [UIColor colorWithWhite:0.0f alpha:0.74f].CGColor);
    [[UIColor colorWithRed:128.0f / 255.0f green:132.0f / 255.0f
                          blue:143.0f / 255.0f alpha:1.0f] set];
    [placeholder drawInRect:textRect withFont:font
              lineBreakMode:UILineBreakModeTailTruncation
                  alignment:UITextAlignmentLeft];
    CGContextRestoreGState(context);
}

@end

static void DCThreadAddCellSeparator(UIView *container, BOOL atTop) {
    const CGFloat height = CGRectGetHeight(container.bounds);
    const CGFloat y = atTop ? 0.0f : MAX(0.0f, height - 2.0f);
    UIColor *colors[2] = {
        [UIColor colorWithRed:31.0f / 255.0f green:32.0f / 255.0f
                        blue:36.0f / 255.0f alpha:1.0f],
        [UIColor colorWithRed:48.0f / 255.0f green:49.0f / 255.0f
                        blue:56.0f / 255.0f alpha:1.0f]
    };
    for (NSUInteger i = 0; i < 2; i++) {
        UIView *line = [[UIView alloc] initWithFrame:
            CGRectMake(0.0f, y + (CGFloat)i, CGRectGetWidth(container.bounds), 1.0f)];
        line.backgroundColor = colors[i];
        line.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            (atTop ? UIViewAutoresizingFlexibleBottomMargin : UIViewAutoresizingFlexibleTopMargin);
        [container addSubview:line];
    }
}

@interface DCThreadCreateViewController () <UITableViewDataSource, UITableViewDelegate,
    UITextFieldDelegate, UITextViewDelegate, DCChatLookupViewDelegate>
@property (nonatomic, strong) DCChannel *parentChannel;
@property (nonatomic, strong) UITableView *formTable;
@property (nonatomic, strong) UITextField *titleField;
@property (nonatomic, strong) UILabel *nameWarning;
@property (nonatomic, strong) UILabel *warningSymbol;
@property (nonatomic, strong) UISwitch *privateSwitch;
@property (nonatomic, strong) UILabel *privateDescription;
@property (nonatomic, strong) UIView *composerBar;
@property (nonatomic, strong) DCChatComposer *chatComposer;
@property (nonatomic, strong) DCChatLookupView *mentionLookup;
@property (nonatomic, strong) UIView *lookupDimming;
@property (nonatomic, strong) NSArray *lookupCandidates;
@property (nonatomic, copy) NSString *lookupQuery;
@property (nonatomic, copy) NSString *lookupNonce;
@property (nonatomic, assign) NSRange lookupToken;
@property (nonatomic, assign) BOOL lookupVisible;
@property (nonatomic, assign) NSUInteger lookupSequence;
@property (nonatomic, strong) UITextView *messageField;
@property (nonatomic, strong) UILabel *messagePlaceholder;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIActivityIndicatorView *sendingSpinner;
@property (nonatomic, assign) BOOL privateThread;
@property (nonatomic, assign) BOOL allowPublic;
@property (nonatomic, assign) BOOL allowPrivate;
@property (nonatomic, assign) BOOL creating;
@property (nonatomic, assign) BOOL showingNameWarning;
@property (nonatomic, assign) BOOL didFocusTitle;
@property (nonatomic, assign) BOOL leavingScreen;
@property (nonatomic, assign) BOOL needsInitialKeyboardLayout;
@property (nonatomic, assign) CGFloat keyboardOverlap;
- (void)submitThread:(id)sender;
- (void)updatePrivateRow;
- (void)privateSwitchChanged:(UISwitch *)sender;
- (void)updateComposerFrames;
- (void)focusTitleIfNeeded;
- (void)showNameWarning:(BOOL)visible;
- (void)updateMentionLookup;
- (void)hideMentionLookup;
- (void)hideMentionLookupAnimated:(BOOL)animated;
- (CGRect)mentionLookupVisibleFrame;
- (void)refreshMentionLookupFrame;
- (void)searchMentionGuild;
- (void)mentionSearchReceived:(NSNotification *)notification;
@end

@implementation DCThreadCreateViewController

- (id)initWithParentChannel:(DCChannel *)channel {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _parentChannel = channel;
        uint64_t permissions = [DCServerCommunicator.sharedInstance
            effectivePermissionsForChannel:channel];
        _allowPublic = (permissions & DCPermissionViewChannel) != 0 &&
            (permissions & DCPermissionCreatePublicThreads) != 0;
        _allowPrivate = (permissions & DCPermissionViewChannel) != 0 &&
            (permissions & DCPermissionCreatePrivateThreads) != 0;
        _privateThread = !_allowPublic && _allowPrivate;
    }
    return self;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = DCThreadCreateBackground();
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"New Thread";

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero
                                                      style:UITableViewStylePlain];
    table.backgroundColor = DCThreadCreateBackground();
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.dataSource = self;
    table.delegate = self;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 46.0f)];
    footer.backgroundColor = [UIColor clearColor];
    UILabel *description = [[UILabel alloc] initWithFrame:CGRectZero];
    description.backgroundColor = [UIColor clearColor];
    description.font = [UIFont systemFontOfSize:14.0f];
    description.textColor = [UIColor colorWithWhite:128.0f / 255.0f alpha:1.0f];
    description.shadowColor = [UIColor blackColor];
    description.shadowOffset = CGSizeMake(0.0f, 1.0f);
    description.textAlignment = UITextAlignmentCenter;
    description.lineBreakMode = UILineBreakModeWordWrap;
    description.numberOfLines = 0;
    description.text = @"Only invited members and moderators can see it";
    [footer addSubview:description];
    table.tableFooterView = footer;
    self.privateDescription = description;
    table.alwaysBounceVertical = NO;
    [self.view addSubview:table];
    self.formTable = table;
    self.lookupToken = NSMakeRange(NSNotFound, 0);

    DCChatComposer *composer = [[DCChatComposer alloc] initWithFrame:
        CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 44.0f)];
    composer.showsPhotoButton = NO;
    composer.placeholderLabel.text = @"Start the conversation!";
    composer.textView.delegate = self;
    [composer.sendButton addTarget:self action:@selector(submitThread:)
                   forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:composer.view];
    self.chatComposer = composer;
    self.composerBar = composer.view;
    self.messageField = composer.textView;
    self.messagePlaceholder = composer.placeholderLabel;
    self.sendButton = composer.sendButton;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    spinner.hidesWhenStopped = YES;
    [composer.view addSubview:spinner];
    self.sendingSpinner = spinner;

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardFrameChanged:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardFrameChanged:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(mentionSearchReceived:)
        name:@"DCChatLookupGuildMembersReceived" object:nil];

    [self.formTable reloadData];
    [self updateComposerFrames];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.leavingScreen) [self updateComposerFrames];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.leavingScreen = NO;
    self.needsInitialKeyboardLayout = YES;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        [self updateComposerFrames];
        [self focusTitleIfNeeded];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self focusTitleIfNeeded];
}

- (void)focusTitleIfNeeded {
    if (self.didFocusTitle || self.creating) return;
    [self.formTable layoutIfNeeded];
    if (self.titleField) {
        self.didFocusTitle = [self.titleField becomeFirstResponder];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    self.leavingScreen = YES;
    [self hideMentionLookupAnimated:NO];
    [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.keyboardOverlap = 0.0f;
    self.didFocusTitle = NO;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)keyboardFrameChanged:(NSNotification *)notification {
    if (self.leavingScreen) return;
    BOOL hiding = [notification.name isEqualToString:UIKeyboardWillHideNotification];
    CGFloat overlap = 0.0f;
    NSValue *frameValue = [notification.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey];
    if (!hiding && frameValue) {
        CGRect frame = [self.view convertRect:[frameValue CGRectValue] fromView:nil];
        if (CGRectIntersectsRect(self.view.bounds, frame)) {
            overlap = MAX(0.0f, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(frame));
        }
    }
    if (fabs(self.keyboardOverlap - overlap) < 0.5f) return;
    self.keyboardOverlap = overlap;

    // The incoming controller slides horizontally with the navigation push.
    // Position its composer before drawing instead of animating it vertically.
    if (!hiding && self.needsInitialKeyboardLayout &&
        UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        self.needsInitialKeyboardLayout = NO;
        BOOL animationsEnabled = [UIView areAnimationsEnabled];
        [UIView setAnimationsEnabled:NO];
        [self updateComposerFrames];
        [UIView setAnimationsEnabled:animationsEnabled];
        return;
    }

    // While visible, follow UIKit's keyboard timing and curve.
    NSTimeInterval duration = [[notification.userInfo
        objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        (UIViewAnimationOptions)([[notification.userInfo
            objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16);
    [UIView animateWithDuration:duration delay:0.0f options:options animations:^{
        [self updateComposerFrames];
    } completion:nil];
}

- (void)updateComposerFrames {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    if (fabs(CGRectGetWidth(self.composerBar.bounds) - width) > 0.5f) {
        CGRect frame = self.composerBar.frame;
        frame.size.width = width;
        self.composerBar.frame = frame;
        [self.chatComposer layoutStandaloneContents];
    }
    CGFloat barHeight = [self.chatComposer preferredHeightWithMaximumLines:
        (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? 10 : 5)];
    CGFloat barTop = floorf(MAX(0.0f, height - self.keyboardOverlap - barHeight));
    self.formTable.frame = CGRectMake(0, 0, width, barTop);
    UIView *footer = self.formTable.tableFooterView;
    if (footer && self.privateDescription) {
        const CGFloat inset = 11.0f;
        CGFloat labelWidth = floorf(MAX(0.0f, CGRectGetWidth(self.formTable.bounds) - 2.0f * inset));
        CGSize textSize = [self.privateDescription.text sizeWithFont:self.privateDescription.font
            constrainedToSize:CGSizeMake(labelWidth, CGFLOAT_MAX)
                lineBreakMode:UILineBreakModeWordWrap];
        CGFloat footerHeight = MAX(46.0f, ceilf(textSize.height) + 10.0f);
        if (fabs(CGRectGetWidth(footer.bounds) - width) > 0.5f ||
            fabs(CGRectGetHeight(footer.bounds) - footerHeight) > 0.5f) {
            footer.frame = CGRectMake(0.0f, 0.0f, width, footerHeight);
            self.formTable.tableFooterView = footer;
        }
        self.privateDescription.frame = CGRectMake(inset, 1.0f,
            labelWidth, footerHeight - 4.0f);
    }
    self.composerBar.frame = CGRectMake(0, barTop, width, barHeight);
    [self.chatComposer layoutStandaloneContents];
    self.sendingSpinner.center = self.sendButton.center;
    [self refreshMentionLookupFrame];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 2; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.row == 0 ? (self.showingNameWarning ? 77.0f : 58.0f) : 44.0f;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.row == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ThreadName"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"ThreadName"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundView = [[UIView alloc] initWithFrame:cell.bounds];
            cell.backgroundView.backgroundColor = DCThreadCreateBackground();
            UITextField *field = [[DCThreadTitleTextField alloc] initWithFrame:CGRectZero];
            field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            field.backgroundColor = [UIColor clearColor];
            field.background = [DCInterfaceStyle threadTitleFieldBackgroundImage];
            field.textColor = [UIColor whiteColor];
            field.font = [UIFont systemFontOfSize:16.0f];
            field.placeholder = @"Thread title";
            field.textAlignment = UITextAlignmentLeft;
            field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
            field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10.0f, 34.0f)];
            field.leftViewMode = UITextFieldViewModeAlways;
            field.keyboardAppearance = UIKeyboardAppearanceAlert;
            field.returnKeyType = UIReturnKeyNext;
            field.delegate = self;
            [field addTarget:self action:@selector(titleTextChanged:)
                forControlEvents:UIControlEventEditingChanged];
            [cell.contentView addSubview:field];
            self.titleField = field;

            UILabel *symbol = [[UILabel alloc] initWithFrame:CGRectMake(16, 53, 16, 16)];
            symbol.backgroundColor = [UIColor colorWithRed:0.95f green:0.38f blue:0.36f alpha:1.0f];
            symbol.text = @"!";
            symbol.font = [UIFont boldSystemFontOfSize:12.0f];
            symbol.textAlignment = UITextAlignmentCenter;
            symbol.textColor = [UIColor whiteColor];
            symbol.layer.cornerRadius = 8.0f;
            symbol.layer.masksToBounds = YES;
            symbol.hidden = YES;
            [cell.contentView addSubview:symbol];
            self.warningSymbol = symbol;

            UILabel *warning = [[UILabel alloc] initWithFrame:CGRectZero];
            warning.backgroundColor = [UIColor clearColor];
            warning.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            warning.text = @"Thread Name is required";
            warning.font = [UIFont systemFontOfSize:13.0f];
            warning.textColor = [UIColor colorWithRed:1.0f green:0.54f blue:0.50f alpha:1.0f];
            warning.hidden = YES;
            [cell.contentView addSubview:warning];
            self.nameWarning = warning;
        }
        CGFloat width = CGRectGetWidth(tableView.bounds);
        self.titleField.frame = CGRectMake(16, 12, MAX(0, width - 32), 34);
        self.nameWarning.frame = CGRectMake(38, 51, MAX(0, width - 54), 21);
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ThreadPrivate"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"ThreadPrivate"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *privateBackground = [[UIView alloc] initWithFrame:cell.bounds];
        privateBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        privateBackground.backgroundColor = DCThreadCreateAlternateBackground();
        DCThreadAddCellSeparator(privateBackground, YES);
        DCThreadAddCellSeparator(privateBackground, NO);
        cell.backgroundView = privateBackground;
        cell.textLabel.text = @"Private Thread";
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0f];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.shadowColor = [UIColor blackColor];
        cell.textLabel.shadowOffset = CGSizeMake(0.0f, 1.0f);

        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.onTintColor = [UIColor colorWithRed:114.0f / 255.0f
                                             green:137.0f / 255.0f
                                              blue:218.0f / 255.0f alpha:1.0f];
        [toggle addTarget:self action:@selector(privateSwitchChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        self.privateSwitch = toggle;
    }
    [self updatePrivateRow];
    return cell;
}

- (void)updatePrivateRow {
    BOOL canToggle = self.allowPublic && self.allowPrivate && !self.creating;
    self.privateSwitch.enabled = canToggle;
    [self.privateSwitch setOn:self.privateThread animated:NO];
    self.privateDescription.textColor =
        [UIColor colorWithWhite:128.0f / 255.0f alpha:1.0f];
}

- (void)privateSwitchChanged:(UISwitch *)sender {
    if (!self.allowPublic || !self.allowPrivate || self.creating) {
        [sender setOn:self.privateThread animated:YES];
        return;
    }
    self.privateThread = sender.on;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.row != 1 || !self.allowPublic || !self.allowPrivate || self.creating) return;
    self.privateThread = !self.privateThread;
    [self.privateSwitch setOn:self.privateThread animated:YES];
}

- (void)titleTextChanged:(UITextField *)field {
    if (DCThreadTrimmedString(field.text).length) [self showNameWarning:NO];
}

- (void)showNameWarning:(BOOL)visible {
    if (self.showingNameWarning == visible) return;
    self.showingNameWarning = visible;
    self.nameWarning.hidden = !visible;
    self.warningSymbol.hidden = !visible;
    [self.formTable beginUpdates];
    [self.formTable endUpdates];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self.messageField becomeFirstResponder];
    return NO;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string {
    return textField.text.length - range.length + string.length <= 100;
}

- (void)textViewDidChange:(UITextView *)textView {
    [self.chatComposer updatePlaceholder];
    [self updateComposerFrames];
    [self updateMentionLookup];
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    [self hideMentionLookup];
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range
replacementText:(NSString *)text {
    return textView.text.length - range.length + text.length <= 2000;
}

#pragma mark - Composer mentions

- (NSArray *)mentionCandidates {
    DCGuild *guild = self.parentChannel.parentGuild;
    NSDictionary *memberItems = nil;
    NSArray *legacy = nil;
    @synchronized (guild) {
        memberItems = [guild.memberListItems copy];
        legacy = [guild.members copy];
    }
    NSMutableArray *users = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *positions = [[memberItems allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *raw = [NSMutableArray arrayWithCapacity:positions.count + legacy.count];
    for (NSNumber *position in positions) {
        id user = [memberItems objectForKey:position];
        if (user) [raw addObject:user];
    }
    if (legacy.count) [raw addObjectsFromArray:legacy];
    for (id object in raw) {
        if (![object isKindOfClass:[DCUser class]]) continue;
        DCUser *user = object;
        if (!user.snowflake.length || [seen containsObject:user.snowflake]) continue;
        [seen addObject:user.snowflake];
        [users addObject:user];
    }
    return users;
}

- (void)ensureMentionLookup {
    if (self.mentionLookup) return;
    UIView *dimming = [[UIView alloc] initWithFrame:self.formTable.frame];
    dimming.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.40f];
    dimming.alpha = 0.0f;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissMentionLookup:)];
    [dimming addGestureRecognizer:tap];
    self.lookupDimming = dimming;
    DCChatLookupView *lookup = [[DCChatLookupView alloc] initWithFrame:CGRectZero];
    lookup.delegate = self;
    self.mentionLookup = lookup;
}

- (CGRect)mentionLookupVisibleFrame {
    CGFloat bottom = CGRectGetMinY(self.composerBar.frame);
    CGFloat available = MAX(0.0f, bottom);
    CGFloat rows = MIN((NSUInteger)10, MAX((NSUInteger)1, self.mentionLookup.resultCount));
    CGFloat height = MIN(available, 44.0f * rows);
    return CGRectMake(0.0f, floorf(bottom - height),
                      CGRectGetWidth(self.view.bounds), ceilf(height));
}

- (void)refreshMentionLookupFrame {
    if (!self.lookupVisible) return;
    self.lookupDimming.frame = self.formTable.frame;
    self.mentionLookup.frame = [self mentionLookupVisibleFrame];
}

- (void)dismissMentionLookup:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) [self hideMentionLookup];
}

- (void)hideMentionLookup {
    [self hideMentionLookupAnimated:YES];
}

- (void)hideMentionLookupAnimated:(BOOL)animated {
    if (!self.lookupVisible) return;
    self.lookupVisible = NO;
    self.lookupToken = NSMakeRange(NSNotFound, 0);
    self.lookupQuery = nil;
    self.lookupNonce = nil;
    self.lookupCandidates = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(searchMentionGuild) object:nil];

    DCChatLookupView *lookup = self.mentionLookup;
    UIView *dimming = self.lookupDimming;
    CGRect hiddenFrame = lookup.frame;
    hiddenFrame.origin.y = CGRectGetMinY(self.composerBar.frame);
    [UIView animateWithDuration:(animated ? 0.18 : 0.0)
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        dimming.alpha = 0.0f;
        lookup.frame = hiddenFrame;
    } completion:^(BOOL finished) {
        if (self.lookupVisible) return;
        [lookup removeFromSuperview];
        [dimming removeFromSuperview];
        [lookup clearResults];
    }];
}

- (void)updateMentionLookup {
    if (self.creating || !self.messageField.isFirstResponder) {
        [self hideMentionLookup];
        return;
    }
    NSString *text = self.messageField.text ?: @"";
    NSRange selected = self.messageField.selectedRange;
    if (selected.location == NSNotFound || selected.location > text.length) {
        [self hideMentionLookup];
        return;
    }
    NSUInteger cursor = selected.location;
    NSRange at = [text rangeOfString:@"@" options:NSBackwardsSearch
                             range:NSMakeRange(0, cursor)];
    if (at.location == NSNotFound) { [self hideMentionLookup]; return; }
    NSString *query = [text substringWithRange:
        NSMakeRange(NSMaxRange(at), cursor - NSMaxRange(at))];
    if ([query rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location
            != NSNotFound ||
        [query rangeOfString:@"<"].location != NSNotFound ||
        [query rangeOfString:@">"].location != NSNotFound ||
        (at.location && [[NSCharacterSet alphanumericCharacterSet]
            characterIsMember:[text characterAtIndex:at.location - 1]])) {
        [self hideMentionLookup];
        return;
    }
    BOOL opening = !self.lookupVisible;
    if (opening) {
        [self ensureMentionLookup];
        self.lookupCandidates = [self mentionCandidates];
    }
    self.lookupToken = NSMakeRange(at.location, cursor - at.location);
    [self.mentionLookup setMentionUsers:self.lookupCandidates
                                  guild:self.parentChannel.parentGuild query:query];
    if (opening) {
        self.lookupVisible = YES;
        self.lookupDimming.frame = self.formTable.frame;
        self.lookupDimming.alpha = 0.0f;
        [self.view insertSubview:self.lookupDimming aboveSubview:self.formTable];
        CGRect visibleFrame = [self mentionLookupVisibleFrame];
        CGRect hiddenFrame = visibleFrame;
        hiddenFrame.origin.y = CGRectGetMinY(self.composerBar.frame);
        self.mentionLookup.frame = hiddenFrame;
        [self.view insertSubview:self.mentionLookup aboveSubview:self.lookupDimming];
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.lookupDimming.alpha = 1.0f;
            self.mentionLookup.frame = visibleFrame;
        } completion:nil];
    } else {
        [self refreshMentionLookupFrame];
    }
    NSString *normalized = [query lowercaseString];
    if (![normalized isEqualToString:self.lookupQuery]) {
        self.lookupQuery = normalized;
        self.lookupNonce = nil;
        [NSObject cancelPreviousPerformRequestsWithTarget:self
            selector:@selector(searchMentionGuild) object:nil];
        if (normalized.length >= 2) {
            [self performSelector:@selector(searchMentionGuild)
                       withObject:nil afterDelay:0.30];
        }
    }
}

- (void)searchMentionGuild {
    if (!self.lookupVisible || self.lookupQuery.length < 2) return;
    self.lookupSequence++;
    NSString *nonce = [NSString stringWithFormat:@"dctc-%lu-%08x",
        (unsigned long)self.lookupSequence, arc4random()];
    self.lookupNonce = nonce;
    [DCServerCommunicator.sharedInstance sendJSON:@{
        @"op": @(DCGatewayOpCodeRequestGuildMembers),
        @"d": @{
            @"guild_id": self.parentChannel.parentGuild.snowflake,
            @"query": self.lookupQuery,
            @"limit": @100,
            @"presences": @NO,
            @"nonce": nonce
        }
    }];
}

- (void)mentionSearchReceived:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self mentionSearchReceived:notification]; });
        return;
    }
    NSDictionary *info = notification.userInfo;
    if (!self.lookupVisible || !self.lookupNonce.length ||
        ![[info objectForKey:@"guild_id"] isEqualToString:self.parentChannel.parentGuild.snowflake] ||
        ![[info objectForKey:@"nonce"] isEqualToString:self.lookupNonce]) return;
    NSArray *ids = [info objectForKey:@"user_ids"];
    if (![ids isKindOfClass:[NSArray class]]) return;
    NSMutableArray *candidates = [self.lookupCandidates mutableCopy] ?: [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (DCUser *user in candidates) if (user.snowflake.length) [seen addObject:user.snowflake];
    for (NSString *userID in ids) {
        if (![userID isKindOfClass:[NSString class]] || [seen containsObject:userID]) continue;
        DCUser *user = [DCServerCommunicator.sharedInstance userForSnowflake:userID];
        if (!user) continue;
        [seen addObject:userID];
        [candidates addObject:user];
    }
    self.lookupCandidates = candidates;
    [self.mentionLookup setMentionUsers:candidates
                                  guild:self.parentChannel.parentGuild query:self.lookupQuery];
    [self refreshMentionLookupFrame];
}

- (void)chatLookupView:(DCChatLookupView *)lookup didSelectUser:(DCUser *)user {
    if (!user.snowflake.length || !self.lookupVisible) return;
    NSString *text = self.messageField.text ?: @"";
    NSRange range = self.lookupToken;
    if (range.location == NSNotFound || NSMaxRange(range) > text.length) return;
    NSString *mention = [NSString stringWithFormat:@"<@%@> ", user.snowflake];
    self.messageField.text = [text stringByReplacingCharactersInRange:range withString:mention];
    self.messageField.selectedRange = NSMakeRange(range.location + mention.length, 0);
    [self.chatComposer updatePlaceholder];
    [self updateComposerFrames];
    [self hideMentionLookup];
}

- (void)setCreatingState:(BOOL)creating {
    if (creating) [self hideMentionLookupAnimated:NO];
    self.creating = creating;
    self.sendButton.enabled = !creating;
    self.sendButton.hidden = creating;
    self.titleField.enabled = !creating;
    self.messageField.editable = !creating;
    self.navigationItem.hidesBackButton = creating;
    if (creating) [self.sendingSpinner startAnimating];
    else [self.sendingSpinner stopAnimating];
    [self updatePrivateRow];
}

- (void)showSubmissionError:(NSString *)message {
    [self setCreatingState:NO];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Couldn't Create Thread"
        message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
}

- (void)submitThread:(id)sender {
    if (self.creating) return;
    NSString *name = DCThreadTrimmedString(self.titleField.text);
    if (!name.length) {
        [self showNameWarning:YES];
        [self.titleField becomeFirstResponder];
        return;
    }

    uint64_t permission = [DCServerCommunicator.sharedInstance
        effectivePermissionsForChannel:self.parentChannel];
    BOOL canCreate = (permission & DCPermissionViewChannel) != 0 &&
        (permission & (self.privateThread ? DCPermissionCreatePrivateThreads
                                          : DCPermissionCreatePublicThreads)) != 0;
    if (!canCreate) {
        [self showSubmissionError:@"You don't have permission to create this type of thread."];
        return;
    }
    NSString *text = DCThreadTrimmedString(self.messageField.text);
    if (text.length && (permission & DCPermissionSendMessagesInThreads) == 0) {
        [self showSubmissionError:@"You don't have permission to send messages in threads."];
        return;
    }

    NSString *parsedMessage = text.length
        ? [DCTools parseMessage:text withGuild:self.parentChannel.parentGuild] : @"";
    NSDictionary *body = @{
        @"name": name,
        @"type": @(self.privateThread ? DCChannelTypePrivateThread : DCChannelTypePublicThread),
        @"auto_archive_duration": @1440
    };
    NSString *parentID = [self.parentChannel.snowflake copy];
    NSString *guildID = [self.parentChannel.parentGuild.snowflake copy];
    NSString *token = [DCServerCommunicator.sharedInstance.token copy];
    [self.view endEditing:YES];
    [self setCreatingState:YES];
    __weak DCThreadCreateViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSString *path = [NSString stringWithFormat:@"/channels/%@/threads", parentID];
            NSMutableURLRequest *request = [DCServerCommunicator requestWithPath:path token:token];
            [request setHTTPMethod:@"POST"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
            [request setTimeoutInterval:18.0];
            [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
            NSHTTPURLResponse *response = nil;
            NSError *error = nil;
            NSData *responseData = [NSURLConnection sendSynchronousRequest:request
                returningResponse:&response error:&error];
            id json = responseData.length ?
                [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
            NSDictionary *created = [json isKindOfClass:[NSDictionary class]] ? json : nil;
            NSString *threadID = [created objectForKey:@"id"];
            BOOL success = !error && (response.statusCode == 200 || response.statusCode == 201) &&
                [threadID isKindOfClass:[NSString class]] && threadID.length;
            BOOL sent = YES;
            if (success && parsedMessage.length) {
                NSString *messagePath = [NSString stringWithFormat:@"/channels/%@/messages", threadID];
                NSMutableURLRequest *messageRequest =
                    [DCServerCommunicator requestWithPath:messagePath token:token];
                [messageRequest setHTTPMethod:@"POST"];
                [messageRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                [messageRequest setTimeoutInterval:18.0];
                [messageRequest setHTTPBody:[NSJSONSerialization dataWithJSONObject:
                    @{@"content": parsedMessage, @"type": @0} options:0 error:nil]];
                NSHTTPURLResponse *sendResponse = nil;
                NSError *sendError = nil;
                [NSURLConnection sendSynchronousRequest:messageRequest
                                 returningResponse:&sendResponse error:&sendError];
                sent = !sendError && (sendResponse.statusCode == 200 || sendResponse.statusCode == 201);
            }
            NSString *errorMessage = nil;
            if (!success) {
                if (response.statusCode == 403)
                    errorMessage = @"Discord denied permission to create the thread.";
                else if (response.statusCode == 429)
                    errorMessage = @"You're being rate limited. Please try again shortly.";
                else if (error.localizedDescription.length)
                    errorMessage = error.localizedDescription;
                else
                    errorMessage = @"Discord couldn't create this thread. Please try again.";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                DCThreadCreateViewController *controller = weakSelf;
                if (!controller) return;
                if (!success) {
                    [controller showSubmissionError:errorMessage];
                    return;
                }
                NSMutableDictionary *payload = [created mutableCopy];
                if (![[payload objectForKey:@"guild_id"] isKindOfClass:[NSString class]])
                    [payload setObject:guildID forKey:@"guild_id"];
                if (![[payload objectForKey:@"parent_id"] isKindOfClass:[NSString class]])
                    [payload setObject:parentID forKey:@"parent_id"];
                [DCServerCommunicator.sharedInstance handleChannelCreateWithData:payload];
                [controller.navigationController dismissViewControllerAnimated:YES completion:^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"DCThreadOpenRequested"
                        object:nil userInfo:@{@"thread": payload}];
                    if (!sent) {
                        UIAlertView *warning = [[UIAlertView alloc] initWithTitle:@"Thread Created"
                            message:@"The thread was created, but its first message could not be sent."
                            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                        [warning show];
                    }
                }];
            });
        }
    });
}

@end
