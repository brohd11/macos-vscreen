#import <Foundation/Foundation.h>
// ~/.vscreen/config.yaml, or VSCREEN_CONFIG. The hook log and hooks/ directory live next to it.
NSString *VSConfigPath(void);
NSString *VSHookDirectory(void);
// Creates the config directory, hooks/, layout/, and a starter config if missing; never overwrites.
BOOL VSEnsureConfig(NSString **error);
// Each hook is @[hookName, args...]. A missing config means no hooks; nil means an invalid config.
NSArray<NSArray<NSString *> *> *VSLoadHooks(NSString **error);
// The config's top-level drawMouse (true/false); missing means NO. Sets *error when invalid.
BOOL VSLoadDrawMouse(NSString **error);
// `vscreen --draw-mouse` / `--no-draw-mouse`: edits drawMouse in the config in place. Client only.
int VSSetDrawMouse(BOOL enable);
// `vscreen hooks [--run|--list|--enable NAME|--disable NAME]`. Client only.
int VSRunHooksCommand(NSDictionary *command);
// Runs the hooks one after another without blocking the main thread, appending output to the log.
void VSRunHooksAsync(NSString *event, void (^done)(void));
