#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#ifndef PSPDF_ENABLE_UIKIT_MAIN_THREAD_GUARD
#define PSPDF_ENABLE_UIKIT_MAIN_THREAD_GUARD 0
#endif

#if PSPDF_ENABLE_UIKIT_MAIN_THREAD_GUARD

static IMP PSPDFOriginalSetNeedsLayout = NULL;
static IMP PSPDFOriginalSetNeedsDisplay = NULL;
static IMP PSPDFOriginalSetNeedsDisplayInRect = NULL;

static void PSPDFLogOffMainUIKitCall(UIView *view, SEL selector) {
    static NSUInteger loggedCallCount = 0;
    if (loggedCallCount >= 8) return;
    loggedCallCount++;

    NSLog(@"[UIKitMainThreadGuard] %@ sent to %@ off main thread. Stack: %@",
          NSStringFromSelector(selector),
          NSStringFromClass([view class]),
          [NSThread callStackSymbols]);
}

static void PSPDFCallOriginal(UIView *view, SEL selector, IMP original) {
    if (!original) return;
    if ([NSThread isMainThread]) {
        ((void (*)(id, SEL))original)(view, selector);
        return;
    }

    PSPDFLogOffMainUIKitCall(view, selector);
    dispatch_sync(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL))original)(view, selector);
    });
}

static void PSPDFCallOriginalWithRect(UIView *view, SEL selector, CGRect rect, IMP original) {
    if (!original) return;
    if ([NSThread isMainThread]) {
        ((void (*)(id, SEL, CGRect))original)(view, selector, rect);
        return;
    }

    PSPDFLogOffMainUIKitCall(view, selector);
    dispatch_sync(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, CGRect))original)(view, selector, rect);
    });
}

static void PSPDFSetNeedsLayout(UIView *view, SEL selector) {
    PSPDFCallOriginal(view, selector, PSPDFOriginalSetNeedsLayout);
}

static void PSPDFSetNeedsDisplay(UIView *view, SEL selector) {
    PSPDFCallOriginal(view, selector, PSPDFOriginalSetNeedsDisplay);
}

static void PSPDFSetNeedsDisplayInRect(UIView *view, SEL selector, CGRect rect) {
    PSPDFCallOriginalWithRect(view, selector, rect, PSPDFOriginalSetNeedsDisplayInRect);
}

static void PSPDFInstallGuard(SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod([UIView class], selector);
    if (!method) {
        NSLog(@"[UIKitMainThreadGuard] Missing UIView method: %@", NSStringFromSelector(selector));
        return;
    }

    IMP current = method_getImplementation(method);
    if (current == replacement) return;
    *original = method_setImplementation(method, replacement);
}

#endif

__attribute__((constructor)) static void PSPDFUIKitMainThreadGuard(void) {
    setenv("CA_DEBUG_TRANSACTIONS", "1", 1);
#if PSPDF_ENABLE_UIKIT_MAIN_THREAD_GUARD
    @autoreleasepool {
        PSPDFInstallGuard(@selector(setNeedsLayout),
                          (IMP)PSPDFSetNeedsLayout, &PSPDFOriginalSetNeedsLayout);
        PSPDFInstallGuard(@selector(setNeedsDisplay),
                          (IMP)PSPDFSetNeedsDisplay, &PSPDFOriginalSetNeedsDisplay);
        PSPDFInstallGuard(@selector(setNeedsDisplayInRect:),
                          (IMP)PSPDFSetNeedsDisplayInRect, &PSPDFOriginalSetNeedsDisplayInRect);
    }
#endif
}
