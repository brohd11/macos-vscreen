#import <Foundation/Foundation.h>
NSString *VSLayoutDirectory(void);
// Resolves NAME or NAME.sh in the layout directory to an executable file, or explains why not.
NSString *VSLayoutPath(NSString *name, NSString **error);
// Lists or execs a user layout script; runs in the client, never the resident app.
int VSRunLayout(NSDictionary *command);
// Writes the embedded XREAL dual example into the layout directory; never overwrites edits.
int VSGenerateExample(void);
