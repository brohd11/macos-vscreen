#import <Cocoa/Cocoa.h>

@interface VSDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (BOOL)isSupported;
- (instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height
                        fps:(NSUInteger)fps error:(NSError **)error;
- (void)invalidate;
- (BOOL)setWidth:(NSUInteger)width height:(NSUInteger)height fps:(NSUInteger)fps error:(NSError **)error;
@end

// Internal child-process entry point. The parent holds stdin open as a lifetime
// lease, so even an ungraceful parent exit disconnects this helper's display.
int VSRunDisplayHost(NSString *name, NSUInteger width, NSUInteger height, NSUInteger fps);
