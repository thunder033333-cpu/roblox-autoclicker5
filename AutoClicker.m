// AutoClicker.m — v2  "Headless"
// LiveContainer TweakLoader dylib → injected into Roblox
// Zero UI. Fully controlled by AutoClickerApp.ipa via Darwin notifications.
//
// IPC channel (CFDarwinNotifyCenter — cross-process, no shared container needed):
//   com.ac.fire.start          → arm the timer, start firing at s_tapPt
//   com.ac.fire.stop           → disarm
//   com.ac.interval.<ms>       → set fire interval, e.g. com.ac.interval.50 = 20 taps/sec
//
// Position tracking:
//   swizzles UIApplication -sendEvent: to record every UITouchPhaseBegan
//   coordinate in Roblox's own window space → s_tapPt
//   s_tapPt is therefore always "the last place the user actually tapped in Roblox"
//
// Background execution:
//   On start-notification, requests a UIBackgroundTask so the firing
//   timer keeps running even if Roblox is momentarily backgrounded.
//   Best experience: iPadOS Split View (both apps foreground simultaneously).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ──────────────────────────────────────────────────────────────
// PRIVATE SELECTOR CACHE  (same synthesis engine as v1)
// ──────────────────────────────────────────────────────────────

static SEL kSEL_initWithWindow;
static SEL kSEL_setLocation;
static SEL kSEL_setPhase;
static SEL kSEL_setView;
static SEL kSEL_setTimestamp;
static SEL kSEL_setTapCount;
static SEL kSEL_touchesEvent;
static SEL kSEL_clearTouches;
static SEL kSEL_addTouch;

typedef id        (*FN_initWin)(id,SEL,id);
typedef void      (*FN_setLocBOOL)(id,SEL,CGPoint,BOOL);
typedef void      (*FN_setPhase)(id,SEL,UITouchPhase);
typedef void      (*FN_setView)(id,SEL,UIView *);
typedef void      (*FN_setTS)(id,SEL,NSTimeInterval);
typedef void      (*FN_setN)(id,SEL,NSUInteger);
typedef void      (*FN_addTouch)(id,SEL,UITouch *,BOOL);
typedef void      (*FN_clearTouches)(id,SEL);
typedef UIEvent * (*FN_touchesEvent)(id,SEL);

// ──────────────────────────────────────────────────────────────
// GLOBALS
// ──────────────────────────────────────────────────────────────

static NSTimer               *s_timer          = nil;
static CGPoint                s_tapPt;                   // last real touch in Roblox
static NSTimeInterval         s_interval        = 0.05;  // 50ms default
static NSInteger              s_synthDepth      = 0;     // re-entrancy guard for swizzle
static UIBackgroundTaskIdentifier s_bgTask      = UIBackgroundTaskInvalid;
static IMP                    s_origSendEvent   = NULL;  // saved original sendEvent IMP

// ──────────────────────────────────────────────────────────────
// HELPERS
// ──────────────────────────────────────────────────────────────

static UIWindow *roblox_window(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (!w.isHidden) return w;
    return UIApplication.sharedApplication.windows.firstObject;
}

// ──────────────────────────────────────────────────────────────
// TOUCH SYNTHESIS ENGINE  (identical to v1)
// ──────────────────────────────────────────────────────────────

