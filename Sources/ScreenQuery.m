#import "ScreenQuery.h"
#import "Control.h"
#import <CoreGraphics/CoreGraphics.h>
#include <fnmatch.h>

// Usable desktop modes, largest logical size first; within a size, most backing pixels, then fastest refresh.
static NSArray *displayModes(CGDirectDisplayID display) {
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    NSArray *all = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options));
    NSMutableArray *modes = [NSMutableArray new];
    for (id mode in all)
        if (CGDisplayModeIsUsableForDesktopGUI((__bridge CGDisplayModeRef)mode)) [modes addObject:mode];
    return [modes sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        CGDisplayModeRef x = (__bridge CGDisplayModeRef)a, y = (__bridge CGDisplayModeRef)b;
        double keysX[] = {CGDisplayModeGetWidth(x), CGDisplayModeGetHeight(x), CGDisplayModeGetPixelWidth(x), CGDisplayModeGetRefreshRate(x)};
        double keysY[] = {CGDisplayModeGetWidth(y), CGDisplayModeGetHeight(y), CGDisplayModeGetPixelWidth(y), CGDisplayModeGetRefreshRate(y)};
        for (int i = 0; i < 4; i++)
            if (keysX[i] != keysY[i]) return keysX[i] > keysY[i] ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static NSString *modeSize(CGDisplayModeRef mode) {
    return [NSString stringWithFormat:@"%zux%zu", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
}

static NSDictionary *listModes(CGDirectDisplayID display) {
    NSMutableOrderedSet *sizes = [NSMutableOrderedSet new];
    for (id mode in displayModes(display)) [sizes addObject:modeSize((__bridge CGDisplayModeRef)mode)];
    return VSReply([sizes.array componentsJoinedByString:@"\n"]);
}

// Physical displays are changed only when a command asks, e.g. a hook restoring XREAL's full resolution.
static NSDictionary *setMode(CGDirectDisplayID display, id target) {
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
    if (!current) return VSFailure(@"Cannot read the display's current mode.");
    size_t currentWidth = CGDisplayModeGetWidth(current), currentHeight = CGDisplayModeGetHeight(current);
    CGDisplayModeRelease(current);
    CGDisplayModeRef chosen = NULL;
    for (id object in displayModes(display)) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)object;
        size_t width = CGDisplayModeGetWidth(mode), height = CGDisplayModeGetHeight(mode);
        BOOL match = [target isEqual:@"max"] ? width * currentHeight == height * currentWidth
            : width == [target[0] unsignedIntegerValue] && height == [target[1] unsignedIntegerValue];
        if (match) { chosen = mode; break; }
    }
    if (!chosen) return VSFailure([target isEqual:@"max"] ? @"The display has no usable mode at its current aspect ratio."
        : [NSString stringWithFormat:@"The display has no %@x%@ mode. Run --modes to list them.", target[0], target[1]]);
    NSString *size = modeSize(chosen);
    if (CGDisplayModeGetWidth(chosen) == currentWidth && CGDisplayModeGetHeight(chosen) == currentHeight) return VSReply(size);
    CGDisplayConfigRef config;
    CGError error = CGBeginDisplayConfiguration(&config);
    if (!error) {
        error = CGConfigureDisplayWithDisplayMode(config, display, chosen, NULL);
        error = error ? (CGCancelDisplayConfiguration(config), error) : CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    }
    return error ? VSFailure([NSString stringWithFormat:@"Cannot switch the display to %@ (CGError %d).", size, error]) : VSReply(size);
}

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
        CGDirectDisplayID displayID = [display[@"id"] unsignedIntValue];
        if ([query isEqual:@"modes"]) return listModes(displayID);
        if ([query isEqual:@"set-mode"]) return setMode(displayID, command[@"mode"]);
        if ([query isEqual:@"name"] || [query isEqual:@"aspect"]) return VSReply(display[query]);
        NSArray *pair = display[query];
        return VSReply([NSString stringWithFormat:@"%@x%@", pair[0], pair[1]]);
    }
    return VSFailure([NSString stringWithFormat:@"No connected display with ID %@.", command[@"id"]]);
}
