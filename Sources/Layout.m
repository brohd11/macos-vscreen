#import "Layout.h"
#import "Hooks.h"
#include <sys/stat.h>
#include <unistd.h>

NSString *VSLayoutDirectory(void) {
    NSString *custom = NSProcessInfo.processInfo.environment[@"VSCREEN_LAYOUT_DIR"];
    return custom.length ? custom : [NSHomeDirectory() stringByAppendingPathComponent:@".vscreen/layout"];
}

static BOOL isRegularFile(NSString *path) {
    struct stat info;
    return stat(path.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode);
}

static BOOL isExecutable(NSString *path) {
    return isRegularFile(path) && access(path.fileSystemRepresentation, X_OK) == 0;
}

NSString *VSScriptPath(NSString *directory, NSString *kind, NSString *name, NSString **error) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (!isRegularFile(path)) path = [path stringByAppendingPathExtension:@"sh"];
    if (!isRegularFile(path)) {
        if (error) *error = [NSString stringWithFormat:@"No %@ %@ in %@.", kind, name, directory];
        return nil;
    }
    if (!isExecutable(path)) {
        if (error) *error = [NSString stringWithFormat:@"%@ %@ is not executable; run: chmod +x '%@'",
                             kind.capitalizedString, name, path];
        return nil;
    }
    return path;
}

NSString *VSLayoutPath(NSString *name, NSString **error) {
    return VSScriptPath(VSLayoutDirectory(), @"layout", name, error);
}

NSArray<NSString *> *VSScriptNames(NSString *directory) {
    NSMutableOrderedSet *names = [NSMutableOrderedSet new];
    NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]
                      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *file in files) {
        if ([file hasPrefix:@"."] || !isExecutable([directory stringByAppendingPathComponent:file])) continue;
        [names addObject:[file.pathExtension isEqual:@"sh"] ? file.stringByDeletingPathExtension : file];
    }
    return names.array;
}

int VSRunLayout(NSDictionary *command) {
    if ([command[@"query"] isEqual:@"list"]) {
        for (NSString *name in VSScriptNames(VSLayoutDirectory())) puts(name.UTF8String);
        return 0;
    }

    NSString *error = nil;
    NSString *path = VSLayoutPath(command[@"name"], &error);
    if (!path) { fprintf(stderr, "%s\n", error.UTF8String); return 1; }

    // Layout scripts call vscreen; point them at this binary when PATH lacks the launcher.
    setenv("VSCREEN_BIN", NSBundle.mainBundle.executablePath.fileSystemRepresentation, 0);
    NSArray<NSString *> *arguments = command[@"arguments"];
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    argv[0] = strdup(path.fileSystemRepresentation);
    for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = strdup(arguments[i].UTF8String);
    fflush(stdout);
    execv(argv[0], argv);
    fprintf(stderr, "Cannot run layout %s: %s\n", path.UTF8String, strerror(errno));
    return 1;
}

int VSGenerate(NSDictionary *command) {
    NSFileManager *manager = NSFileManager.defaultManager;
    // Resolve the executable, since the build/vscreen symlink hides the bundle from NSBundle.mainBundle.
    NSString *contents = NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath
                             .stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *root = [contents stringByAppendingPathComponent:@"Resources/presets"];
    NSMutableArray<NSString *> *presets = [NSMutableArray new];
    for (NSString *name in [[manager contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL directory = NO;
        if (![name hasPrefix:@"."] && [manager fileExistsAtPath:[root stringByAppendingPathComponent:name] isDirectory:&directory]
            && directory) [presets addObject:name];
    }
    NSString *preset = command[@"name"];
    if (!preset) {
        for (NSString *name in presets) puts(name.UTF8String);
        return 0;
    }
    if (![presets containsObject:preset]) {
        fprintf(stderr, "No preset %s. Available: %s\n", preset.UTF8String,
                [presets componentsJoinedByString:@", "].UTF8String);
        return 1;
    }

    // Check every file before writing any, so a conflict leaves nothing half-installed.
    NSDictionary<NSString *, NSString *> *targets = @{@"hooks": VSHookDirectory(), @"layout": VSLayoutDirectory()};
    NSMutableArray<NSArray *> *writes = [NSMutableArray new];
    NSMutableArray<NSString *> *conflicts = [NSMutableArray new], *hooks = [NSMutableArray new];
    for (NSString *kind in @[@"hooks", @"layout"]) {
        NSString *source = [[root stringByAppendingPathComponent:preset] stringByAppendingPathComponent:kind];
        for (NSString *file in [[manager contentsOfDirectoryAtPath:source error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            NSData *contents = [file hasPrefix:@"."] ? nil : [NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:file]];
            if (!contents) continue;
            NSString *destination = [targets[kind] stringByAppendingPathComponent:file];
            NSData *existing = [NSData dataWithContentsOfFile:destination];
            if (existing && ![existing isEqual:contents]) [conflicts addObject:destination];
            else [writes addObject:@[destination, existing ? NSNull.null : contents]];
            if ([kind isEqual:@"hooks"])
                [hooks addObject:[file.pathExtension isEqual:@"sh"] ? file.stringByDeletingPathExtension : file];
        }
    }
    if (conflicts.count) {
        fprintf(stderr, "Nothing generated; these files exist and differ (remove them to regenerate):\n");
        for (NSString *path in conflicts) fprintf(stderr, "  %s\n", path.UTF8String);
        return 1;
    }
    NSString *problem = nil;
    if (!VSEnsureConfig(&problem)) { fprintf(stderr, "%s\n", problem.UTF8String); return 1; }
    for (NSArray *write in writes) {
        NSString *path = write[0];
        NSError *error = nil;
        if (write[1] != NSNull.null) {
            if (![write[1] writeToFile:path options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "Cannot write %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String); return 1;
            }
            printf("Wrote %s\n", path.UTF8String);
        }
        if (chmod(path.fileSystemRepresentation, 0755) != 0) {
            fprintf(stderr, "Cannot make %s executable: %s\n", path.UTF8String, strerror(errno)); return 1;
        }
    }
    NSMutableSet *enabled = [NSMutableSet new];
    for (NSArray *hook in VSLoadHooks(NULL) ?: @[]) [enabled addObject:hook[0]];
    for (NSString *hook in hooks)
        if (![enabled containsObject:hook]) printf("Enable the hook: vscreen hooks --enable %s\n", hook.UTF8String);
    return 0;
}
