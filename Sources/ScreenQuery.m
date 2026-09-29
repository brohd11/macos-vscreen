#import "ScreenQuery.h"
#import "Control.h"
#include <fnmatch.h>

NSDictionary *VSScreenQuery(NSDictionary *command, NSArray<NSDictionary *> *displays) {
    NSString *query = command[@"query"];
    if (!query) return VSReply(VSJSON(displays));
    NSArray *sorted = [displays sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]]];
    if ([query isEqual:@"list"]) {
        NSMutableArray *lines = [NSMutableArray new];
        for (NSDictionary *display in sorted)
            [lines addObject:[NSString stringWithFormat:@"%@\t%@", display[@"id"], display[@"name"]]];
        return VSReply([lines componentsJoinedByString:@"\n"]);
    }
    if ([query isEqual:@"find"] || [query isEqual:@"main"]) {
        for (NSDictionary *display in sorted) {
            BOOL match = [query isEqual:@"main"] ? [display[@"main"] boolValue]
                : fnmatch([command[@"pattern"] UTF8String], [display[@"name"] UTF8String], 0) == 0;
            if (match) return VSReply([display[@"id"] stringValue]);
        }
        return VSFailure([query isEqual:@"main"] ? @"No main display found."
            : [NSString stringWithFormat:@"No display matches %@.", command[@"pattern"]]);
    }
    for (NSDictionary *display in sorted) {
        if (![display[@"id"] isEqual:command[@"id"]]) continue;
        if ([query isEqual:@"detail"]) return VSReply(VSJSON(display));
        if ([query isEqual:@"name"] || [query isEqual:@"aspect"]) return VSReply(display[query]);
        NSArray *pair = display[query];
        return VSReply([NSString stringWithFormat:@"%@x%@", pair[0], pair[1]]);
    }
    return VSFailure([NSString stringWithFormat:@"No connected display with ID %@.", command[@"id"]]);
}
