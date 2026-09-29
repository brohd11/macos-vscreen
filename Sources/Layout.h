#import <Foundation/Foundation.h>
NSString *VSLayoutDirectory(void);
// Resolves NAME or NAME.sh in directory to an executable file, or explains why not. kind is "layout" or "hook".
NSString *VSScriptPath(NSString *directory, NSString *kind, NSString *name, NSString **error);
NSString *VSLayoutPath(NSString *name, NSString **error);
// Executable script names in directory, without .sh, sorted and deduplicated.
NSArray<NSString *> *VSScriptNames(NSString *directory);
// Lists or execs a user layout script; runs in the client, never the resident app.
int VSRunLayout(NSDictionary *command);
// `vscreen generate [--list|PRESET]`: copies a bundled preset's hooks and layouts; never overwrites edits.
int VSGenerate(NSDictionary *command);