static void ac_fire(void) {
    UIApplication *app  = UIApplication.sharedApplication;
    UIWindow      *rwin = roblox_window();
    if (!rwin) return;

    CGPoint        pt  = s_tapPt;
    UIView        *hit = [rwin hitTest:pt withEvent:nil] ?: rwin;
    NSTimeInterval ts  = NSProcessInfo.processInfo.systemUptime;

    UITouch *t = [UITouch alloc];
    if ([t respondsToSelector:kSEL_initWithWindow])
        t = ((FN_initWin)objc_msgSend)(t, kSEL_initWithWindow, rwin);
    else
        t = [t init];

    if ([t respondsToSelector:kSEL_setLocation])
        ((FN_setLocBOOL)objc_msgSend)(t, kSEL_setLocation, pt, YES);
    if ([t respondsToSelector:kSEL_setView])
        ((FN_setView)objc_msgSend)(t, kSEL_setView, hit);
    if ([t respondsToSelector:kSEL_setTimestamp])
        ((FN_setTS)objc_msgSend)(t, kSEL_setTimestamp, ts);
    if ([t respondsToSelector:kSEL_setTapCount])
        ((FN_setN)objc_msgSend)(t, kSEL_setTapCount, (NSUInteger)1);

    UIEvent *ev = ((FN_touchesEvent)objc_msgSend)(app, kSEL_touchesEvent);
    if (!ev) return;

    ((FN_clearTouches)objc_msgSend)(ev, kSEL_clearTouches);

    // ── Began ─────────────────────────────────────────────────
    if ([t respondsToSelector:kSEL_setPhase])
        ((FN_setPhase)objc_msgSend)(t, kSEL_setPhase, UITouchPhaseBegan);
    ((FN_addTouch)objc_msgSend)(ev, kSEL_addTouch, t, NO);

    s_synthDepth++;             // tell the swizzle to ignore this event
    [app sendEvent:ev];
    s_synthDepth--;

    // ── Ended (one frame later) ───────────────────────────────
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if ([t respondsToSelector:kSEL_setPhase])
            ((FN_setPhase)objc_msgSend)(t, kSEL_setPhase, UITouchPhaseEnded);
        if ([t respondsToSelector:kSEL_setTimestamp])
            ((FN_setTS)objc_msgSend)(t, kSEL_setTimestamp,
                                    NSProcessInfo.processInfo.systemUptime);
        s_synthDepth++;
        [app sendEvent:ev];
        s_synthDepth--;
        ((FN_clearTouches)objc_msgSend)(ev, kSEL_clearTouches);
    });
}

// ──────────────────────────────────────────────────────────────
// sendEvent: SWIZZLE
// Intercepts every UIEvent passing through Roblox's UIApplication.
// If it's a real touch (not our synthetic one) at phase Began,
// record the window-space coordinate as the new tap target.
//
// Stack at swizzle call site:
//   Roblox UIApplication -sendEvent:
//     → ac_sendEvent_hook          ← we are here
//         → record s_tapPt if real touch
//         → call s_origSendEvent   (original UIApplication -sendEvent:)
//             → Roblox responder chain
// ──────────────────────────────────────────────────────────────

static void ac_sendEvent_hook(UIApplication *self, SEL _cmd, UIEvent *event) {
    // Only update position on real (non-synthetic) touch began events
    if (s_synthDepth == 0 && event.type == UIEventTypeTouches) {
        for (UITouch *t in [event allTouches]) {
            if (t.phase == UITouchPhaseBegan) {
                UIWindow *win = t.window;
                if (win) {
                    // locationInView:nil gives screen coordinates
                    s_tapPt = [t locationInView:win];
                }
                break; // only need the first finger
            }
        }
    }
    ((void(*)(id,SEL,UIEvent *))s_origSendEvent)(self, _cmd, event);
}

// ──────────────────────────────────────────────────────────────
// TIMER CALLBACKS
// ──────────────────────────────────────────────────────────────

static void ac_start_firing(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_timer invalidate];
        s_timer = [NSTimer scheduledTimerWithTimeInterval:s_interval
                                                   target:[NSBlockOperation blockOperationWithBlock:^{ ac_fire(); }]
                                                 selector:@selector(main)
                                                 userInfo:nil
                                                  repeats:YES];

        // Request background execution time so the timer survives
        // if Roblox is briefly backgrounded while the user holds
        // the companion app's button.
        UIApplication *app = UIApplication.sharedApplication;
        if (s_bgTask == UIBackgroundTaskInvalid) {
            s_bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
                [s_timer invalidate]; s_timer = nil;
                [app endBackgroundTask:s_bgTask];
                s_bgTask = UIBackgroundTaskInvalid;
            }];
        }
    });
}

