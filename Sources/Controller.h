#import <Cocoa/Cocoa.h>
#import "Control.h"
NSArray<NSNumber *> *VSOnlineDisplays(void);
NSArray<NSDictionary *> *VSSystemDisplays(void);
@interface VSController : NSObject <NSApplicationDelegate>
@property(nonatomic, copy) NSString *runtimeDirectory;
@property(nonatomic) BOOL testMode;
@property(nonatomic) int exitCode;
@end
