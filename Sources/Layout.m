#import "Layout.h"
#include <sys/stat.h>
#include <unistd.h>

static NSString *layoutDirectory(void) {
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

int VSRunLayout(NSDictionary *command) {
    NSString *directory = layoutDirectory();
    if ([command[@"query"] isEqual:@"list"]) {
        NSMutableOrderedSet *names = [NSMutableOrderedSet new];
        NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]
                          sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *file in files) {
            if ([file hasPrefix:@"."] || !isExecutable([directory stringByAppendingPathComponent:file])) continue;
            [names addObject:[file.pathExtension isEqual:@"sh"] ? file.stringByDeletingPathExtension : file];
        }
        for (NSString *name in names) puts(name.UTF8String);
        return 0;
    }

    NSString *name = command[@"name"];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (!isRegularFile(path)) path = [path stringByAppendingPathExtension:@"sh"];
    if (!isRegularFile(path)) {
        fprintf(stderr, "No layout %s in %s.\n", name.UTF8String, directory.UTF8String); return 1;
    }
    if (!isExecutable(path)) {
        fprintf(stderr, "Layout %s is not executable; run: chmod +x '%s'\n", name.UTF8String, path.UTF8String); return 1;
    }

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
