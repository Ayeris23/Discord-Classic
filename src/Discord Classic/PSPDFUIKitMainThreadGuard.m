#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

#define PROPERTY(propName) NSStringFromSelector(@selector(propName))

#define PSPDFAssert(expression, ...) \
do { if(!(expression)) { \
    NSLog(@"%@", [NSString stringWithFormat: @"Assertion failure: %s in %s on line %s:%d. %@", #expression, __PRETTY_FUNCTION__, __FILE__, __LINE__, [NSString stringWithFormat:@"" __VA_ARGS__]]); \
abort(); }} while(0)

BOOL PSPDFReplaceMethodWithBlock(Class c, SEL origSEL, SEL newSEL, id block) {
    PSPDFAssert(c && origSEL && newSEL && block);
    Method origMethod = class_getInstanceMethod(c, origSEL);
    const char *encoding = method_getTypeEncoding(origMethod);

    IMP impl = imp_implementationWithBlock(block);
    if (!class_addMethod(c, newSEL, impl, encoding)) {
        NSLog(@"Failed to add method: %@ on %@", NSStringFromSelector(newSEL), c);
        return NO;
    } else {
        Method newMethod = class_getInstanceMethod(c, newSEL);
        PSPDFAssert(strcmp(method_getTypeEncoding(origMethod), method_getTypeEncoding(newMethod)) == 0,
                    @"Encoding must be the same.");

        if (class_addMethod(c, origSEL, method_getImplementation(newMethod), encoding)) {
            class_replaceMethod(c, newSEL, method_getImplementation(origMethod), encoding);
        } else {
            method_exchangeImplementations(origMethod, newMethod);
        }
    }
    return YES;
}

static void PSPDFLogOffMainUIKitCall(UIView *view, SEL selector) {
    static NSUInteger loggedCallCount = 0;
    if (loggedCallCount >= 8) return;
    loggedCallCount++;

    NSLog(@"[UIKitMainThreadGuard] %@ sent to %@ off main thread. Stack: %@",
          NSStringFromSelector(selector),
          NSStringFromClass([view class]),
          [NSThread callStackSymbols]);
}

__attribute__((constructor)) static void PSPDFUIKitMainThreadGuard(void) {
    setenv("CA_DEBUG_TRANSACTIONS", "1", 1);
    @autoreleasepool {
        for (NSString *selStr in @[PROPERTY(setNeedsLayout), PROPERTY(setNeedsDisplay), PROPERTY(setNeedsDisplayInRect:)]) {
            SEL selector = NSSelectorFromString(selStr);
            SEL newSelector = NSSelectorFromString([NSString stringWithFormat:@"pspdf_%@", selStr]);

            if ([selStr hasSuffix:@":"]) {
                PSPDFReplaceMethodWithBlock(UIView.class, selector, newSelector, ^(UIView *_self, CGRect rect) {
                    if ([NSThread isMainThread]) {
                        ((void (*)(id, SEL, CGRect))objc_msgSend)(_self, newSelector, rect);
                        return;
                    }

                    PSPDFLogOffMainUIKitCall(_self, selector);
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL, CGRect))objc_msgSend)(_self, newSelector, rect);
                    });
                });
            } else {
                PSPDFReplaceMethodWithBlock(UIView.class, selector, newSelector, ^(UIView *_self) {
                    if ([NSThread isMainThread]) {
                        ((void (*)(id, SEL))objc_msgSend)(_self, newSelector);
                        return;
                    }

                    PSPDFLogOffMainUIKitCall(_self, selector);
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(_self, newSelector);
                    });
                });
            }
        }
    }
}
