#import <Cocoa/Cocoa.h>
#import "Command.h"
#import "Controller.h"
#import "Layout.h"
#import "VirtualDisplay.h"
#import "ScreenQuery.h"
#import "Hooks.h"
#include <signal.h>

static int client(NSArray<NSString *> *arguments) {
    NSString *error = nil;
    NSDictionary *command = VSParseCommand(arguments, &error);
    if (!command) { fprintf(stderr, "%s\n", error.UTF8String); return 2; }
    NSString *action = command[@"action"];
    if ([action isEqual:@"help"]) { fputs(VSUsage().UTF8String, stdout); return 0; }
    if ([action isEqual:@"layout"]) return VSRunLayout(command);
    if ([action isEqual:@"generate"]) return VSGenerate(command);
    // Hooks call vscreen, so they must not run inside a request the app is still serving.
    if ([action isEqual:@"hooks"]) return VSRunHooksCommand(command);
    if ([action isEqual:@"screens"]) {
        NSDictionary *reply = VSScreenQuery(command, VSSystemDisplays());
        if (![reply[@"ok"] boolValue]) { fprintf(stderr, "%s\n", [reply[@"error"] UTF8String]); return 1; }
        NSString *output = reply[@"output"];
        if (output.length) puts(output.UTF8String);
        return 0;
    }
    // The config is the saved setting; a running app is then told to reread it.
    if ([action isEqual:@"drawMouse"] && VSSetDrawMouse([command[@"enable"] boolValue])) return 1;
    NSString *directory = VSRuntimeDirectory();
    int fd = VSConnect(directory);
    if (fd < 0) {
        if (errno != ENOENT && errno != ECONNREFUSED) {
            fprintf(stderr, "Cannot connect to VScreen: %s\n", strerror(errno)); return 1;
        }
        if ([action isEqual:@"list"] || [action isEqual:@"close"] || [action isEqual:@"quit"] || [action isEqual:@"drawMouse"]) {
            if ([command[@"json"] boolValue]) puts("[]");
            return 0;
        }
        if (![@[@"new", @"check", @"permissions", @"login"] containsObject:action]) {
            fprintf(stderr, "VScreen is not running. Create a display with --new NAME first.\n"); return 1;
        }
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.arguments = @[@"--serve", directory];
        configuration.activates = NO;
        configuration.createsNewApplicationInstance = YES;
        dispatch_semaphore_t launched = dispatch_semaphore_create(0);
        __block NSError *launchError = nil;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
            completionHandler:^(NSRunningApplication *application, NSError *failure) {
                (void)application; launchError = failure; dispatch_semaphore_signal(launched);
            }];
        if (dispatch_semaphore_wait(launched, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "Timed out launching VScreen.\n"); return 1;
        }
        if (launchError) { fprintf(stderr, "%s\n", launchError.localizedDescription.UTF8String); return 1; }
        for (int attempt = 0; attempt < 100 && fd < 0; attempt++) {
            usleep(100000); fd = VSConnect(directory);
        }
        if (fd < 0) { fprintf(stderr, "VScreen did not start its control socket. Quit an older build, then retry.\n"); return 1; }
    }
    NSDictionary *reply = nil;
    if (VSWriteMessage(fd, @{@"arguments": arguments})) reply = VSReadMessage(fd);
    close(fd);
    if (!reply) { fprintf(stderr, "No reply from VScreen; the outcome is unknown. Inspect --list before retrying.\n"); return 1; }
    if (![reply[@"ok"] boolValue]) { fprintf(stderr, "%s\n", [reply[@"error"] UTF8String]); return 1; }
    if ([action isEqual:@"quit"]) {
        BOOL stopped = NO;
        for (int attempt = 0; attempt < 100; attempt++) {
            int probe = VSConnect(directory);
            if (probe < 0) { stopped = YES; break; }
            close(probe); usleep(50000);
        }
        if (!stopped) { fprintf(stderr, "VScreen acknowledged quit but has not finished stopping.\n"); return 1; }
    }
    NSString *output = reply[@"output"];
    if (output.length) { fputs(output.UTF8String, stdout); if (![output hasSuffix:@"\n"]) fputc('\n', stdout); }
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (argc > 1 && strcmp(argv[1], "--display-host") == 0) {
            NSInteger width, height, fps;
            if (argc != 6 || !VSNumber(@(argv[2]), 480, 7680, &width) || !VSNumber(@(argv[3]), 480, 4320, &height)
                || !VSNumber(@(argv[4]), 1, 120, &fps)) return 2;
            return VSRunDisplayHost(@(argv[5]), (NSUInteger)width, (NSUInteger)height, (NSUInteger)fps);
        }
        // LaunchServices starts login items (and Finder opens) with no arguments and launchd as parent;
        // a terminal `vscreen` has a shell parent and still prints help.
        BOOL loginLaunch = argc == 1 && getppid() == 1;
        if (loginLaunch || (argc == 3 && (!strcmp(argv[1], "--serve") || !strcmp(argv[1], "--serve-test")))) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            VSController *controller = [VSController new];
            controller.runtimeDirectory = loginLaunch ? VSRuntimeDirectory() : @(argv[2]);
            controller.testMode = !loginLaunch && !strcmp(argv[1], "--serve-test");
            controller.launchHooks = loginLaunch;
            NSApp.delegate = controller;
            [NSApp run];
            return controller.exitCode;
        }
        NSMutableArray *arguments = [NSMutableArray new];
        for (int i = 1; i < argc; i++) [arguments addObject:@(argv[i])];
        return client(arguments);
    }
}
