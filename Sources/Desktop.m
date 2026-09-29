#import "Desktop.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>

@implementation VSWindow
// AppKit normally keeps titled windows below the menu bar. This is intentional
// for these desktop surfaces, including during interactive dragging.
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen {
    (void)screen;
    return frame;
}
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (BOOL)isOpaque { return YES; }
@end

@interface VSPreview : NSView
@property(nonatomic, strong) CALayer *surface;
@property(nonatomic, strong) AVSampleBufferDisplayLayer *video;
@property(nonatomic) BOOL hiPerf;
@property(nonatomic, strong) NSTextField *message;
@property(nonatomic, strong) CALayer *outline;
@property(nonatomic, strong) CALayer *cursor;
@property(nonatomic, copy) NSString *borderColor;
@end

@implementation VSPreview
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.blackColor.CGColor;
    // Opaque layers let WindowServer skip blending whatever is behind a preview.
    self.layer.opaque = YES;
    // By default frames go straight onto a plain layer. An AVSampleBufferDisplayLayer paces frames
    // more smoothly, but even an idle one keeps WindowServer compositing every refresh (~18% CPU per
    // window, measured 2026-09-28), so it exists only while hi-perf is on.
    _surface = [CALayer new];
    _surface.opaque = YES;
    _surface.contentsGravity = kCAGravityResizeAspect;
    [self.layer addSublayer:_surface];
    _outline = [CALayer new];
    _outline.zPosition = 1;
    [self.layer addSublayer:_outline];
    _cursor = [CALayer new];
    _cursor.zPosition = 0.5;
    _cursor.hidden = YES;
    _cursor.contentsGravity = kCAGravityResize;
    [self.layer addSublayer:_cursor];
    self.borderColor = @"none";
    _message = [NSTextField wrappingLabelWithString:@"Starting desktop…"];
    _message.textColor = NSColor.whiteColor;
    _message.alignment = NSTextAlignmentCenter;
    [self addSubview:_message];
    return self;
}
- (void)setBorderColor:(NSString *)borderColor {
    _borderColor = [borderColor copy];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _outline.hidden = [borderColor isEqual:@"none"];
    if (!_outline.hidden) {
        unsigned int rgb = 0;
        [[NSScanner scannerWithString:[borderColor substringFromIndex:1]] scanHexInt:&rgb];
        _outline.borderColor = [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
            green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1].CGColor;
    }
    [CATransaction commit];
    self.needsLayout = YES;
}
- (void)setHiPerf:(BOOL)hiPerf {
    if (hiPerf == _hiPerf) return;
    _hiPerf = hiPerf;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (hiPerf) {
        _video = [AVSampleBufferDisplayLayer new];
        _video.opaque = YES;
        _video.videoGravity = AVLayerVideoGravityResizeAspect;
        _video.frame = self.bounds;
        [self.layer insertSublayer:_video below:_outline];
        _surface.contents = nil;
    } else {
        [_video flushAndRemoveImage];
        [_video removeFromSuperlayer];
        _video = nil;
    }
    [CATransaction commit];
}
- (BOOL)isOpaque { return YES; }
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.needsLayout = YES;
}
- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _surface.frame = self.bounds;
    _video.frame = self.bounds;
    _outline.frame = self.bounds;
    CGFloat scale = self.window.backingScaleFactor ?: 1;
    _outline.contentsScale = scale;
    _outline.borderWidth = 1 / scale;
    [CATransaction commit];
    _message.frame = NSInsetRect(self.bounds, 24, MAX(24, self.bounds.size.height / 2 - 30));
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagOption) {
        [self.window performWindowDragWithEvent:event];
    }
}
@end

@interface VSDesktop () <SCStreamOutput, SCStreamDelegate>
@end

