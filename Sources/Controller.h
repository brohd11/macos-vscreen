#import <Cocoa/Cocoa.h>
#import "Control.h"
NSArray<NSNumber *> *VSOnlineDisplays(void);
NSArray<NSDictionary *> *VSSystemDisplays(void);
@interface VSController : NSObject <NSApplicationDelegate>
@property(nonatomic, copy) NSString *runtimeDirectory;
@property(nonatomic) BOOL testMode;
@property(nonatomic) BOOL launchHooks;  // Launched at login: run hooks once at startup.
@property(nonatomic) int exitCode;
@end
