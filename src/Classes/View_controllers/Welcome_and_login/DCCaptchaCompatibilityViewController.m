//
//  DCCaptchaCompatibilityViewController.m
//  Discord Classic
//
//  Created by Ayeris on 11/8/26.
//  Copyright (c) 2026 Ayeris All rights reserved.
//

#import "DCCaptchaCompatibilityViewController.h"

static NSString *const DCCaptchaTestSitekey = @"10000000-ffff-ffff-ffff-000000000001";

@interface DCCaptchaCompatibilityViewController ()
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableString *report;
@property (atomic, assign) NSUInteger runNumber;
@property (nonatomic, assign) BOOL networkChecksStarted;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (atomic, assign) NSTimeInterval lastMainHeartbeat;
@end

@implementation DCCaptchaCompatibilityViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CAPTCHA Test";
    self.view.backgroundColor = [UIColor colorWithRed:40/255.0f green:41/255.0f blue:46/255.0f alpha:1.0f];
    self.report = [NSMutableString string];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Stock", @"Polyfills", @"ES5", @"JS Only", @"Native Fix"]];
    self.modeControl.segmentedControlStyle = UISegmentedControlStyleBar;
    self.modeControl.selectedSegmentIndex = 0;
    self.modeControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.modeControl addTarget:self action:@selector(startProbe) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeControl];

    NSLog(@"[CAPTCHA Probe] Creating UIWebView");
    self.webView = [[UIWebView alloc] initWithFrame:CGRectZero];
    NSLog(@"[CAPTCHA Probe] UIWebView initialized");
    self.webView.delegate = self;
    self.webView.backgroundColor = self.view.backgroundColor;
    self.webView.opaque = NO;
    self.webView.scalesPageToFit = NO;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.webView];

    self.logView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.logView.editable = NO;
    self.logView.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    self.logView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    self.logView.font = [UIFont fontWithName:@"Courier" size:11.0f];
    self.logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.logView];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Copy Log"
                                                                               style:UIBarButtonItemStyleBordered
                                                                              target:self
                                                                              action:@selector(copyReport)];
    [self startProbe];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lastMainHeartbeat = [NSDate timeIntervalSinceReferenceDate];
    if (!self.heartbeatTimer) {
        self.heartbeatTimer = [NSTimer timerWithTimeInterval:0.5
                                                    target:self
                                                  selector:@selector(updateMainHeartbeat)
                                                  userInfo:nil
                                                   repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)updateMainHeartbeat {
    self.lastMainHeartbeat = [NSDate timeIntervalSinceReferenceDate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    self.modeControl.frame = CGRectMake(8, 8, MAX(0, width - 16), 30);
    CGFloat webHeight = MAX(140, height * 0.55f - 42);
    self.webView.frame = CGRectMake(0, 42, width, webHeight);
    self.logView.frame = CGRectMake(0, CGRectGetMaxY(self.webView.frame), width,
                                    MAX(0, height - CGRectGetMaxY(self.webView.frame)));
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    ++self.runNumber;
    [self.webView stopLoading];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || orientation == UIInterfaceOrientationPortrait);
}

- (void)copyReport {
    [UIPasteboard generalPasteboard].string = self.report;
    [self appendLog:@"Diagnostic log copied to clipboard"];
}

- (void)appendLog:(NSString *)message {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:message]; });
        return;
    }
    NSArray *modeLabels = @[@"Stock", @"Polyfill", @"ES5", @"JS Only", @"Native Fix"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", modeLabels[self.modeControl.selectedSegmentIndex], message];
    [self.report appendString:line];
    self.logView.text = self.report;
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    NSLog(@"[CAPTCHA Probe] %@", line);
}

+ (NSString *)JSONStringForValue:(NSString *)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""] options:0 error:NULL];
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *literal = [array substringWithRange:NSMakeRange(1, array.length - 2)];
    return [literal stringByReplacingOccurrencesOfString:@"<" withString:@"\\u003c"];
}

