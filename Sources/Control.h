#import <Foundation/Foundation.h>
NSString *VSRuntimeDirectory(void);
NSString *VSJSON(id object);
NSDictionary *VSReadMessage(int fd);
BOOL VSWriteMessage(int fd, NSDictionary *message);
int VSConnect(NSString *directory);
NSDictionary *VSReply(NSString *output);
NSDictionary *VSFailure(NSString *message);

typedef void (^VSCompletion)(NSDictionary *reply);
typedef void (^VSRequestHandler)(NSArray *arguments, VSCompletion reply);
@interface VSControl : NSObject
- (BOOL)startAtDirectory:(NSString *)directory handler:(VSRequestHandler)handler error:(NSString **)error;
- (void)stop;
@end
