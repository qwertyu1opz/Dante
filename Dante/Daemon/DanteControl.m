

#import "DanteControl.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

const uint16_t kDanteControlPort = 9095;
const uint16_t kDanteSOCKSPort = 10808;

NSString *DanteLocalRequest(uint16_t port, NSString *line, BOOL readToEOF,
                            NSTimeInterval timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (NSTimeInterval)tv.tv_sec) * 1e6);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return nil;
    }

    NSData *out = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (send(fd, out.bytes, out.length, 0) != (ssize_t)out.length) {
        close(fd);
        return nil;
    }

    NSMutableData *in = [NSMutableData data];
    uint8_t buf[4096];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        [in appendBytes:buf length:(NSUInteger)n];
        if (!readToEOF && memchr(buf, '\n', (size_t)n)) break;
    }
    close(fd);
    if (in.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:in encoding:NSUTF8StringEncoding];
    if (!readToEOF) {
        s = [[s componentsSeparatedByString:@"\n"] objectAtIndex:0];
    }
    return s;
}

NSString *DanteControlSend(NSString *command, NSTimeInterval timeout) {
    
    BOOL multiline = [command isEqualToString:@"LOG"] || [command isEqualToString:@"DCLIST"];
    return DanteLocalRequest(kDanteControlPort, command, multiline, timeout);
}
