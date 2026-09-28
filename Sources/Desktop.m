#import "Desktop.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>

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
@property(nonatomic, strong) NSTextField *message;
@property(nonatomic, strong) CALayer *outline;
@property(nonatomic, copy) NSString *borderColor;
@end

@implementation VSPreview
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.blackColor.CGColor;
    // Opaque layers let WindowServer skip blending whatever is behind a preview.
    self.layer.opaque = YES;
    // Frames go straight onto a plain layer. An AVSampleBufferDisplayLayer, even an idle one,
    // keeps WindowServer compositing every refresh (~18% CPU per window, measured 2026-09-28).
    _surface = [CALayer new];
    _surface.opaque = YES;
    _surface.contentsGravity = kCAGravityResizeAspect;
    [self.layer addSublayer:_surface];
    _outline = [CALayer new];
    _outline.zPosition = 1;
    [self.layer addSublayer:_outline];
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
    id _frame;  // Holds the shown frame's surface until the next one replaces it.
    NSString *_captureError;
    void (^_captureCompletion)(NSError *error);
}
- (VSDisplay *)display { return _display; }
- (VSWindow *)window { return _window; }
- (BOOL)receivedFrame { return _receivedFrame; }
- (NSString *)captureError { return _captureError; }
- (NSString *)borderColor { return _preview.borderColor; }
- (void)setBorderColor:(NSString *)borderColor { _preview.borderColor = borderColor; }
- (instancetype)initWithDisplay:(VSDisplay *)display name:(NSString *)name frame:(NSRect)frame
                     borderless:(BOOL)borderless level:(NSInteger)level {
    if (!(self = [super init])) return nil;
    _display = display;
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
- (void)clearFrame {
    _preview.surface.contents = nil;
    _frame = nil;
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
                            sampleHandlerQueue:dispatch_get_main_queue() error:&outputError]) {
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
    configuration.minimumFrameInterval = seen ? CMTimeMake(1, (int32_t)MAX(_fps, 1)) : CMTimeMake(1, 1);
    configuration.queueDepth = 3;
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    configuration.showsCursor = YES;
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
- (void)windowDidChangeOcclusionState:(NSNotification *)notification { (void)notification; [self updateStreamConfiguration]; }
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (_stopped || stream != _stream || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments.count == 0 || !attachments[0][SCStreamFrameInfoStatus]
        || [attachments[0][SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    IOSurfaceRef surface = buffer ? CVPixelBufferGetIOSurface(buffer) : NULL;
    if (!surface) return;
    // Keep the sample alive so ScreenCaptureKit does not reuse its surface while it is on screen.
    _frame = (__bridge id)sample;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _preview.surface.contents = (__bridge id)surface;
    [CATransaction commit];
    if (!_receivedFrame) {
        printf("%s: live preview ready\n", _window.title.UTF8String);
        fflush(stdout);
    }
    _receivedFrame = YES;
    _preview.message.hidden = YES;
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
