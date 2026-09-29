#import "Layout.h"
#include <sys/stat.h>
#include <unistd.h>

static NSString *layoutDirectory(void) {
    NSString *custom = NSProcessInfo.processInfo.environment[@"VSCREEN_LAYOUT_DIR"];
    return custom.length ? custom : [NSHomeDirectory() stringByAppendingPathComponent:@".vscreen/layout"];
}

// Verbatim copy of examples/xreal-uw-dual.sh; Tests/examples.py checks they match.
static NSString *const exampleLayout = @
    "#!/bin/sh\n"
    "# Split XREAL into two virtual displays with matching resolutions and previews.\n"
    "# Uses only shell built-ins and vscreen. Override its path with VSCREEN_BIN.\n"
    "set -eu\n"
    "vscreen_bin=${VSCREEN_BIN:-vscreen}\n"
    "vsrun() { \"$vscreen_bin\" \"$@\"; }\n"
    "fail() { printf 'xreal-uw-dual: %s\\n' \"$*\" >&2; exit 1; }\n"
    "[ \"$#\" -eq 0 ] || fail 'usage: xreal-uw-dual.sh (no arguments)'\n"
    "command -v \"$vscreen_bin\" >/dev/null 2>&1 || fail \"cannot find $vscreen_bin; install VScreen or set VSCREEN_BIN.\"\n"
    "\n"
    "# Validate the complete layout before creating or changing any displays.\n"
    "if ! xr=$(vsrun screens --find 'XREAL*'); then\n"
    "    fail 'no XREAL display found; nothing changed.'\n"
    "fi\n"
    "dimensions=$(vsrun screens \"$xr\" --size)\n"
    "width=${dimensions%x*}\n"
    "height=${dimensions#*x}\n"
    "left_width=$((width / 2))\n"
    "right_width=$((width - left_width))\n"
    "validate_width() {\n"
    "    [ \"$1\" -ge 480 ] && [ \"$1\" -le 7680 ] ||\n"
    "        fail \"each virtual must be 480–7680 pixels wide; this layout needs $1. Nothing changed.\"\n"
    "}\n"
    "validate_width \"$left_width\"\n"
    "validate_width \"$right_width\"\n"
    "[ \"$height\" -ge 480 ] && [ \"$height\" -le 4320 ] ||\n"
    "    fail \"virtual height must be 480–4320 pixels; XREAL reports $height. Nothing changed.\"\n"
    "main=$(vsrun screens --main)\n"
    "main_origin=$(vsrun screens \"$main\" --origin)\n"
    "main_size=$(vsrun screens \"$main\" --size)\n"
    "\n"
    "# Center the entire contiguous row directly above the main display.\n"
    "origin_x=$((${main_origin%x*} + (${main_size%x*} - width) / 2))\n"
    "origin_y=$((${main_origin#*x} - height))\n"
    "vsrun --new UWLeft --resolution \"${left_width}x${height}\" --size \"${left_width}x${height}\" --origin \"${origin_x}x${origin_y}\" --borderless --hide\n"
    "vsrun --new UWRight --resolution \"${right_width}x${height}\" --size \"${right_width}x${height}\" --origin \"$((origin_x + left_width))x${origin_y}\" --borderless --hide\n"
    "\n"
    "# Connecting displays can move XREAL. Position previews using its new origin,\n"
    "# but never stretch the captured image if its logical size changed mid-setup.\n"
    "if ! current_size=$(vsrun screens \"$xr\" --size) || ! origin=$(vsrun screens \"$xr\" --origin); then\n"
    "    fail 'XREAL disconnected during setup; previews remain hidden. Reconnect and rerun.'\n"
    "fi\n"
    "[ \"$current_size\" = \"$dimensions\" ] ||\n"
    "    fail 'XREAL changed size during setup; previews remain hidden. Rerun to use its new size.'\n"
    "x=${origin%x*}\n"
    "y=${origin#*x}\n"
    "vsrun UWLeft --size \"${left_width}x${height}\" --position \"${x}x${y}\" --show\n"
    "vsrun UWRight --size \"${right_width}x${height}\" --position \"$((x + left_width))x${y}\" --show\n"
    "printf 'Two virtual displays now fill XREAL (display %s, %s).\\n' \"$xr\" \"$dimensions\"\n";

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

int VSGenerateExample(void) {
    NSString *directory = layoutDirectory();
    NSString *path = [directory stringByAppendingPathComponent:@"xreal-uw-dual.sh"];
    NSData *contents = [exampleLayout dataUsingEncoding:NSUTF8StringEncoding];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    if (existing && ![existing isEqual:contents]) {
        fprintf(stderr, "%s already exists and differs; remove it to regenerate.\n", path.UTF8String); return 1;
    }
    NSError *error = nil;
    if (!existing && (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                               attributes:nil error:&error]
                      || ![contents writeToFile:path options:NSDataWritingAtomic error:&error])) {
        fprintf(stderr, "Cannot write %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String); return 1;
    }
    if (chmod(path.fileSystemRepresentation, 0755) != 0) {
        fprintf(stderr, "Cannot make %s executable: %s\n", path.UTF8String, strerror(errno)); return 1;
    }
    printf("Wrote %s. Run: vscreen layout xreal-uw-dual\n", path.UTF8String);
    return 0;
}
