#import "Command.h"

NSString *VSUsage(void) {
    return @"Usage:\n"
      "  vscreen --new NAME [settings]     Create a desktop, or apply settings to the existing one\n"
      "  vscreen NAME|ID [settings]        Update an owned desktop, or show its JSON details\n"
      "  vscreen NAME|ID --close           Close one owned desktop (missing target is a no-op)\n"
      "  vscreen --list [--json]           Owned names, one per line; optional detailed JSON\n"
      "  vscreen close                    Close all owned desktops; keep app running (alias: --close)\n"
      "  vscreen screens                  All macOS displays as JSON (alias: --screens)\n"
      "  vscreen screens --list           Display IDs and names, tab-separated\n"
      "  vscreen screens --find 'GLOB'    First matching display ID (case-sensitive name glob)\n"
      "  vscreen screens --main           Main display ID\n"
      "  vscreen screens ID               JSON details for a system display\n"
      "  vscreen screens ID --name        Display name\n"
      "  vscreen screens ID --origin      Display origin as XxY\n"
      "  vscreen screens ID --size        Logical display size as WxH\n"
      "  vscreen layout NAME [ARGS...]    Run layout script NAME[.sh] from ~/.vscreen/layout (alias: --layout)\n"
      "  vscreen layout --list            Available layout names\n"
      "  vscreen --check                  Report the app's Screen Recording permission\n"
      "  vscreen --request-permissions    Request Screen Recording for VScreen\n"
      "  vscreen quit                     Close all owned desktops and stop app (alias: --quit)\n"
      "\nSettings (can be combined):\n"
      "  --resolution WxH  Virtual display pixels (480–7680 x 480–4320)\n"
      "  --size WxH        Preview content size in points (240–7680 x 135–4320)\n"
      "  --position XxY    Preview content top-left in global desktop coordinates\n"
      "  --origin XxY      Virtual display top-left in macOS Arrange coordinates\n"
      "  --borderless      Hide title bar (default)\n"
      "  --titled          Show title bar\n"
      "  --border-color COLOR  Preview edge: '#RRGGBB' or none (default: none)\n"
      "  --shadow / --no-shadow  Enable/disable the native window shadow (default: off)\n"
      "  --hi-perf / --no-hi-perf  Smoother AVFoundation preview; ~18% more WindowServer CPU each (default: off)\n"
      "  --hide / --show   Hide/show preview without disconnecting the display\n"
      "\nDefaults: 1920x1080 display at 60 Hz, 960x540 preview, maximum window priority.\n"
      "Coordinates: main display top-left is 0x0; X increases right, Y down; negatives allowed.\n"
      "Names: letters/underscore first, then letters, digits, underscore, dot, or hyphen (64 max).\n"
      "Move across a screen edge to enter or leave; previews do not capture input.\n"
      "Option-drag moves previews. Cmd-Option-T toggles bars; H hides/shows; Q quits.\n";
}

