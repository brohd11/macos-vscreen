#import "Hooks.h"
#import "Command.h"
#import "Layout.h"
#include <fcntl.h>
#include <unistd.h>
#include <yaml.h>

NSString *VSConfigPath(void) {
    NSString *custom = NSProcessInfo.processInfo.environment[@"VSCREEN_CONFIG"];
    return custom.length ? custom : [NSHomeDirectory() stringByAppendingPathComponent:@".vscreen/config.yaml"];
}

NSString *VSHookDirectory(void) {
    return [VSConfigPath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"hooks"];
}

static NSString *const defaultConfig = @
    "# VScreen config. Hooks are scripts in ~/.vscreen/hooks; only the ones listed here run.\n"
    "# Toggle one with: vscreen hooks --enable NAME / --disable NAME\n"
    "onDisplayChange:\n";

BOOL VSEnsureConfig(NSString **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *path = VSConfigPath();
    NSError *failure = nil;
    for (NSString *directory in @[path.stringByDeletingLastPathComponent, VSHookDirectory(), VSLayoutDirectory()]) {
        if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&failure]) {
            if (error) *error = [NSString stringWithFormat:@"Cannot create %@: %@", directory, failure.localizedDescription];
            return NO;
        }
    }
    if ([manager fileExistsAtPath:path]) return YES;
    // Exclusive create, so a config written concurrently is never replaced.
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0 && errno == EEXIST) return YES;
    const char *text = defaultConfig.UTF8String;
    BOOL written = fd >= 0 && write(fd, text, strlen(text)) == (ssize_t)strlen(text);
    if (fd >= 0) close(fd);
    if (!written && error) *error = [NSString stringWithFormat:@"Cannot write %@: %s", path, strerror(errno)];
    return written;
}

// Scalars stay strings: hook entries are layout names and arguments. A bare empty value is NSNull.
static id yamlObject(yaml_document_t *document, yaml_node_t *node, int depth) {
    if (!node || depth > 32) return nil;
    if (node->type == YAML_SCALAR_NODE && node->data.scalar.style == YAML_PLAIN_SCALAR_STYLE && !node->data.scalar.length)
        return NSNull.null;
    if (node->type == YAML_SCALAR_NODE)
        return [[NSString alloc] initWithBytes:node->data.scalar.value length:node->data.scalar.length
                                      encoding:NSUTF8StringEncoding];
    if (node->type == YAML_SEQUENCE_NODE) {
        NSMutableArray *array = [NSMutableArray new];
        for (yaml_node_item_t *item = node->data.sequence.items.start; item < node->data.sequence.items.top; item++) {
            id value = yamlObject(document, yaml_document_get_node(document, *item), depth + 1);
            if (!value) return nil;
            [array addObject:value];
        }
        return array;
    }
    if (node->type != YAML_MAPPING_NODE) return nil;
    NSMutableDictionary *dictionary = [NSMutableDictionary new];
    for (yaml_node_pair_t *pair = node->data.mapping.pairs.start; pair < node->data.mapping.pairs.top; pair++) {
        id key = yamlObject(document, yaml_document_get_node(document, pair->key), depth + 1);
        id value = yamlObject(document, yaml_document_get_node(document, pair->value), depth + 1);
        if (![key isKindOfClass:NSString.class] || !value) return nil;
        dictionary[key] = value;
    }
    return dictionary;
}

// An empty file is an empty mapping; nil sets *problem.
static id loadYAML(NSData *data, NSString **problem) {
    yaml_parser_t parser;
    yaml_document_t document;
    if (!yaml_parser_initialize(&parser)) { *problem = @"out of memory"; return nil; }
    yaml_parser_set_input_string(&parser, data.length ? data.bytes : (const unsigned char *)"", data.length);
    id result = nil;
    if (!yaml_parser_load(&parser, &document)) {
        *problem = [NSString stringWithFormat:@"%s at line %zu, column %zu", parser.problem ?: "parse error",
                    parser.problem_mark.line + 1, parser.problem_mark.column + 1];
    } else {
        yaml_node_t *root = yaml_document_get_root_node(&document);
        result = root ? yamlObject(&document, root, 0) : @{};
        if (!result) *problem = @"keys and values must be strings, lists, or mappings";
        yaml_document_delete(&document);
    }
    yaml_parser_delete(&parser);
    return result;
}

