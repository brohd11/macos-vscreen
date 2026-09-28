#import "Control.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <poll.h>

NSString *VSRuntimeDirectory(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"VSCREEN_RUNTIME_DIR"];
    if (override.length) return override.stringByStandardizingPath;
    char path[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, path, sizeof(path)) == 0) return nil;
    return [@(path) stringByAppendingPathComponent:@"local.vscreen"];
}
NSString *VSJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}
NSDictionary *VSReply(NSString *output) { return @{@"ok": @YES, @"output": output ?: @""}; }
NSDictionary *VSFailure(NSString *message) { return @{@"ok": @NO, @"error": message}; }
NSDictionary *VSReadMessage(int fd) {
    NSMutableData *data = [NSMutableData new];
    NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + 30;
    while (data.length < 65536) {
        int timeout = (int)MAX(0, (deadline - NSDate.timeIntervalSinceReferenceDate) * 1000);
        struct pollfd item = { .fd = fd, .events = POLLIN };
        int ready = poll(&item, 1, timeout);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return nil;
        char byte;
        ssize_t n = read(fd, &byte, 1);
        if (n < 0 && errno == EINTR) continue;
        if (n != 1) return nil;
        if (byte == '\n') {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            return [object isKindOfClass:NSDictionary.class] ? object : nil;
        }
        [data appendBytes:&byte length:1];
    }
    return nil;
}
BOOL VSWriteMessage(int fd, NSDictionary *message) {
    NSData *data = [[VSJSON(message) stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *bytes = data.bytes;
    NSUInteger written = 0;
    while (written < data.length) {
        ssize_t n = write(fd, bytes + written, data.length - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        written += (NSUInteger)n;
    }
    return YES;
}
static BOOL addressForDirectory(NSString *directory, struct sockaddr_un *address) {
    if (!directory.length) return NO;
    NSString *path = [directory stringByAppendingPathComponent:@"control.sock"];
    const char *bytes = path.fileSystemRepresentation;
    if (strlen(bytes) >= sizeof(address->sun_path)) return NO;
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    strlcpy(address->sun_path, bytes, sizeof(address->sun_path));
    return YES;
}
int VSConnect(NSString *directory) {
    struct sockaddr_un address;
    if (!addressForDirectory(directory, &address)) { errno = ENAMETOOLONG; return -1; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

@implementation VSControl {
    int _socket, _lock;
    NSString *_path;
    dispatch_source_t _listener;
}
- (instancetype)init { if ((self = [super init])) { _socket = -1; _lock = -1; } return self; }
- (BOOL)startAtDirectory:(NSString *)directory handler:(VSRequestHandler)handler error:(NSString **)error {
    struct sockaddr_un address;
    struct stat info;
    if (!addressForDirectory(directory, &address)) {
        if (error) *error = @"Control socket path is too long.";
        return NO;
    }
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) goto failed;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)
        || info.st_uid != getuid() || (info.st_mode & 0077)) {
        if (error) *error = @"Runtime directory must be a private directory owned by this user.";
        return NO;
    }
    _lock = open([directory stringByAppendingPathComponent:@"host.lock"].fileSystemRepresentation,
                 O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (_lock < 0 || flock(_lock, LOCK_EX | LOCK_NB) != 0) goto failed;
    _socket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_socket < 0) goto failed;
    fcntl(_socket, F_SETFD, FD_CLOEXEC);
    unlink(address.sun_path); // Exclusive lock permits reclaiming a crashed host's socket.
    if (bind(_socket, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(_socket, 16) != 0) goto failed;
    chmod(address.sun_path, 0600);
    _path = @(address.sun_path);
    fcntl(_socket, F_SETFL, O_NONBLOCK);
    {
    dispatch_queue_t queue = dispatch_queue_create("local.vscreen.commands", DISPATCH_QUEUE_SERIAL);
    _listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _socket, 0, queue);
    int server = _socket;
    dispatch_source_set_event_handler(_listener, ^{
        int client = accept(server, NULL, NULL);
        if (client < 0) return;
        fcntl(client, F_SETFD, FD_CLOEXEC);
        uid_t uid; gid_t gid;
        if (getpeereid(client, &uid, &gid) != 0 || uid != getuid()) { close(client); return; }
        NSDictionary *request = VSReadMessage(client);
        NSArray *arguments = request[@"arguments"];
        if (![arguments isKindOfClass:NSArray.class]) {
            VSWriteMessage(client, VSFailure(@"Invalid control request.")); close(client); return;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSDictionary *response = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(arguments, ^(NSDictionary *reply) { response = reply; dispatch_semaphore_signal(done); });
        });
        // Serialize requests through completion, including asynchronous capture startup.
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        VSWriteMessage(client, response ?: VSFailure(@"No response from the app."));
        close(client);
    });
    dispatch_source_set_cancel_handler(_listener, ^{ close(server); });
    dispatch_resume(_listener);
    return YES;
    }
failed:
    if (error) *error = [NSString stringWithFormat:@"Cannot start VScreen control socket: %s", strerror(errno)];
    [self stop];
    return NO;
}
- (void)stop {
    if (_listener) { dispatch_source_cancel(_listener); _listener = nil; _socket = -1; }
    else if (_socket >= 0) { close(_socket); _socket = -1; }
    if (_path) { unlink(_path.fileSystemRepresentation); _path = nil; }
    if (_lock >= 0) { close(_lock); _lock = -1; }
}
- (void)dealloc { [self stop]; }
@end