static void ac_stop_firing(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_timer invalidate]; s_timer = nil;
        if (s_bgTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:s_bgTask];
            s_bgTask = UIBackgroundTaskInvalid;
        }
    });
}

// ──────────────────────────────────────────────────────────────
// DARWIN NOTIFICATION OBSERVERS
// CFDarwinNotifyCenter is system-wide — no shared container,
// no app group, no entitlement needed. Works from any process.
// ──────────────────────────────────────────────────────────────

typedef void (*CFNCCallback)(CFNotificationCenterRef, void *,
                              CFNotificationName, const void *, CFDictionaryRef);

static void on_start(CFNotificationCenterRef c, void *o,
                     CFNotificationName n, const void *ob, CFDictionaryRef i) {
    ac_start_firing();
}

static void on_stop(CFNotificationCenterRef c, void *o,
                    CFNotificationName n, const void *ob, CFDictionaryRef i) {
    ac_stop_firing();
}

// Interval notifications arrive as "com.ac.interval.50" where 50 = ms
// We can't pass data in Darwin notifications, so we encode it in the name.
static void on_interval(CFNotificationCenterRef c, void *o,
                        CFNotificationName n, const void *ob, CFDictionaryRef i) {
    NSString *name = (__bridge NSString *)n;
    NSArray  *parts = [name componentsSeparatedByString:@"."];
    // name format: com.ac.interval.<ms>
    if (parts.count >= 4) {
        NSInteger ms = [parts.lastObject integerValue];
        if (ms >= 5 && ms <= 2000) {
            s_interval = ms / 1000.0;
            // If already firing, restart with new interval
            if (s_timer) { ac_stop_firing(); ac_start_firing(); }
        }
    }
}

static void ac_register_observers(void) {
    CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(dc, NULL, on_start,
        CFSTR("com.ac.fire.start"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(dc, NULL, on_stop,
        CFSTR("com.ac.fire.stop"),  NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // Wildcard-ish: listen for com.ac.interval.* by registering a
    // catch-all and filtering in the callback.
    // Darwin doesn't support wildcards, so we register the exact names
    // for common intervals. The companion app only posts these values.
    for (NSInteger ms = 5; ms <= 2000; ms += 5) {
        NSString *key = [NSString stringWithFormat:@"com.ac.interval.%ld", (long)ms];
        CFNotificationCenterAddObserver(dc, NULL, on_interval,
            (__bridge CFStringRef)key, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

// ──────────────────────────────────────────────────────────────
// CONSTRUCTOR
// ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void ac_init(void) {

    // ── Private selector cache ────────────────────────────────
    kSEL_initWithWindow = NSSelectorFromString(@"_initWithWindow:");
    kSEL_setLocation    = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    kSEL_setPhase       = NSSelectorFromString(@"_setPhase:");
    kSEL_setView        = NSSelectorFromString(@"_setView:");
    kSEL_setTimestamp   = NSSelectorFromString(@"_setTimestamp:");
    kSEL_setTapCount    = NSSelectorFromString(@"_setTapCount:");
    kSEL_touchesEvent   = NSSelectorFromString(@"_touchesEvent");
    kSEL_clearTouches   = NSSelectorFromString(@"_clearTouches");
    kSEL_addTouch       = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");

    // ── Swizzle UIApplication -sendEvent: ─────────────────────
    // Pure ObjC runtime — no MSHookFunction, no ElleKit.
    Method m = class_getInstanceMethod([UIApplication class],
                                        @selector(sendEvent:));
    s_origSendEvent = method_getImplementation(m);
    method_setImplementation(m, (IMP)ac_sendEvent_hook);

    // ── Register Darwin notification observers ────────────────
    ac_register_observers();

    // ── Set initial tap target to screen centre ───────────────
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = UIScreen.mainScreen.bounds;
        s_tapPt = CGPointMake(b.size.width / 2.f, b.size.height / 2.f);
    });
}
