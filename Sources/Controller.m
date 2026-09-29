#import "Controller.h"
#import "Command.h"
#import "Desktop.h"
#import "ScreenQuery.h"
#import "Hooks.h"
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#include <signal.h>

NSArray<NSNumber *> *VSOnlineDisplays(void) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess) return @[];
    CGDirectDisplayID *ids = calloc(MAX(count, 1), sizeof(CGDirectDisplayID));
    NSMutableArray *result = [NSMutableArray new];
    if (CGGetOnlineDisplayList(count, ids, &count) == kCGErrorSuccess)
        for (uint32_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    free(ids);
    return result;
}
static NSArray *pointArray(CGPoint p) { return @[@(p.x), @(p.y)]; }
static NSArray *sizeArray(CGSize p) { return @[@(p.width), @(p.height)]; }
static CGPoint arrayPoint(NSArray *p) { return CGPointMake([p[0] doubleValue], [p[1] doubleValue]); }
static CGSize arraySize(NSArray *p) { return CGSizeMake([p[0] doubleValue], [p[1] doubleValue]); }
// Becoming main moves every display by -origin; shifting a preview position the same way keeps it on the same screen.
static NSArray *shifted(NSArray *p, CGPoint by) { return @[@([p[0] doubleValue] - by.x), @([p[1] doubleValue] - by.y)]; }
static CGFloat primaryHeight(void) { return NSScreen.screens.firstObject.frame.size.height; }
static NSRect contentRect(NSWindow *window) { return [window contentRectForFrameRect:window.frame]; }
static CGPoint previewPosition(NSWindow *window) {
    NSRect content = contentRect(window);
    return CGPointMake(content.origin.x, primaryHeight() - NSMaxY(content));
}
static NSRect previewRect(CGPoint position, CGSize size) {
    return NSMakeRect(position.x, primaryHeight() - position.y - size.height, size.width, size.height);
}
static NSString *aspectString(CGSize size) {
    long width = lround(size.width), height = lround(size.height), a = width, b = height;
    while (b) { long t = a % b; a = b; b = t; }
    return a ? [NSString stringWithFormat:@"%ld:%ld", width / a, height / a] : @"0:0";
}
NSArray<NSDictionary *> *VSSystemDisplays(void) {
    NSMutableArray *result = [NSMutableArray new];
    for (NSNumber *number in VSOnlineDisplays()) {
        CGDirectDisplayID display = number.unsignedIntValue;
        NSString *name = @"Unknown";
        for (NSScreen *screen in NSScreen.screens)
            if ([screen.deviceDescription[@"NSScreenNumber"] isEqual:number]) name = screen.localizedName;
        CGRect bounds = CGDisplayBounds(display);
        [result addObject:@{@"id": number, @"name": name, @"origin": pointArray(bounds.origin),
            @"size": sizeArray(bounds.size), @"aspect": aspectString(bounds.size), @"resolution": @[@(CGDisplayPixelsWide(display)), @(CGDisplayPixelsHigh(display))],
            @"main": @((BOOL)CGDisplayIsMain(display)), @"mirror": @(CGDisplayMirrorsDisplay(display))}];
    }
    return result;
}

