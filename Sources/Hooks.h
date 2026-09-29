#import <Foundation/Foundation.h>
// ~/.vscreen/config.json, or VSCREEN_CONFIG. The hook log lives next to it.
NSString *VSConfigPath(void);
// Each hook is @[layoutName, args...]. A missing config means no hooks; nil means an invalid config.
NSArray<NSArray<NSString *> *> *VSLoadHooks(NSString **error);
// `vscreen hooks [--run]`: lists hooks, or runs them in the foreground. Client only.
int VSRunHooksCommand(NSDictionary *command);
// Runs the hooks one after another without blocking the main thread, appending output to the log.
void VSRunHooksAsync(NSString *event, void (^done)(void));
