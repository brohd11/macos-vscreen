#import "Hooks.h"
#import "Command.h"
#import "Layout.h"

NSString *VSConfigPath(void) {
    NSString *custom = NSProcessInfo.processInfo.environment[@"VSCREEN_CONFIG"];
    return custom.length ? custom : [NSHomeDirectory() stringByAppendingPathComponent:@".vscreen/config.json"];
}

NSArray<NSArray<NSString *> *> *VSLoadHooks(NSString **error) {
    NSString *path = VSConfigPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @[];
    NSError *parseError = nil;
    id config = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    NSString *problem = nil;
    NSMutableArray *hooks = [NSMutableArray new];
    id entries = [config isKindOfClass:NSDictionary.class] ? config[@"onDisplayChange"] : nil;
    if (!config) problem = parseError.localizedDescription;
    else if (![config isKindOfClass:NSDictionary.class]) problem = @"top level must be an object";
    else if (entries && ![entries isKindOfClass:NSArray.class]) problem = @"onDisplayChange must be an array";
    for (id entry in problem ? @[] : entries ?: @[]) {
        NSArray *hook = [entry isKindOfClass:NSString.class] ? @[entry] : entry;
        BOOL valid = [hook isKindOfClass:NSArray.class] && hook.count > 0;
        for (id part in valid ? hook : @[]) valid &= [part isKindOfClass:NSString.class];
        if (!valid || !VSValidName(hook[0])) {
            problem = [NSString stringWithFormat:@"invalid hook %@; use a layout name or [name, args...]",
                       [entry isKindOfClass:NSString.class] ? entry : @"entry"];
            break;
        }
        [hooks addObject:hook];
    }
    if (problem) {
        if (error) *error = [NSString stringWithFormat:@"Invalid %@: %@%@", path, problem, [problem hasSuffix:@"."] ? @"" : @"."];
        return nil;
    }
    return hooks;
}

static NSTask *hookTask(NSArray<NSString *> *hook, NSString *event, NSString **error) {
    NSString *path = VSLayoutPath(hook[0], error);
    if (!path) return nil;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    if (!environment[@"VSCREEN_BIN"]) environment[@"VSCREEN_BIN"] = NSBundle.mainBundle.executablePath;
    environment[@"VSCREEN_EVENT"] = event;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = [hook subarrayWithRange:NSMakeRange(1, hook.count - 1)];
    task.environment = environment;
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    return task;
}

int VSRunHooksCommand(NSDictionary *command) {
    NSString *error = nil;
    NSArray<NSArray<NSString *> *> *hooks = VSLoadHooks(&error);
    if (!hooks) { fprintf(stderr, "%s\n", error.UTF8String); return 1; }
    if (![command[@"run"] boolValue]) {
        for (NSArray *hook in hooks) puts([hook componentsJoinedByString:@" "].UTF8String);
        return 0;
    }
    int status = 0;
    for (NSArray<NSString *> *hook in hooks) {
        NSError *launchError = nil;
        NSTask *task = hookTask(hook, @"manual", &error);
        fflush(stdout);
        if (task && [task launchAndReturnError:&launchError]) {
            [task waitUntilExit];
            if (task.terminationStatus == 0 && task.terminationReason == NSTaskTerminationReasonExit) continue;
            error = [NSString stringWithFormat:@"Hook %@ exited with status %d.", hook[0], task.terminationStatus];
        } else if (task) error = [NSString stringWithFormat:@"Cannot run hook %@: %@", hook[0], launchError.localizedDescription];
        fprintf(stderr, "%s\n", error.UTF8String);
        status = 1;
    }
    return status;
}

static NSFileHandle *openLog(void) {
    NSString *path = [VSConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"hooks.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attributes || attributes.fileSize > 256 * 1024) [NSData.data writeToFile:path atomically:YES];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:path];
    [log seekToEndOfFile];
    return log;
}

static void logLine(NSFileHandle *log, NSString *line) {
    NSString *stamp = [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone
        formatOptions:NSISO8601DateFormatWithInternetDateTime];
    [log writeData:[[NSString stringWithFormat:@"[%@] %@\n", stamp, line] dataUsingEncoding:NSUTF8StringEncoding]];
}

static void runNext(NSArray<NSArray<NSString *> *> *hooks, NSUInteger index, NSString *event, NSFileHandle *log,
                    void (^done)(void)) {
    if (index == hooks.count) { [log closeFile]; done(); return; }
    NSArray<NSString *> *hook = hooks[index];
    void (^next)(void) = ^{ runNext(hooks, index + 1, event, log, done); };
    NSString *error = nil;
    NSError *launchError = nil;
    NSTask *task = hookTask(hook, event, &error);
    logLine(log, [NSString stringWithFormat:@"%@: %@", event, [hook componentsJoinedByString:@" "]]);
    if (task) {
        task.standardInput = NSFileHandle.fileHandleWithNullDevice;
        task.standardOutput = log;
        task.standardError = log;
        task.terminationHandler = ^(NSTask *finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                logLine(log, [NSString stringWithFormat:@"%@ exited with status %d", hook[0], finished.terminationStatus]);
                next();
            });
        };
        if ([task launchAndReturnError:&launchError]) return;
        error = [NSString stringWithFormat:@"Cannot run hook %@: %@", hook[0], launchError.localizedDescription];
    }
    logLine(log, error);
    next();
}

void VSRunHooksAsync(NSString *event, void (^done)(void)) {
    NSString *error = nil;
    NSArray<NSArray<NSString *> *> *hooks = VSLoadHooks(&error);
    if (hooks.count == 0 && !error) { done(); return; }
    NSFileHandle *log = openLog();
    if (!hooks) { logLine(log, error); hooks = @[]; }
    runNext(hooks, 0, event, log, done);
}
