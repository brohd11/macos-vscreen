#import "VirtualDisplay.h"
#import "Control.h"
#include <poll.h>

// Private CoreGraphics interfaces. Resolve classes dynamically so unsupported
// systems fail with a useful error rather than a missing-symbol loader failure.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) unsigned int vendorID, productID, serialNum;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, strong) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation VSDisplay {
    NSTask *_host;
    NSPipe *_lifetime;
    NSPipe *_reply;
    CGDirectDisplayID _displayID;
}
+ (BOOL)isSupported {
    NSDictionary *required = @{
        @"CGVirtualDisplayDescriptor": @[@"setName:", @"setQueue:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
            @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setSizeInMillimeters:",
            @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplaySettings": @[@"setHiDPI:", @"setModes:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"]
    };
    for (NSString *name in required) {
        Class cls = NSClassFromString(name);
        if (!cls) return NO;
        for (NSString *selector in required[name])
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return NO;
    }
    return YES;
}
- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height
                        fps:(NSUInteger)fps error:(NSError **)error {
    if (!(self = [super init])) return nil;
    NSString *failure = nil;
    if (![VSDisplay isSupported]) {
        failure = @"This macOS version does not expose the required CGVirtualDisplay API.";
    } else {
        _host = [NSTask new];
        _host.executableURL = NSBundle.mainBundle.executableURL;
        _host.arguments = @[@"--display-host", @(width).stringValue, @(height).stringValue, @(fps).stringValue, name];
        _lifetime = [NSPipe pipe];
        _reply = [NSPipe pipe];
        _host.standardInput = _lifetime;
        _host.standardOutput = _reply;
        NSError *launchError = nil;
        if (![_host launchAndReturnError:&launchError]) {
            failure = launchError.localizedDescription;
        } else {
            // The helper emits exactly one binary ID, then waits for pipe EOF.
            NSData *data = [_reply.fileHandleForReading readDataOfLength:sizeof(_displayID)];
            if (data.length == sizeof(_displayID)) [data getBytes:&_displayID length:sizeof(_displayID)];
            if (!_displayID) failure = @"WindowServer refused the virtual display or its requested mode.";
        }
    }
    if (failure) {
        [self invalidate];
        if (error) *error = [NSError errorWithDomain:@"VScreen" code:1
                                          userInfo:@{NSLocalizedDescriptionKey: failure}];
        return nil;
    }
    return self;
}
- (CGDirectDisplayID)displayID { return _displayID; }
- (BOOL)setWidth:(NSUInteger)width height:(NSUInteger)height fps:(NSUInteger)fps error:(NSError **)error {
    NSDictionary *response = nil;
    if (_host.running && VSWriteMessage(_lifetime.fileHandleForWriting.fileDescriptor,
                                        @{@"width": @(width), @"height": @(height), @"fps": @(fps)}))
        response = VSReadMessage(_reply.fileHandleForReading.fileDescriptor);
    if ([response[@"ok"] boolValue]) return YES;
    if (error) *error = [NSError errorWithDomain:@"VScreen" code:3 userInfo:@{
        NSLocalizedDescriptionKey: response[@"error"] ?: @"Display helper did not respond to the resolution change."}];
    return NO;
}
- (void)invalidate {
    [_lifetime.fileHandleForWriting closeFile];
    _lifetime = nil;
    if (_host.running) [_host waitUntilExit];
    [_reply.fileHandleForReading closeFile];
    _reply = nil;
    _host = nil;
    _displayID = 0;
}
- (void)dealloc { [self invalidate]; }
@end

static BOOL applyMode(CGVirtualDisplay *display, NSUInteger width, NSUInteger height, NSUInteger fps) {
    CGVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI = 0;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                       initWithWidth:width height:height refreshRate:fps]];
    if (![display applySettings:settings]) return NO;
    for (int attempt = 0; attempt < 30; attempt++) {
        if (CGDisplayPixelsWide(display.displayID) == width && CGDisplayPixelsHigh(display.displayID) == height) return YES;
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(display.displayID, NULL);
        if (modes) {
            for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                if (CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height) {
                    CGDisplaySetDisplayMode(display.displayID, mode, NULL); break;
                }
            }
            CFRelease(modes);
        }
        usleep(50000);
    }
    return CGDisplayPixelsWide(display.displayID) == width && CGDisplayPixelsHigh(display.displayID) == height;
}

// macOS keys a display's identity (and its generated ColorSync profile) on vendor/product/serial.
// A stable per-name serial reuses one profile per name instead of leaving a new one on every launch.
static uint32_t serialForName(NSString *name) {
    uint32_t hash = 2166136261u;  // FNV-1a
    for (const char *c = name.UTF8String; *c; c++) hash = (hash ^ (uint8_t)*c) * 16777619u;
    return hash ?: 1;
}

int VSRunDisplayHost(NSString *name, NSUInteger width, NSUInteger height, NSUInteger fps) {
    if (![VSDisplay isSupported]) return 1;
    CGVirtualDisplayDescriptor *descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    descriptor.name = name;
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.maxPixelsWide = 7680;
    descriptor.maxPixelsHigh = 4320;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110, height * 25.4 / 110);
    descriptor.vendorID = 0x5653;
    descriptor.productID = 1;
    descriptor.serialNum = serialForName(name);
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    __attribute__((objc_precise_lifetime)) CGVirtualDisplay *display =
        [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display || !applyMode(display, width, height, fps)) return 1;
    CGDirectDisplayID displayID = display.displayID;
    if (write(STDOUT_FILENO, &displayID, sizeof(displayID)) != sizeof(displayID)) return 1;
    for (;;) {
        struct pollfd pipe = {.fd = STDIN_FILENO, .events = POLLIN};
        int ready = poll(&pipe, 1, -1);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) break;
        NSDictionary *request = VSReadMessage(STDIN_FILENO);
        if (!request) break;
        NSUInteger nextW = [request[@"width"] unsignedIntegerValue], nextH = [request[@"height"] unsignedIntegerValue];
        NSUInteger nextFPS = [request[@"fps"] unsignedIntegerValue];
        BOOL valid = nextW >= 480 && nextW <= 7680 && nextH >= 480 && nextH <= 4320 && nextFPS >= 1 && nextFPS <= 120;
        BOOL changed = valid && applyMode(display, nextW, nextH, nextFPS);
        if (changed) { width = nextW; height = nextH; fps = nextFPS; }
        else if (valid) applyMode(display, width, height, fps);
        if (!VSWriteMessage(STDOUT_FILENO, changed ? VSReply(@"") : VSFailure(@"macOS refused the requested resolution; the previous mode was restored."))) break;
    }
    // Process exit reliably tears down only this connection's virtual display.
    // Releasing the private object alone is unreliable on some macOS versions.
    _exit(0);
}
