#import <Cocoa/Cocoa.h>
#import "VirtualDisplay.h"

@interface VSWindow : NSPanel
@end

@interface VSDesktop : NSObject <NSWindowDelegate>
@property(nonatomic, readonly) VSDisplay *display;
@property(nonatomic, readonly) VSWindow *window;
@property(nonatomic, copy) void (^onClose)(VSDesktop *desktop);
@property(nonatomic, readonly) BOOL receivedFrame;
@property(nonatomic, copy, readonly) NSString *captureError;
@property(nonatomic, copy) NSString *borderColor;
@property(nonatomic) BOOL hiPerf;
// Draw the pointer in the preview at its screen's refresh instead of capturing it (~30 fps).
@property(nonatomic) BOOL drawsCursor;
- (instancetype)initWithDisplay:(VSDisplay *)display name:(NSString *)name frame:(NSRect)frame
                     borderless:(BOOL)borderless level:(NSInteger)level;
- (void)startCaptureWithFPS:(NSUInteger)fps completion:(void (^)(NSError *error))completion;
- (void)toggleTitleBar;
- (void)pauseCapture:(void (^)(void))completion;
- (void)stop;
@end