@interface VSController ()
- (void)finish;
- (void)handleHotKey:(UInt32)key;
- (void)displaysWillChange;
- (void)display:(CGDirectDisplayID)display changed:(CGDisplayChangeSummaryFlags)flags;
@end
@implementation VSController {
    NSMutableDictionary<NSString *, VSDesktop *> *_desktops;
    VSControl *_control;
    EventHotKeyRef _hotKeys[3];
    EventHandlerRef _eventHandler;
    dispatch_source_t _interrupt, _terminate;
    BOOL _stopping, _quitting;
    NSMutableDictionary<NSString *, NSArray *> *_homes;  // name -> @[screen display ID, content rect]
    NSMutableSet<NSNumber *> *_ownedIDs;  // Every display this process created, kept after close.
    NSTimer *_hookTimer;
    BOOL _hooksRunning, _hooksPending;
    BOOL _drawMouse;  // config.yaml drawMouse, applied to every desktop.
}
static void displaysReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    if (flags & kCGDisplayBeginConfigurationFlag) [(__bridge VSController *)context displaysWillChange];
    else [(__bridge VSController *)context display:display changed:flags];
}
// Runs before AppKit relocates windows off a disconnected screen, so record which screen each
// visible preview is on and where.
- (void)displaysWillChange {
    if (_homes || _stopping) return;
    _homes = [NSMutableDictionary new];
    for (NSString *name in _desktops) {
        NSWindow *window = _desktops[name].window;
        NSNumber *screen = window.screen.deviceDescription[@"NSScreenNumber"];
        if (window.visible && screen) _homes[name] = @[screen, [NSValue valueWithRect:contentRect(window)]];
    }
}
// Hide previews whose screen went away instead of letting macOS pile them onto a remaining screen.
// Their position is kept, so `NAME --show` restores them once the screen is back.
- (void)screensChanged:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary<NSString *, NSArray *> *homes = self->_homes;
        self->_homes = nil;
        if (self->_stopping) return;
        NSArray *online = VSOnlineDisplays();
        for (NSString *name in homes) {
            VSDesktop *desktop = self->_desktops[name];
            // Other displays may slide into the gap, so check the screen itself rather than the rect.
            if (!desktop || [online containsObject:homes[name][0]]) continue;
            NSRect home = [homes[name][1] rectValue];
            [desktop.window setFrame:[desktop.window frameRectForContentRect:home] display:NO];
            [desktop.window orderOut:nil];
        }
    });
}
// Tests read the user's config only when they point VSCREEN_CONFIG at their own, as for hooks.
- (NSDictionary *)reloadDrawMouse {
    NSString *error = nil;
    _drawMouse = [self hooksEnabled] && VSLoadDrawMouse(&error);
    if (error) fprintf(stderr, "%s\n", error.UTF8String);
    for (VSDesktop *desktop in _desktops.allValues) desktop.drawsCursor = _drawMouse;
    return error ? VSFailure(error) : VSReply(@"");
}
- (BOOL)hooksEnabled {
    return !self.testMode || NSProcessInfo.processInfo.environment[@"VSCREEN_CONFIG"].length;
}
// Hooks react to other displays appearing, disappearing, or changing mode. Moves are ignored because
// layout scripts rearrange displays themselves, and VScreen's own displays are ignored for the same reason.
- (void)display:(CGDirectDisplayID)display changed:(CGDisplayChangeSummaryFlags)flags {
    CGDisplayChangeSummaryFlags relevant = kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplaySetModeFlag
        | kCGDisplayEnabledFlag | kCGDisplayDisabledFlag;
    if (_stopping || !(flags & relevant) || ![self hooksEnabled] || [_ownedIDs containsObject:@(display)]
        || CGDisplayVendorNumber(display) == 0x5653) return;
    // A connection arrives as a burst of callbacks; run once it settles.
    [_hookTimer invalidate];
    __weak VSController *weakSelf = self;
    _hookTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *timer) {
        (void)timer; [weakSelf runHooks:@"display-change"];
    }];
}
- (void)runHooks:(NSString *)event {
    if (_stopping) return;
    if (_hooksRunning) { _hooksPending = YES; return; }
    _hooksRunning = YES;
    VSRunHooksAsync(event, ^{
        self->_hooksRunning = NO;
        if (!self->_hooksPending) return;
        self->_hooksPending = NO;
        [self runHooks:@"display-change"];
    });
}
static OSStatus hotKey(EventHandlerCallRef handler, EventRef event, void *context) {
    (void)handler;
    EventHotKeyID key;
    OSStatus result = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(key), NULL, &key);
    if (result == noErr) [(__bridge VSController *)context handleHotKey:key.id];
    return result;
}
- (void)handleHotKey:(UInt32)key {
    if (key == 1) for (VSDesktop *desktop in _desktops.allValues) [desktop toggleTitleBar];
    if (key == 2) {
        BOOL anyVisible = NO;
        for (VSDesktop *desktop in _desktops.allValues) anyVisible |= desktop.window.visible;
        for (VSDesktop *desktop in _desktops.allValues)
            if (anyVisible) [desktop.window orderOut:nil]; else [desktop.window orderFrontRegardless];
    }
    if (key == 3) [self finish];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _desktops = [NSMutableDictionary new];
    _ownedIDs = [NSMutableSet new];
    _control = [VSControl new];
    NSString *error = nil;
    __weak VSController *weakSelf = self;
    if (![_control startAtDirectory:self.runtimeDirectory handler:^(NSArray *arguments, VSCompletion reply) {
        VSController *self = weakSelf;
        if (!self || self->_stopping || self->_quitting) { reply(VSFailure(@"VScreen is stopping.")); return; }
        __block BOOL responded = NO;
        [self handleArguments:arguments completion:^(NSDictionary *response) {
            if (responded) return;
            responded = YES;
            reply(response);
        }];
    } error:&error]) {
        int running = self.launchHooks ? VSConnect(self.runtimeDirectory) : -1;
        if (running >= 0) { close(running); [self finish]; return; }  // Already resident; nothing to do.
        fprintf(stderr, "%s\n", error.UTF8String); self.exitCode = 1; [self finish]; return;
    }
    if (!self.testMode) {
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        OSStatus status = InstallApplicationEventHandler(hotKey, 1, &spec, (__bridge void *)self, &_eventHandler);
        UInt32 keys[] = {kVK_ANSI_T, kVK_ANSI_H, kVK_ANSI_Q};
        for (int i = 0; status == noErr && i < 3; i++) {
            EventHotKeyID key = {'VScn', (UInt32)i + 1};
            status = RegisterEventHotKey(keys[i], cmdKey | optionKey, key, GetApplicationEventTarget(), 0, &_hotKeys[i]);
        }
        if (status != noErr) fprintf(stderr, "Some global shortcuts are unavailable; CLI control still works.\n");
    }
    CGDisplayRegisterReconfigurationCallback(displaysReconfigured, (__bridge void *)self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    if ([self hooksEnabled] && !VSEnsureConfig(&error)) fprintf(stderr, "%s\n", error.UTF8String);
    [self reloadDrawMouse];
    if (self.launchHooks && [self hooksEnabled]) [self runHooks:@"launch"];
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN);
    _interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    _terminate = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_interrupt, ^{ [weakSelf finish]; });
    dispatch_source_set_event_handler(_terminate, ^{ [weakSelf finish]; });
    dispatch_resume(_interrupt); dispatch_resume(_terminate);
}
- (NSDictionary *)details:(VSDesktop *)desktop name:(NSString *)name {
    CGDirectDisplayID display = desktop.display.displayID;
    return @{@"name": name, @"id": @(display), @"resolution": @[@(CGDisplayPixelsWide(display)), @(CGDisplayPixelsHigh(display))],
        @"size": sizeArray(contentRect(desktop.window).size), @"position": pointArray(previewPosition(desktop.window)),
        @"origin": pointArray(CGDisplayBounds(display).origin), @"main": @((BOOL)CGDisplayIsMain(display)), @"borderless": @((BOOL)!(desktop.window.styleMask & NSWindowStyleMaskTitled)),
        @"visible": @(desktop.window.visible), @"live": @(desktop.receivedFrame), @"windowLevel": @(desktop.window.level),
        @"borderColor": desktop.borderColor, @"shadow": @(desktop.window.hasShadow), @"hiPerf": @(desktop.hiPerf),
        @"captureError": desktop.captureError ?: NSNull.null};
}
- (NSString *)nameForSelector:(NSString *)selector {
    if (_desktops[selector]) return selector;
    NSInteger displayID;
    if (VSNumber(selector, 1, UINT32_MAX, &displayID)) {
        for (NSString *name in _desktops)
            if (_desktops[name].display.displayID == (CGDirectDisplayID)displayID) return name;
    }
    return nil;
}
// With main, the display goes to 0x0 (which makes it main) and every other display shifts by -origin in
// the same transaction, so the arrangement keeps its shape. This is the only path that moves displays
// VScreen does not own, and it only translates them; see "XREAL as the only display" in docs.
- (void)configure:(VSDesktop *)desktop origin:(CGPoint)origin main:(BOOL)main attempts:(NSUInteger)attempts completion:(void (^)(NSString *))completion {
    if (_stopping || !desktop.display) { completion(@"Desktop was closed."); return; }
    CGDirectDisplayID display = desktop.display.displayID;
    NSArray *online = VSOnlineDisplays();
    CGDisplayConfigRef config = NULL;
    CGError result = [online containsObject:@(display)] ? CGBeginDisplayConfiguration(&config) : kCGErrorCannotComplete;
    if (result == kCGErrorSuccess) result = CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay);
    if (result == kCGErrorSuccess) result = main ? CGConfigureDisplayOrigin(config, display, 0, 0)
        : CGConfigureDisplayOrigin(config, display, (int32_t)origin.x, (int32_t)origin.y);
    for (NSNumber *other in main ? online : @[]) {
        CGDirectDisplayID otherID = other.unsignedIntValue;
        if (result != kCGErrorSuccess) break;
        if (otherID == display || CGDisplayMirrorsDisplay(otherID) != kCGNullDirectDisplay) continue;
        CGRect bounds = CGDisplayBounds(otherID);
        result = CGConfigureDisplayOrigin(config, otherID, (int32_t)(bounds.origin.x - origin.x), (int32_t)(bounds.origin.y - origin.y));
    }
    if (result == kCGErrorSuccess) result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    else if (config) CGCancelDisplayConfiguration(config);
    if (result == kCGErrorSuccess) {
        if (main) [self awaitMain:display attempts:30 completion:completion]; else completion(nil);
        return;
    }
    if (attempts > 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
            [self configure:desktop origin:origin main:main attempts:attempts - 1 completion:completion];
        });
    } else completion([NSString stringWithFormat:@"Could not arrange display (CoreGraphics %d).", result]);
}
// Preview frames convert through NSScreen's first screen, which AppKit updates a little after CoreGraphics.
- (void)awaitMain:(CGDirectDisplayID)display attempts:(NSUInteger)attempts completion:(void (^)(NSString *))completion {
    NSNumber *first = NSScreen.screens.firstObject.deviceDescription[@"NSScreenNumber"];
    if (CGDisplayIsMain(display) && first.unsignedIntValue == display) { completion(nil); return; }
    if (attempts == 0) { completion(@"macOS did not make the display main."); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        [self awaitMain:display attempts:attempts - 1 completion:completion];
    });
}
- (void)capture:(VSDesktop *)desktop visible:(BOOL)visible completion:(void (^)(NSError *))completion {
    if (self.testMode) {
        if (visible) [desktop.window orderFrontRegardless]; else [desktop.window orderOut:nil];
        completion(nil); return;
    }
    [desktop startCaptureWithFPS:60 completion:^(NSError *error) {
        if (!visible) [desktop.window orderOut:nil];
        completion(error);
    }];
}
- (void)handleArguments:(NSArray *)arguments completion:(VSCompletion)reply {
    NSString *error = nil;
    NSDictionary *command = VSParseCommand(arguments, &error);
    if (!command) { reply(VSFailure(error)); return; }
    NSString *action = command[@"action"];
    NSArray *names = [_desktops.allKeys sortedArrayUsingSelector:@selector(compare:)];
    if ([action isEqual:@"list"]) {
        if ([command[@"json"] boolValue]) {
            NSMutableArray *details = [NSMutableArray new];
            for (NSString *name in names) [details addObject:[self details:_desktops[name] name:name]];
            reply(VSReply(VSJSON(details)));
        } else reply(VSReply([names componentsJoinedByString:@"\n"]));
        return;
    }
    if ([action isEqual:@"screens"]) { reply(VSScreenQuery(command, VSSystemDisplays())); return; }
    if ([action isEqual:@"check"]) {
        reply(VSReply(VSJSON(@{@"virtualDisplayAPI": @([VSDisplay isSupported]), @"screenRecording": @(CGPreflightScreenCaptureAccess()),
                              @"pid": @(getpid()), @"testMode": @(self.testMode)}))); return;
    }
    if ([action isEqual:@"permissions"]) {
        if (CGPreflightScreenCaptureAccess()) { reply(VSReply(@"VScreen already has Screen Recording permission.")); return; }
        CGRequestScreenCaptureAccess();  // Shows the system dialog only while the permission is undecided.
        reply(VSReply(@"Enable VScreen in System Settings → Privacy & Security → Screen & System Audio Recording, "
                      "then run vscreen quit before creating a desktop.\n"
                      "If no dialog appeared, open that pane yourself, or reset VScreen first: "
                      "tccutil reset ScreenCapture local.vscreen")); return;
    }
    if ([action isEqual:@"login"]) { reply([self loginItem:command[@"enable"]]); return; }
    if ([action isEqual:@"drawMouse"]) { reply([self reloadDrawMouse]); return; }
    if ([action isEqual:@"quit"]) {
        _quitting = YES;
        reply(VSReply(@""));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{ [self finish]; });
        return;
    }
    if ([action isEqual:@"close"]) {
        NSMutableArray *ids = [NSMutableArray new];
        for (NSString *selector in [command[@"all"] boolValue] ? names : command[@"names"]) {
            NSString *name = [self nameForSelector:selector];
            VSDesktop *desktop = name ? _desktops[name] : nil;
            if (!desktop) continue;
            [ids addObject:@(desktop.display.displayID)];
            [_desktops removeObjectForKey:name];
            [desktop stop];
        }
        [self awaitRemoval:ids attempts:50 completion:reply]; return;
    }
    if ([action isEqual:@"help"]) { reply(VSReply(VSUsage())); return; }
    if ([@[@"hooks", @"layout", @"generate"] containsObject:action]) {
        reply(VSFailure(@"This command runs in the vscreen client, not the app.")); return;
    }
    NSString *selector = command[@"name"];
    NSString *name = [action isEqual:@"new"] ? selector : [self nameForSelector:selector];
    VSDesktop *desktop = name ? _desktops[name] : nil;
    if ([action isEqual:@"new"]) {
        if (desktop) {
            if ([command[@"changes"] count]) [self update:desktop name:name changes:command[@"changes"] completion:reply];
            else reply(VSReply(@""));
            return;
        }
        if (_desktops.count >= 8) { reply(VSFailure(@"At most eight VScreen displays can be active.")); return; }
        if (!self.testMode && !CGPreflightScreenCaptureAccess()) {
            reply(VSFailure(@"VScreen needs Screen Recording permission. Run: vscreen --request-permissions\nIf an older build is already enabled, reset only VScreen with: tccutil reset ScreenCapture local.vscreen")); return;
        }
        [self create:name changes:command[@"changes"] completion:reply]; return;
    }
    if (!desktop) { reply(VSFailure([NSString stringWithFormat:@"No owned VScreen display matches %@. Create one with --new NAME first.", selector])); return; }
    if ([action isEqual:@"info"]) { reply(VSReply(VSJSON([self details:desktop name:name]))); return; }
    [self update:desktop name:name changes:command[@"changes"] completion:reply];
}
- (NSDictionary *)loginItem:(NSNumber *)enable {
    SMAppService *service = SMAppService.mainAppService;
    NSError *failure = nil;
    BOOL registered = service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval;
    if (enable && enable.boolValue != registered
        && !(enable.boolValue ? [service registerAndReturnError:&failure] : [service unregisterAndReturnError:&failure]))
        return VSFailure([NSString stringWithFormat:@"Cannot %@ login item: %@", enable.boolValue ? @"register" : @"remove",
                          failure.localizedDescription]);
    if (service.status == SMAppServiceStatusEnabled) return VSReply(@"enabled");
    if (service.status != SMAppServiceStatusRequiresApproval) return VSReply(@"disabled");
    [SMAppService openSystemSettingsLoginItems];
    return VSReply(@"requires-approval: allow VScreen in System Settings > General > Login Items");
}
- (void)awaitRemoval:(NSArray *)ids attempts:(NSUInteger)attempts completion:(VSCompletion)reply {
    NSArray *online = VSOnlineDisplays();
    BOOL removed = YES;
    for (NSNumber *display in ids) if ([online containsObject:display]) removed = NO;
    if (removed) { reply(VSReply(@"")); return; }
    if (attempts == 0) { reply(VSFailure(@"Display helpers exited but macOS has not yet confirmed disconnection.")); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        [self awaitRemoval:ids attempts:attempts - 1 completion:reply];
    });
}
- (void)create:(NSString *)name changes:(NSDictionary *)changes completion:(VSCompletion)reply {
    CGSize resolution = changes[@"resolution"] ? arraySize(changes[@"resolution"]) : CGSizeMake(1920, 1080);
    CGSize size = changes[@"size"] ? arraySize(changes[@"size"]) : CGSizeMake(960, 540);
    CGPoint position = changes[@"position"] ? arrayPoint(changes[@"position"]) : CGPointMake(40 + 32 * _desktops.count, 80 + 32 * _desktops.count);
    CGFloat right = 0;
    for (NSNumber *display in VSOnlineDisplays()) right = MAX(right, CGRectGetMaxX(CGDisplayBounds(display.unsignedIntValue)));
    CGPoint origin = changes[@"origin"] ? arrayPoint(changes[@"origin"]) : CGPointMake(right, 0);
    NSError *error = nil;
    VSDisplay *display = [[VSDisplay alloc] initWithName:name width:(NSUInteger)resolution.width height:(NSUInteger)resolution.height fps:60 error:&error];
    if (!display) { reply(VSFailure(error.localizedDescription)); return; }
    [_ownedIDs addObject:@(display.displayID)];
    VSDesktop *desktop = [[VSDesktop alloc] initWithDisplay:display name:name frame:previewRect(position, size)
        borderless:changes[@"borderless"] ? [changes[@"borderless"] boolValue] : YES level:CGWindowLevelForKey(kCGMaximumWindowLevelKey)];
    if (changes[@"borderColor"]) desktop.borderColor = changes[@"borderColor"];
    if (changes[@"shadow"]) desktop.window.hasShadow = [changes[@"shadow"] boolValue];
    if (changes[@"hiPerf"]) desktop.hiPerf = [changes[@"hiPerf"] boolValue];
    desktop.drawsCursor = _drawMouse;
    _desktops[name] = desktop;
    __weak VSController *weakSelf = self;
    desktop.onClose = ^(VSDesktop *closed) {
        VSController *self = weakSelf;
        if (self && self->_desktops[name] == closed) [self->_desktops removeObjectForKey:name];
    };
    BOOL main = [changes[@"main"] boolValue];
    [self configure:desktop origin:origin main:main attempts:30 completion:^(NSString *failure) {
        if (failure) { [self->_desktops removeObjectForKey:name]; [desktop stop]; reply(VSFailure(failure)); return; }
        // --position was given before the shift, so move it with the displays.
        if (main) [desktop.window setFrame:[desktop.window frameRectForContentRect:
            previewRect(arrayPoint(shifted(pointArray(position), origin)), size)] display:NO];
        BOOL visible = changes[@"visible"] ? [changes[@"visible"] boolValue] : YES;
        [self capture:desktop visible:visible completion:^(NSError *captureError) {
            if (captureError) {
                [self->_desktops removeObjectForKey:name]; [desktop stop]; reply(VSFailure(captureError.localizedDescription));
            } else reply(VSReply(@""));
        }];
    }];
}
- (void)applyPreviewChanges:(NSDictionary *)changes to:(VSDesktop *)desktop previous:(NSDictionary *)previous {
    if (changes[@"borderColor"]) desktop.borderColor = changes[@"borderColor"];
    BOOL borderless = changes[@"borderless"] ? [changes[@"borderless"] boolValue] : [previous[@"borderless"] boolValue];
    if (borderless == ((desktop.window.styleMask & NSWindowStyleMaskTitled) != 0)) [desktop toggleTitleBar];
    if (changes[@"shadow"]) desktop.window.hasShadow = [changes[@"shadow"] boolValue];
    if (changes[@"hiPerf"]) desktop.hiPerf = [changes[@"hiPerf"] boolValue];
    CGPoint position = arrayPoint(changes[@"position"] ?: previous[@"position"]);
    CGSize size = arraySize(changes[@"size"] ?: previous[@"size"]);
    [desktop.window setFrame:[desktop.window frameRectForContentRect:previewRect(position, size)] display:YES];
    BOOL visible = [(changes[@"visible"] ?: previous[@"visible"]) boolValue];
    if (visible) { [desktop.window deminiaturize:nil]; [desktop.window orderFrontRegardless]; }
    else [desktop.window orderOut:nil];
}
- (void)update:(VSDesktop *)desktop name:(NSString *)name changes:(NSDictionary *)changes completion:(VSCompletion)reply {
    NSDictionary *before = [self details:desktop name:name];
    BOOL resolutionChange = changes[@"resolution"] && ![changes[@"resolution"] isEqual:before[@"resolution"]];
    void (^apply)(void) = ^{
        if (self->_desktops[name] != desktop || !desktop.display) { reply(VSFailure(@"Desktop was closed.")); return; }
        NSError *modeError = nil;
        CGSize size = arraySize(changes[@"resolution"] ?: before[@"resolution"]);
        BOOL modeOK = !resolutionChange || [desktop.display setWidth:(NSUInteger)size.width height:(NSUInteger)size.height fps:60 error:&modeError];
        CGPoint origin = arrayPoint(changes[@"origin"] ?: before[@"origin"]);
        BOOL main = [changes[@"main"] boolValue];
        void (^finish)(NSString *) = ^(NSString *layoutError) {
            NSString *failure = modeOK ? layoutError : modeError.localizedDescription;
            if (failure && resolutionChange && modeOK) {
                CGSize previous = arraySize(before[@"resolution"]);
                NSError *rollbackError = nil;
                if (![desktop.display setWidth:(NSUInteger)previous.width height:(NSUInteger)previous.height fps:60 error:&rollbackError])
                    failure = [failure stringByAppendingFormat:@" Rollback also failed: %@", rollbackError.localizedDescription];
            }
            void (^complete)(NSError *) = ^(NSError *captureError) {
                if (!failure && !captureError) {
                    // Positions in this command, and the preview's old one, predate the shift; move them with the displays.
                    NSMutableDictionary *previous = [before mutableCopy], *moved = [changes mutableCopy];
                    if (main) {
                        previous[@"position"] = shifted(before[@"position"], origin);
                        if (changes[@"position"]) moved[@"position"] = shifted(changes[@"position"], origin);
                    }
                    [self applyPreviewChanges:moved to:desktop previous:previous];
                }
                reply(failure || captureError ? VSFailure(failure ?: captureError.localizedDescription) : VSReply(@""));
            };
            if (resolutionChange) [self capture:desktop visible:[before[@"visible"] boolValue] completion:complete];
            else complete(nil);
        };
        if (modeOK && (changes[@"origin"] || resolutionChange || main))
            [self configure:desktop origin:origin main:main attempts:30 completion:finish];
        else finish(nil);
    };
    if (resolutionChange && !self.testMode) [desktop pauseCapture:apply]; else apply();
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application {
    (void)application; [self finish]; return NSTerminateCancel;
}
- (void)finish {
    if (_stopping) return;
    _stopping = YES;
    [_hookTimer invalidate];
    CGDisplayRemoveReconfigurationCallback(displaysReconfigured, (__bridge void *)self);
    for (VSDesktop *desktop in _desktops.allValues) [desktop stop];
    [_desktops removeAllObjects];
    [_control stop];
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
        timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
}
- (void)dealloc {
    for (int i = 0; i < 3; i++) if (_hotKeys[i]) UnregisterEventHotKey(_hotKeys[i]);
    if (_eventHandler) RemoveEventHandler(_eventHandler);
    if (_interrupt) dispatch_source_cancel(_interrupt);
    if (_terminate) dispatch_source_cancel(_terminate);
}
@end
