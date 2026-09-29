#import <Foundation/Foundation.h>
// Lists or execs a user layout script; runs in the client, never the resident app.
int VSRunLayout(NSDictionary *command);
// Writes the embedded XREAL dual example into the layout directory; never overwrites edits.
int VSGenerateExample(void);
