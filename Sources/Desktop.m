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
@end

@interface VSPreview : NSView
@property(nonatomic, strong) AVSampleBufferDisplayLayer *video;
@property(nonatomic, strong) NSTextField *message;
@property(nonatomic, strong) CALayer *outline;
@property(nonatomic, copy) NSString *borderColor;
@end

@implementation VSPreview
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.blackColor.CGColor;
    _video = [AVSampleBufferDisplayLayer new];
    _video.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.layer addSublayer:_video];
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
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.needsLayout = YES;
}
- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
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
    BOOL _stopped;
    BOOL _receivedFrame;
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
- (void)pauseCapture:(void (^)(void))completion {
    SCStream *old = _stream;
    _stream = nil;
    _receivedFrame = NO;
    [old removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    [_preview.video flushAndRemoveImage];
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
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = CGDisplayPixelsWide(display.displayID);
            configuration.height = CGDisplayPixelsHigh(display.displayID);
            configuration.minimumFrameInterval = CMTimeMake(1, (int32_t)fps);
            configuration.queueDepth = 3;
            configuration.pixelFormat = kCVPixelFormatType_32BGRA;
            configuration.showsCursor = YES;
            configuration.capturesAudio = NO;
            configuration.scalesToFit = YES;
            self->_stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
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
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (_stopped || stream != _stream || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments.count == 0 || !attachments[0][SCStreamFrameInfoStatus]
        || [attachments[0][SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
    if (_preview.video.status == AVQueuedSampleBufferRenderingStatusFailed) [_preview.video flush];
    if (!_preview.video.readyForMoreMediaData) return;
    CFArrayRef array = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(array, 0),
                         kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    [_preview.video enqueueSampleBuffer:sample];
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
    void (^done)(NSError *) = _captureCompletion;
    _captureCompletion = nil;
    if (done) done([NSError errorWithDomain:@"VScreen" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Desktop closed during capture startup."}]);
    [_window orderOut:nil];
    [_stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
    [_stream removeStreamOutput:self type:SCStreamOutputTypeScreen error:nil];
    _stream = nil;
    [_preview.video flushAndRemoveImage];
    [_display invalidate];
    _display = nil;
}
@end
