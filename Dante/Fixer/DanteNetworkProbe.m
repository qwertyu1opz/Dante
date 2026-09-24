

#import "DanteNetworkProbe.h"
#import "DebugLog.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static int DanteTCPConnect(const char *ip, uint16_t port, NSTimeInterval timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (rc != 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        struct timeval tv;
        tv.tv_sec = (time_t)timeout;
        tv.tv_usec = (suseconds_t)((timeout - (time_t)timeout) * 1000000.0);
        rc = select(fd + 1, NULL, &wfds, NULL, &tv);
        if (rc <= 0) {
            close(fd);
            return -1;
        }
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0 || err != 0) {
            close(fd);
            return -1;
        }
    }

    
    fcntl(fd, F_SETFL, flags);
    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (time_t)timeout) * 1000000.0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return fd;
}

static BOOL DanteSendAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

@implementation DanteNetworkProbe

+ (BOOL)detectWhitelistMode {
    
    
    const char *hosts[] = { "1.1.1.1", "1.0.0.1", "8.8.8.8" };
    for (size_t i = 0; i < sizeof(hosts) / sizeof(hosts[0]); i++) {
        int fd = DanteTCPConnect(hosts[i], 443, 0.35);
        if (fd >= 0) {
            close(fd);
            return NO;
        }
    }
    return YES;
}

+ (BOOL)verifyTunnelOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout {
    return [self traceOnSOCKSPort:port timeout:timeout] != nil;
}

+ (NSString *)traceOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout {
    int fd = DanteTCPConnect("127.0.0.1", port, timeout);
    if (fd < 0) return nil;

    BOOL ok = NO;
    NSString *text = nil;
    @try {
        
        uint8_t greet[] = { 0x05, 0x01, 0x00 };
        if (!DanteSendAll(fd, greet, sizeof(greet))) @throw @(1);
        uint8_t gresp[2];
        if (recv(fd, gresp, sizeof(gresp), 0) != 2 || gresp[0] != 0x05 || gresp[1] != 0x00)
            @throw @(2);

        
        
        
        
        
        const char *host = "www.cloudflare.com";
        size_t hostLen = strlen(host);
        uint8_t conn[5 + 255 + 2];
        conn[0] = 0x05; conn[1] = 0x01; conn[2] = 0x00; conn[3] = 0x03;
        conn[4] = (uint8_t)hostLen;
        memcpy(conn + 5, host, hostLen);
        conn[5 + hostLen] = 0x00; conn[6 + hostLen] = 0x50;   
        if (!DanteSendAll(fd, conn, 7 + hostLen)) @throw @(3);
        uint8_t cresp[10];
        ssize_t n = recv(fd, cresp, sizeof(cresp), MSG_WAITALL);
        if (n < 10 || cresp[0] != 0x05 || cresp[1] != 0x00) @throw @(4);

        
        const char *req = "GET /cdn-cgi/trace HTTP/1.1\r\n"
                          "Host: www.cloudflare.com\r\n"
                          "User-Agent: Dante/1.0\r\n"
                          "Connection: close\r\n\r\n";
        if (!DanteSendAll(fd, req, strlen(req))) @throw @(5);

        NSMutableData *resp = [NSMutableData dataWithCapacity:2048];
        uint8_t buf[2048];
        while ([resp length] < 16384) {
            n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) break;
            [resp appendBytes:buf length:(NSUInteger)n];
        }
        text = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
        DLog(@"[Probe] получено %lu байт: %@", (unsigned long)resp.length,
             text.length > 0 ? [text substringToIndex:MIN((NSUInteger)200, text.length)] : @"(бинарь/пусто)");
        if (text.length > 0 &&
            [text rangeOfString:@"200"].location != NSNotFound &&
            [text rangeOfString:@"warp=" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            ok = YES;
        }
    }
    @catch (id ignored) {
        ok = NO;
    }
    close(fd);
    return ok ? text : nil;
}

+ (NSString *)randomSNIFromResource:(NSString *)name {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"sni"];
    if (!path) return nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *s = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (s.length > 0 && ![s hasPrefix:@"#"]) [names addObject:s];
    }
    if (names.count == 0) return nil;
    return [names objectAtIndex:arc4random_uniform((uint32_t)names.count)];
}

@end