static NSArray<NSArray<NSString *> *> *hooksFromData(NSData *data, NSString *path, NSString **error) {
    NSString *problem = nil;
    id config = loadYAML(data, &problem);
    NSMutableArray *hooks = [NSMutableArray new];
    id entries = [config isKindOfClass:NSDictionary.class] ? config[@"onDisplayChange"] : nil;
    if ([entries isKindOfClass:NSNull.class]) entries = nil;
    if (config && ![config isKindOfClass:NSDictionary.class]) problem = @"top level must be a mapping";
    else if (entries && ![entries isKindOfClass:NSArray.class]) problem = @"onDisplayChange must be a list";
    for (id entry in problem ? @[] : entries ?: @[]) {
        NSArray *hook = [entry isKindOfClass:NSString.class] ? @[entry] : entry;
        BOOL valid = [hook isKindOfClass:NSArray.class] && hook.count > 0;
        for (id part in valid ? hook : @[]) valid &= [part isKindOfClass:NSString.class];
        if (!valid || !VSValidName(hook[0])) {
            problem = [NSString stringWithFormat:@"invalid hook %@; use a hook name or [name, args...]",
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

NSArray<NSArray<NSString *> *> *VSLoadHooks(NSString **error) {
    NSString *path = VSConfigPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? hooksFromData(data, path, error) : @[];
}

static NSArray<NSString *> *hookNames(NSArray<NSArray<NSString *> *> *hooks) {
    NSMutableArray *names = [NSMutableArray new];
    for (NSArray *hook in hooks) [names addObject:hook[0]];
    return names;
}

static BOOL matches(NSString *line, NSString *pattern) {
    return [line rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

// Adds or removes NAME in onDisplayChange by editing lines, so comments and layout survive.
// Returns nil when the config isn't in a shape this can edit (e.g. a non-empty flow list).
static NSString *editConfig(NSString *text, NSString *name, BOOL enable) {
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count > 1 && [lines.lastObject isEqual:@""]) [lines removeLastObject];
    NSUInteger key = NSNotFound;
    for (NSUInteger i = 0; i < lines.count && key == NSNotFound; i++)
        if (matches(lines[i], @"^onDisplayChange\\s*:")) key = i;
    if (key == NSNotFound) {
        if (!enable) return nil;
        [lines addObjectsFromArray:@[@"onDisplayChange:", [@"  - " stringByAppendingString:name]]];
        return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    }
    NSString *value = [lines[key] substringFromIndex:[lines[key] rangeOfString:@":"].location + 1];
    value = [value stringByReplacingOccurrencesOfString:@"(^|\\s)#.*$" withString:@"" options:NSRegularExpressionSearch
                                                  range:NSMakeRange(0, value.length)];
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([value isEqual:@"[]"] && enable) lines[key] = @"onDisplayChange:";
    else if (value.length) return nil;
    // The block runs while lines are blank, comments, indented, or zero-indent "- " items.
    NSUInteger end = key + 1, last = key;
    NSString *indent = nil;
    for (; end < lines.count; end++) {
        NSString *line = lines[end];
        if (!matches(line, @"^(\\s|#|-(\\s|$)|$)")) break;
        if (matches(line, @"^\\s*(#|$)")) continue;
        last = end;
        if (!indent && matches(line, @"^\\s*-"))
            indent = [line substringToIndex:[line rangeOfString:@"-"].location];
    }
    if (enable) {
        [lines insertObject:[NSString stringWithFormat:@"%@- %@", indent ?: @"  ", name] atIndex:last + 1];
    } else {
        NSString *quoted = [NSRegularExpression escapedPatternForString:name];
        NSString *item = [NSString stringWithFormat:@"^\\s*-\\s+(%1$@|\"%1$@\"|'%1$@'|\\[\\s*%1$@\\s*(,[^\\]]*)?\\])\\s*(#.*)?$", quoted];
        for (NSUInteger i = end; i > key + 1; i--)
            if (matches(lines[i - 1], item)) [lines removeObjectAtIndex:i - 1];
    }
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

static int toggleHook(NSString *name, BOOL enable) {
    NSString *error = nil, *path = VSConfigPath();
    if (enable && (!VSScriptPath(VSHookDirectory(), @"hook", name, &error) || !VSEnsureConfig(&error))) {
        fprintf(stderr, "%s\n", error.UTF8String); return 1;
    }
    NSData *data = [NSData dataWithContentsOfFile:path] ?: NSData.data;
    NSArray *hooks = hooksFromData(data, path, &error);
    if (!hooks) { fprintf(stderr, "%s\n", error.UTF8String); return 1; }
    NSMutableArray *expected = [hookNames(hooks) mutableCopy];
    if ([expected containsObject:name] == enable) return 0;
    if (enable) [expected addObject:name];
    else [expected removeObject:name];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *edited = text ? editConfig(text, name, enable) : nil;
    NSData *output = [edited dataUsingEncoding:NSUTF8StringEncoding];
    // Only write when the edited file parses to exactly the intended hook list.
    NSArray *result = output ? hooksFromData(output, path, NULL) : nil;
    if (!result || ![hookNames(result) isEqual:expected]) {
        fprintf(stderr, "Cannot %s %s automatically; edit onDisplayChange in %s by hand.\n",
                enable ? "enable" : "disable", name.UTF8String, path.UTF8String);
        return 1;
    }
    NSError *failure = nil;
    if (![output writeToFile:path options:NSDataWritingAtomic error:&failure]) {
        fprintf(stderr, "Cannot write %s: %s\n", path.UTF8String, failure.localizedDescription.UTF8String); return 1;
    }
    return 0;
}

static NSTask *hookTask(NSArray<NSString *> *hook, NSString *event, NSString **error) {
    NSString *path = VSScriptPath(VSHookDirectory(), @"hook", hook[0], error);
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
    NSString *query = command[@"query"];
    if ([query isEqual:@"enable"] || [query isEqual:@"disable"])
        return toggleHook(command[@"name"], [query isEqual:@"enable"]);
    NSString *error = nil;
    NSArray<NSArray<NSString *> *> *hooks = VSLoadHooks(&error);
    if (!hooks) { fprintf(stderr, "%s\n", error.UTF8String); return 1; }
    if ([query isEqual:@"list"]) {
        NSArray *enabled = hookNames(hooks), *scripts = VSScriptNames(VSHookDirectory());
        for (NSString *name in scripts)
            printf("%s\t%s\n", name.UTF8String, [enabled containsObject:name] ? "enabled" : "disabled");
        for (NSString *name in [NSOrderedSet orderedSetWithArray:enabled])
            if (![scripts containsObject:name]) printf("%s\tmissing\n", name.UTF8String);
        return 0;
    }
    if (![query isEqual:@"run"]) {
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