BOOL VSNumber(NSString *text, NSInteger low, NSInteger high, NSInteger *value) {
    const char *s = text.UTF8String;
    if (!s || !*s) return NO;
    const char *p = s;
    if (*p == '-') p++;
    if (!*p) return NO;
    for (; *p; p++) if (*p < '0' || *p > '9') return NO;
    errno = 0;
    char *end;
    long long n = strtoll(s, &end, 10);
    if (errno || *end || n < low || n > high) return NO;
    *value = (NSInteger)n;
    return YES;
}
static BOOL validName(NSString *name) {
    return [name rangeOfString:@"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$" options:NSRegularExpressionSearch].location != NSNotFound;
}
NSDictionary *VSParseCommand(NSArray<NSString *> *args, NSString **error) {
    NSString *problem = nil;
    for (id arg in args) if (![arg isKindOfClass:NSString.class]) {
        if (error) *error = @"Arguments must be strings.";
        return nil;
    }
    NSString *first = args.firstObject;
    if (args.count == 0 || ([first isEqual:@"--help"] && args.count == 1)) return @{@"action": @"help"};
    if ([first isEqual:@"screens"]) {
        if (args.count == 1) return @{@"action": @"screens"};
        NSString *option = args[1];
        if (args.count == 2 && ([@[@"--list", @"--main"] containsObject:option]))
            return @{@"action": @"screens", @"query": [option substringFromIndex:2]};
        if (args.count == 3 && [option isEqual:@"--find"] && [args[2] length])
            return @{@"action": @"screens", @"query": @"find", @"pattern": args[2]};
        NSInteger display;
        if (VSNumber(option, 1, UINT32_MAX, &display)) {
            if (args.count == 2) return @{@"action": @"screens", @"query": @"detail", @"id": @(display)};
            if (args.count == 3 && [@[@"--name", @"--origin", @"--size"] containsObject:args[2]])
                return @{@"action": @"screens", @"query": [args[2] substringFromIndex:2], @"id": @(display)};
        }
        if (error) *error = @"Invalid screens query. Run vscreen --help.";
        return nil;
    }
    if ([first isEqual:@"layout"] || [first isEqual:@"--layout"]) {
        if (args.count == 1 || (args.count == 2 && [args[1] isEqual:@"--list"]))
            return @{@"action": @"layout", @"query": @"list"};
        if (validName(args[1]))
            return @{@"action": @"layout", @"name": args[1],
                     @"arguments": [args subarrayWithRange:NSMakeRange(2, args.count - 2)]};
        if (error) *error = @"Invalid layout name. Run vscreen --help.";
        return nil;
    }
    if ([first isEqual:@"--list"] && (args.count == 1 || (args.count == 2 && [args[1] isEqual:@"--json"])))
        return @{@"action": @"list", @"json": @(args.count == 2)};
    NSDictionary *simple = @{@"--screens": @"screens", @"--check": @"check", @"quit": @"quit", @"--quit": @"quit", @"--request-permissions": @"permissions"};
    if (simple[first] && args.count == 1) return @{@"action": simple[first]};
    if ([first isEqual:@"close"] || [first isEqual:@"--close"]) {
        if (args.count == 1) return @{@"action": @"close", @"all": @YES};
        problem = @"close takes no arguments. To close one desktop, use: vscreen NAME|ID --close";
    } else {
        BOOL create = [first isEqual:@"--new"];
        NSUInteger index = create ? 2 : 1;
        NSString *name = create ? (args.count > 1 ? args[1] : nil) : first;
        NSInteger displayID;
        if (!name || (!validName(name) && (create || !VSNumber(name, 1, UINT32_MAX, &displayID))))
            problem = @"Expected a display name or owned display ID. Run vscreen --help.";
        else if ([@[@"screens", @"layout", @"close", @"quit"] containsObject:name])
            problem = @"The names 'screens', 'layout', 'close', and 'quit' are reserved for subcommands.";
        if (!problem && !create && args.count == 2 && [args[1] isEqual:@"--close"])
            return @{@"action": @"close", @"names": @[name]};
        NSMutableDictionary *changes = [NSMutableDictionary new];
        while (!problem && index < args.count) {
            NSString *flag = args[index++];
            NSString *key = nil;
            id value = nil;
            if ([flag isEqual:@"--borderless"] || [flag isEqual:@"--titled"]) {
                key = @"borderless"; value = @([flag isEqual:@"--borderless"]);
            } else if ([flag isEqual:@"--hide"] || [flag isEqual:@"--show"]) {
                key = @"visible"; value = @([flag isEqual:@"--show"]);
            } else if ([flag isEqual:@"--shadow"] || [flag isEqual:@"--no-shadow"]) {
                key = @"shadow"; value = @([flag isEqual:@"--shadow"]);
            } else if ([flag isEqual:@"--hi-perf"] || [flag isEqual:@"--no-hi-perf"]) {
                key = @"hiPerf"; value = @([flag isEqual:@"--hi-perf"]);
            } else if ([flag isEqual:@"--border-color"]) {
                if (index == args.count) { problem = @"Missing value for --border-color"; break; }
                NSString *color = [args[index++] lowercaseString];
                if (![color isEqual:@"none"] && [color rangeOfString:@"^#[0-9a-f]{6}$" options:NSRegularExpressionSearch].location == NSNotFound) {
                    problem = @"Border color must be '#RRGGBB' or none."; break;
                }
                key = @"borderColor"; value = color;
            } else if ([@[@"--resolution", @"--size", @"--position", @"--origin"] containsObject:flag]) {
                if (index == args.count) { problem = [@"Missing value for " stringByAppendingString:flag]; break; }
                key = [flag substringFromIndex:2];
                NSArray *parts = [args[index++] componentsSeparatedByString:@"x"];
                BOOL coordinates = [key isEqual:@"position"] || [key isEqual:@"origin"];
                NSInteger a, b;
                NSInteger minA = coordinates ? -100000 : ([key isEqual:@"resolution"] ? 480 : 240);
                NSInteger minB = coordinates ? -100000 : ([key isEqual:@"resolution"] ? 480 : 135);
                if (parts.count != 2 || !VSNumber(parts[0], minA, coordinates ? 100000 : 7680, &a)
                    || !VSNumber(parts[1], minB, coordinates ? 100000 : 4320, &b)) {
                    problem = [@"Invalid value for " stringByAppendingString:flag]; break;
                }
                value = @[@(a), @(b)];
            } else { problem = [@"Unknown option: " stringByAppendingString:flag]; break; }
            if (changes[key]) { problem = [@"Duplicate/conflicting setting: " stringByAppendingString:key]; break; }
            changes[key] = value;
        }
        if (!problem) return @{@"action": create ? @"new" : (changes.count ? @"update" : @"info"),
                               @"name": name, @"changes": changes};
    }
    if (error) *error = problem ?: @"Invalid command. Run vscreen --help.";
    return nil;
}