@implementation VSDesktop {
    VSDisplay *_display;
    VSWindow *_window;
    VSPreview *_preview;
    SCStream *_stream;
    NSUInteger _fps;
    BOOL _stopped;
    BOOL _receivedFrame;
    NSString *_captureError;
    void (^_captureCompletion)(NSError *error);
    // With drawsCursor the preview draws the pointer itself at the host screen's refresh:
    // ScreenCaptureKit sends cursor-only changes at ~30 fps. Idles at a low rate until the pointer
    // enters this display.
    BOOL _drawsCursor;
    CADisplayLink *_cursorLink;
    NSData *_cursorPixels;
    NSUInteger _cursorTick;
    // Frames arrive on this queue, not main, so AppKit work never delays them. Only this queue
    // touches the ivars below and the preview's frame layers; main reaches them via dispatch_sync.
    dispatch_queue_t _captureQueue;
    id _frame;  // The shown sample: keeps its surface from being reused, and redraws it on a mode switch.
    BOOL _frameShown;
}
- (VSDisplay *)display { return _display; }
- (VSWindow *)window { return _window; }
- (BOOL)receivedFrame { return _receivedFrame; }
- (NSString *)captureError { return _captureError; }
- (NSString *)borderColor { return _preview.borderColor; }
- (void)setBorderColor:(NSString *)borderColor { _preview.borderColor = borderColor; }
- (BOOL)hiPerf { return _preview.hiPerf; }
- (BOOL)drawsCursor { return _drawsCursor; }
- (void)setDrawsCursor:(BOOL)drawsCursor {
    if (drawsCursor == _drawsCursor || _stopped) return;
    _drawsCursor = drawsCursor;
    if (drawsCursor) {
        _cursorLink = [_preview displayLinkWithTarget:self selector:@selector(trackCursor:)];
        _cursorLink.preferredFrameRateRange = CAFrameRateRangeMake(10, 10, 10);
        _cursorLink.paused = (_window.occlusionState & NSWindowOcclusionStateVisible) == 0;
        [_cursorLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else {
        [_cursorLink invalidate];  // It retains self.
        _cursorLink = nil;
        [self setCursorShown:NO];
    }
    [self updateStreamConfiguration];
}
- (void)setHiPerf:(BOOL)hiPerf {
    if (hiPerf == _preview.hiPerf) return;
    // Synchronous, so main-thread layout never sees the video layer half swapped.
    dispatch_sync(_captureQueue, ^{
        self->_preview.hiPerf = hiPerf;
        if (self->_frame) [self showSample:(__bridge CMSampleBufferRef)self->_frame];
    });
}
- (instancetype)initWithDisplay:(VSDisplay *)display name:(NSString *)name frame:(NSRect)frame
                     borderless:(BOOL)borderless level:(NSInteger)level {
    if (!(self = [super init])) return nil;
    _display = display;
    _captureQueue = dispatch_queue_create("local.vscreen.capture",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    NSWindowStyleMask style = NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskResizable;
    if (!borderless) style |= NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    _window = [[VSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    _window.title = name;
    _window.level = level;
    _window.releasedWhenClosed = NO;
    _window.hidesOnDeactivate = NO;
    _window.hasShadow = NO;
    _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
    _window.contentMinSize = NSMakeSize(240, 135);
    _window.delegate = self;
    _window.backgroundColor = NSColor.blackColor;
    _preview = [[VSPreview alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    _window.contentView = _preview;
    return self;
}
- (void)startCaptureWithFPS:(NSUInteger)fps completion:(void (^)(NSError *))completion {
    _fps = fps;
    _captureCompletion = completion;
    _captureError = nil;
    _receivedFrame = NO;
    _preview.message.hidden = NO;
    _preview.message.stringValue = @"Starting desktop…";
    [self findDisplayWithFPS:fps attempts:50 completion:^(NSError *error) {
        void (^done)(NSError *) = self->_captureCompletion;
        self->_captureCompletion = nil;
        if (done) done(error);
    }];
}
// Call after removing the stream output: the sync runs behind any frame already queued.
- (void)clearFrame {
    dispatch_sync(_captureQueue, ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self->_preview.surface.contents = nil;
        [CATransaction commit];
        [self->_preview.video flushAndRemoveImage];
        self->_frame = nil;
        self->_frameShown = NO;
    });
}
- (void)pauseCapture:(void (^)(void))completion {
    SCStream *old = _stream;
    _stream = nil;
    _receivedFrame = NO;
    [old removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    [self clearFrame];
    if (!old) { completion(); return; }
    [old stopCaptureWithCompletionHandler:^(NSError *error) {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), completion);
    }];
}
- (void)findDisplayWithFPS:(NSUInteger)fps attempts:(NSUInteger)attempts completion:(void (^)(NSError *))completion {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_stopped) return;
            if (error) { completion(error); return; }
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays)
                if (candidate.displayID == self->_display.displayID) { display = candidate; break; }
            if (!display) {
                if (attempts > 1) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
                        [self findDisplayWithFPS:fps attempts:attempts - 1 completion:completion];
                    });
                } else {
                    completion([NSError errorWithDomain:@"VScreen" code:2 userInfo:@{
                        NSLocalizedDescriptionKey: @"The new display did not appear in ScreenCaptureKit."}]);
                }
                return;
            }
            NSMutableArray *excluded = [NSMutableArray new];
            for (SCRunningApplication *app in content.applications)
                if (app.processID == getpid()) [excluded addObject:app];
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                excludingApplications:excluded exceptingWindows:@[]];
            self->_stream = [[SCStream alloc] initWithFilter:filter configuration:[self streamConfiguration] delegate:self];
            NSError *outputError = nil;
            if (![self->_stream addStreamOutput:self type:SCStreamOutputTypeScreen
                            sampleHandlerQueue:self->_captureQueue error:&outputError]) {
                completion(outputError); return;
            }
            [self->_stream startCaptureWithCompletionHandler:^(NSError *startError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_stopped) return;
                    if (!startError) [self->_window orderFrontRegardless];
                    completion(startError);
                });
            }];
        });
    }];
}
// Capture only the pixels the preview can show, and trickle frames while it cannot be seen
// (hidden, off-screen, or covered), so WindowServer is not compositing frames nobody sees.
- (SCStreamConfiguration *)streamConfiguration {
    CGDirectDisplayID display = _display.displayID;
    double displayW = CGDisplayPixelsWide(display), displayH = CGDisplayPixelsHigh(display);
    NSSize backing = [_preview convertSizeToBacking:_preview.bounds.size];
    double scale = MIN(1, MIN(backing.width / displayW, backing.height / displayH));
    BOOL seen = (_window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    configuration.width = (size_t)MAX(2, round(displayW * scale));
    configuration.height = (size_t)MAX(2, round(displayH * scale));
    // A visible preview takes every display update; the virtual display's refresh caps the rate.
    // An interval of exactly 1/refresh made SCK drop any frame whose vsync landed a hair early.
    configuration.minimumFrameInterval = seen ? kCMTimeZero : CMTimeMake(1, 1);
    // Room for the shown frame, the one WindowServer may still be compositing, and new ones.
    configuration.queueDepth = 5;
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    configuration.showsCursor = !_drawsCursor;  // Otherwise trackCursor: draws it.
    configuration.capturesAudio = NO;
    configuration.scalesToFit = YES;
    return configuration;
}
- (void)updateStreamConfiguration {
    if (_stopped || !_stream) return;
    [_stream updateConfiguration:[self streamConfiguration] completionHandler:^(NSError *error) {
        if (error) fprintf(stderr, "Capture update failed: %s\n", error.localizedDescription.UTF8String);
    }];
}
- (void)scheduleStreamUpdate {
    // Live resizing fires continuously; reconfigure once it settles.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateStreamConfiguration) object:nil];
    [self performSelector:@selector(updateStreamConfiguration) withObject:nil afterDelay:0.2];
}
- (void)windowDidResize:(NSNotification *)notification { (void)notification; [self scheduleStreamUpdate]; }
- (void)windowDidChangeBackingProperties:(NSNotification *)notification { (void)notification; [self scheduleStreamUpdate]; }
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    (void)notification;
    _cursorLink.paused = (_window.occlusionState & NSWindowOcclusionStateVisible) == 0;
    [self updateStreamConfiguration];
}
- (void)setCursorShown:(BOOL)shown {
    CALayer *cursor = _preview.cursor;
    if (cursor.hidden != shown) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    cursor.hidden = !shown;
    [CATransaction commit];
    _cursorLink.preferredFrameRateRange = shown ? CAFrameRateRangeDefault : CAFrameRateRangeMake(10, 10, 10);
}
- (void)refreshCursorImage:(CGFloat)scale {
    NSCursor *system = NSCursor.currentSystemCursor;
    NSImage *image = system.image;
    NSBitmapImageRep *best = nil;
    for (NSImageRep *rep in image.representations)
        if ([rep isKindOfClass:NSBitmapImageRep.class] && rep.pixelsWide > best.pixelsWide) best = (NSBitmapImageRep *)rep;
    CGImageRef pixels = best.CGImage;
    if (!pixels) return;
    // A fresh NSCursor comes back on every call, so compare pixels to spot a shape change.
    NSData *data = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(pixels)));
    CALayer *cursor = _preview.cursor;
    CGSize size = NSMakeSize(image.size.width * scale, image.size.height * scale);
    if ([data isEqual:_cursorPixels] && CGSizeEqualToSize(cursor.bounds.size, size)) return;
    _cursorPixels = data;
    NSPoint hot = system.hotSpot;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    cursor.contents = (__bridge id)pixels;
    cursor.bounds = CGRectMake(0, 0, size.width, size.height);
    cursor.anchorPoint = CGPointMake(hot.x / image.size.width, 1 - hot.y / image.size.height);
    [CATransaction commit];
}
- (void)trackCursor:(CADisplayLink *)link {
    (void)link;
    CGEventRef event = CGEventCreate(NULL);
    CGPoint pointer = event ? CGEventGetLocation(event) : CGPointMake(-INFINITY, -INFINITY);
    if (event) CFRelease(event);
    CGRect screen = CGDisplayBounds(_display.displayID);
    if (!_receivedFrame || CGRectIsEmpty(screen) || !CGRectContainsPoint(screen, pointer)) {
        [self setCursorShown:NO];
        return;
    }
    // Map like the frame's aspect fit: centred, uniformly scaled; layers are bottom-left origin.
    NSRect bounds = _preview.bounds;
    CGFloat scale = MIN(bounds.size.width / screen.size.width, bounds.size.height / screen.size.height);
    if (_preview.cursor.hidden || _cursorTick++ % 2 == 0) [self refreshCursorImage:scale];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _preview.cursor.position = CGPointMake(NSMidX(bounds) + (pointer.x - CGRectGetMidX(screen)) * scale,
                                           NSMidY(bounds) - (pointer.y - CGRectGetMidY(screen)) * scale);
    [CATransaction commit];
    [self setCursorShown:YES];
}
- (BOOL)showSample:(CMSampleBufferRef)sample {
    AVSampleBufferDisplayLayer *video = _preview.video;
    if (video) {
        if (video.status == AVQueuedSampleBufferRenderingStatusFailed) [video flush];
        if (!video.readyForMoreMediaData) return NO;
        CFArrayRef array = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(array, 0),
                             kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        [video enqueueSampleBuffer:sample];
    } else {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
        IOSurfaceRef surface = buffer ? CVPixelBufferGetIOSurface(buffer) : NULL;
        if (!surface) return NO;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _preview.surface.contents = (__bridge id)surface;
        [CATransaction commit];
    }
    _frame = (__bridge id)sample;
    return YES;
}
// Runs on _captureQueue. A stale stream's frames are harmless: pause/stop remove the output and then
// clear the frame behind any that were already queued.
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (_stopped || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments.count == 0 || !attachments[0][SCStreamFrameInfoStatus]
        || [attachments[0][SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
    if (![self showSample:sample]) return;
    if (_frameShown) return;
    _frameShown = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_stopped || stream != self->_stream) return;
        if (!self->_receivedFrame) {
            printf("%s: live preview ready\n", self->_window.title.UTF8String);
            fflush(stdout);
        }
        self->_receivedFrame = YES;
        self->_preview.message.hidden = YES;
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_stopped || stream != self->_stream) return;
        self->_captureError = error.localizedDescription;
        self->_receivedFrame = NO;
        self->_preview.message.stringValue = @"Capture stopped. Close and relaunch VScreen.";
        self->_preview.message.hidden = NO;
        fprintf(stderr, "Capture stopped for %s: %s\n", self->_window.title.UTF8String, error.localizedDescription.UTF8String);
    });
}
- (void)toggleTitleBar {
    NSRect content = [_window contentRectForFrameRect:_window.frame];
    BOOL shadow = _window.hasShadow;
    NSWindowStyleMask style = _window.styleMask;
    NSWindowStyleMask chrome = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    _window.styleMask = (style & NSWindowStyleMaskTitled) ? (style & ~chrome) : (style | chrome);
    _window.hasShadow = shadow;
    [_window setFrame:[_window frameRectForContentRect:content] display:YES];
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (_stopped) return;
    [self stop];
    if (_onClose) _onClose(self);
}
- (void)stop {
    if (_stopped) return;
    _stopped = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_cursorLink invalidate];  // It retains self.
    _cursorLink = nil;
    void (^done)(NSError *) = _captureCompletion;
    _captureCompletion = nil;
    if (done) done([NSError errorWithDomain:@"VScreen" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Desktop closed during capture startup."}]);
    [_window orderOut:nil];
    [_stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
    [_stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    _stream = nil;
    [self clearFrame];
    [_display invalidate];
    _display = nil;
}
@end