- (void)startProbe {
    ++self.runNumber;
    self.networkChecksStarted = NO;
    self.webView.delegate = nil;
    [self.webView stopLoading];
    self.webView.delegate = self;
    self.report = [NSMutableString string];
    self.logView.text = @"";
    [self appendLog:[NSString stringWithFormat:@"Probe run %lu", (unsigned long)self.runNumber]];

    BOOL isRealChallenge = self.captchaSitekey.length > 0;
    NSString *sitekey = isRealChallenge ? self.captchaSitekey : DCCaptchaTestSitekey;
    [self appendLog:isRealChallenge ? @"Using the sitekey returned by Discord (diagnostic only)" : @"Using hCaptcha's published always-pass test sitekey"];
    [self appendLog:@"This probe does not send a CAPTCHA result or account credentials to Discord"];
    NSArray *modeDescriptions = @[@"unmodified UIWebView",
                                  @"Cloudflare polyfills and direct hCaptcha SDK",
                                  @"hCaptcha ES5 loader with Cloudflare polyfills",
                                  @"Cloudflare polyfills ONLY (no hCaptcha code)",
                                  @"Cloudflare polyfills plus hCaptcha with native MIME/plugin serialization compatibility"];
    [self appendLog:[NSString stringWithFormat:@"Mode: %@", modeDescriptions[self.modeControl.selectedSegmentIndex]]];

    if (isRealChallenge && self.captchaService.length &&
        [self.captchaService rangeOfString:@"hcaptcha" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        [self appendLog:[NSString stringWithFormat:@"Unsupported provider: %@ (hCaptcha test skipped)", self.captchaService]];
        return;
    }

    NSString *path = [[NSBundle mainBundle] pathForResource:@"CaptchaProbe" ofType:@"html"];
    NSError *error = nil;
    NSString *html = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!html) {
        [self appendLog:[NSString stringWithFormat:@"Test page missing from app bundle: %@", error]];
        return;
    }
    html = [html stringByReplacingOccurrencesOfString:@"__RUN_ID__" withString:[NSString stringWithFormat:@"%lu", (unsigned long)self.runNumber]];
    html = [html stringByReplacingOccurrencesOfString:@"__SITEKEY_JSON__" withString:[DCCaptchaCompatibilityViewController JSONStringForValue:sitekey]];
    html = [html stringByReplacingOccurrencesOfString:@"__RQDATA_JSON__" withString:[DCCaptchaCompatibilityViewController JSONStringForValue:self.captchaRQData]];
    html = [html stringByReplacingOccurrencesOfString:@"__PROBE_MODE__" withString:[NSString stringWithFormat:@"%ld", (long)self.modeControl.selectedSegmentIndex]];
    [self.webView loadHTMLString:html baseURL:[NSURL URLWithString:@"https://example.com/"]];
    NSUInteger run = self.runNumber;
    for (NSNumber *seconds in @[@10, @20, @40]) {
        NSTimeInterval delay = [seconds doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (run != self.runNumber || !self.view.window) { return; }
            [self appendLog:[NSString stringWithFormat:@"Native main-queue watchdog reached %.0f seconds", delay]];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (run != self.runNumber) { return; }
            NSTimeInterval gap = [NSDate timeIntervalSinceReferenceDate] - self.lastMainHeartbeat;
            NSLog(@"[CAPTCHA Probe] [Background Watchdog] Run %lu at %.0fs: main-thread heartbeat age %.1fs%@",
                  (unsigned long)run, delay, gap,
                  gap >= 3.0 ? @" (MAIN THREAD STALLED)" : @" (main thread responding)");
        });
    }
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request
 navigationType:(UIWebViewNavigationType)navigationType {
    NSURL *url = request.URL;
    if ([[url.scheme lowercaseString] isEqualToString:@"dccaptcha-log"]) {
        NSString *runValue = nil;
        NSString *encodedMessage = nil;
        for (NSString *parameter in [url.query componentsSeparatedByString:@"&"]) {
            if ([parameter hasPrefix:@"run="]) {
                runValue = [parameter substringFromIndex:4];
            } else if ([parameter hasPrefix:@"message="]) {
                encodedMessage = [parameter substringFromIndex:8];
            }
        }
        if (runValue && [runValue integerValue] == self.runNumber && encodedMessage) {
            NSString *decoded = [encodedMessage stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            [self appendLog:decoded ?: encodedMessage];
        }
        return NO;
    }
    NSString *host = [url.host lowercaseString];
    if (host && ([host isEqualToString:@"hcaptcha.com"] ||
                 [host hasSuffix:@".hcaptcha.com"])) {
        [self appendLog:[NSString stringWithFormat:@"WebKit hCaptcha frame navigation: %@%@ (navigationType=%ld)",
                         host, url.path ?: @"", (long)navigationType]];
    }
    return YES;
}

- (void)checkEndpoint:(NSString *)endpoint label:(NSString *)label userAgent:(NSString *)userAgent run:(NSUInteger)run {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:12.0];
        request.HTTPMethod = @"HEAD";
        if (userAgent.length) {
            [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        }
        NSHTTPURLResponse *response = nil;
        NSError *connectionError = nil;
        [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&connectionError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (run != self.runNumber) { return; }
            if (connectionError) {
                [self appendLog:[NSString stringWithFormat:@"%@ HTTPS HEAD failed (%@ %ld): %@",
                                 label, connectionError.domain, (long)connectionError.code,
                                 connectionError.localizedDescription]];
            } else {
                [self appendLog:[NSString stringWithFormat:@"%@ HTTPS HEAD returned HTTP %ld (connection succeeded)",
                                 label, (long)response.statusCode]];
            }
        });
    });
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    if (self.networkChecksStarted) { return; }
    self.networkChecksStarted = YES;
    NSString *userAgent = [webView stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];
    NSUInteger run = self.runNumber;
    [self checkEndpoint:@"https://js.hcaptcha.com/1/api.js?render=explicit"
                  label:@"hCaptcha" userAgent:userAgent run:run];
    [self checkEndpoint:@"https://cdnjs.cloudflare.com/polyfill/v3/polyfill.min.js?features=default%2Ces2015%2Cfetch"
                  label:@"Cloudflare" userAgent:userAgent run:run];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) { return; }
    NSURL *url = [error.userInfo objectForKey:NSURLErrorFailingURLErrorKey];
    if (!url) {
        NSString *failingURL = [error.userInfo objectForKey:NSURLErrorFailingURLStringErrorKey];
        if (failingURL) { url = [NSURL URLWithString:failingURL]; }
    }
    // Avoid including CAPTCHA request tokens or query parameters in diagnostic output.
    NSString *path = url ? [NSString stringWithFormat:@"%@%@", url.host ?: @"", url.path ?: @""] : @"unknown URL";
    [self appendLog:[NSString stringWithFormat:@"WebKit load failed (%@, %ld), resource=%@",
                     error.domain, (long)error.code, path]];
}

@end
