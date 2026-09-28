#import <Foundation/Foundation.h>
NSDictionary *VSParseCommand(NSArray<NSString *> *arguments, NSString **error);
NSString *VSUsage(void);
BOOL VSNumber(NSString *text, NSInteger low, NSInteger high, NSInteger *value);
