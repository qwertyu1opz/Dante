

#import "DanteHTTPProxy.h"
#import "PowerSession.h"
#import "AmneziaWGManager.h"
#import "DebugLog.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

const uint16_t kDanteHTTPProxyPort = 10810;

static const NSUInteger kMaxHead = 32 * 1024;

@implementation DanteHTTPProxy {
    int _fd;
}

+ (instancetype)sharedProxy {
    static DanteHTTPProxy *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[DanteHTTPProxy alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) _fd = -1;
    return self;
}

- (BOOL)startWithError:(NSString **)error {
    if (_fd >= 0) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDanteHTTPProxyPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 128) != 0) {
        if (fd >= 0) close(fd);
        if (error) *error = [NSString stringWithFormat:@"порт %u: %s", kDanteHTTPProxyPort, strerror(errno)];
        return NO;
    }
    _fd = fd;
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    DLog(@"[proxy] HTTP-прокси: 127.0.0.1:%u", kDanteHTTPProxyPort);
    return YES;
}

- (void)acceptLoop {
    for (;;) {
        @autoreleasepool {
            int client = accept(_fd, NULL, NULL);
            if (client < 0) continue;
            int one = 1;
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            [self handleClient:client initialData:nil];
        }
    }
}

- (void)handleClient:(int)clientFd initialData:(NSData *)initialData {
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(clientThread:)
                                            object:@[@(clientFd), initialData ?: [NSData data]]];
    t.stackSize = 256 * 1024;
    [t start];
}

- (void)clientThread:(NSArray *)args {
    @autoreleasepool {
        int fd = [[args objectAtIndex:0] intValue];
        NSData *initData = [args objectAtIndex:1];
        [self processClientInline:fd initialData:initData];
    }
}

static void DanteSendAndClose(int fd, NSString *response) {
    NSData *d = [response dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length) send(fd, d.bytes, d.length, 0);
    close(fd);
}

static NSString * const kBadGateway =
    @"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

static BOOL DanteSplitAuthority(NSString *authority, uint16_t defaultPort,
                                NSString **host, uint16_t *port) {
    if (authority.length == 0 || [authority hasPrefix:@"["]) return NO;   
    NSRange colon = [authority rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) {
        *host = authority;
        *port = defaultPort;
    } else {
        *host = [authority substringToIndex:colon.location];
        int p = [[authority substringFromIndex:colon.location + 1] intValue];
        if (p <= 0 || p > 65535) return NO;
        *port = (uint16_t)p;
    }
    return (*host).length > 0;
}

#pragma mark - Локальные адреса — мимо туннеля

static BOOL DanteIsLocalHost(NSString *host) {
    NSString *h = [host lowercaseString];
    if ([h isEqualToString:@"localhost"] || [h hasSuffix:@".local"]) return YES;
    struct in_addr a;
    if (inet_pton(AF_INET, [h UTF8String], &a) != 1) return NO;
    uint32_t ip = ntohl(a.s_addr);
    return (ip >> 24) == 127 || (ip >> 24) == 10 ||
           (ip >> 20) == (172 << 4 | 1) ||            
           (ip >> 16) == (192 << 8 | 168) ||          
           (ip >> 16) == (169 << 8 | 254);            
}

static BOOL DanteWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static void DanteRelayDirect(int clientFd, NSString *host, uint16_t port,
                             NSData *okReply, NSData *initialData, NSString *failReply) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", port);
    int up = -1;
    if (getaddrinfo([host UTF8String], portStr, &hints, &res) == 0 && res) {
        up = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (up >= 0 && connect(up, res->ai_addr, res->ai_addrlen) != 0) {
            close(up);
            up = -1;
        }
        freeaddrinfo(res);
    }
    if (up < 0) {
        DLog(@"[proxy] напрямую %@:%u не соединиться: %s", host, port, strerror(errno));
        DanteSendAndClose(clientFd, failReply);
        return;
    }
    int one = 1;
    setsockopt(up, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    if ((okReply && !DanteWriteAll(clientFd, okReply.bytes, okReply.length)) ||
        (initialData.length && !DanteWriteAll(up, initialData.bytes, initialData.length))) {
        close(up);
        close(clientFd);
        return;
    }

    uint8_t buf[16384];
    int maxFd = (clientFd > up ? clientFd : up) + 1;
    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(clientFd, &rfds);
        FD_SET(up, &rfds);
        if (select(maxFd, &rfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        int from = FD_ISSET(clientFd, &rfds) ? clientFd : up;
        int to = (from == clientFd) ? up : clientFd;
        ssize_t n = read(from, buf, sizeof(buf));
        if (n <= 0 || !DanteWriteAll(to, buf, (size_t)n)) break;
    }
    close(up);
    close(clientFd);
}

static BOOL DanteRelayViaPower(int clientFd, NSString *host, uint16_t port,
                               NSData *okReply, NSData *initialData, NSString *failReply) {
    PowerConfig *pc = [DanteHTTPProxy sharedProxy].powerConfig;
    if (!pc) return NO;
    [DanteHTTPProxy sharedProxy].lastClientAt = [NSDate timeIntervalSinceReferenceDate];
    PowerSession *session = [[PowerSession alloc] initWithConfig:pc];
    if ([session relayClient:clientFd host:host port:port
                     okReply:okReply initialData:initialData]) {
        return YES;
    }
    DLog(@"[proxy] через свой сервер до %@:%u не дошли", host, port);
    DanteSendAndClose(clientFd, failReply);
    return YES;
}

static BOOL DanteReadExact(int fd, NSData *pre, NSUInteger *off, uint8_t *out, size_t len) {
    size_t got = 0;
    while (got < len && *off < pre.length) {
        out[got++] = ((const uint8_t *)pre.bytes)[(*off)++];
    }
    while (got < len) {
        ssize_t n = recv(fd, out + got, len - got, 0);
        if (n <= 0) return NO;
        got += (size_t)n;
    }
    return YES;
}

static void DanteHandleSOCKS5(int fd, NSData *pre) {
    NSUInteger off = 0;
    uint8_t hdr[4];
    if (!DanteReadExact(fd, pre, &off, hdr, 2)) { close(fd); return; }
    uint8_t methods[255];
    if (hdr[1] && !DanteReadExact(fd, pre, &off, methods, hdr[1])) { close(fd); return; }
    const uint8_t noAuth[2] = {5, 0};
    if (send(fd, noAuth, 2, 0) != 2) { close(fd); return; }

    NSData *rest = off < pre.length ? [pre subdataWithRange:NSMakeRange(off, pre.length - off)] : nil;
    off = 0;
    if (!DanteReadExact(fd, rest, &off, hdr, 4) || hdr[0] != 5) { close(fd); return; }
    NSString *host = nil;
    if (hdr[3] == 1) {
        uint8_t a[4];
        if (!DanteReadExact(fd, rest, &off, a, 4)) { close(fd); return; }
        host = [NSString stringWithFormat:@"%u.%u.%u.%u", a[0], a[1], a[2], a[3]];
    } else if (hdr[3] == 3) {
        uint8_t l, name[256];
        if (!DanteReadExact(fd, rest, &off, &l, 1) || !DanteReadExact(fd, rest, &off, name, l)) { close(fd); return; }
        host = [[NSString alloc] initWithBytes:name length:l encoding:NSISOLatin1StringEncoding];
    } else if (hdr[3] == 4) {
        uint8_t a[16];
        char s[INET6_ADDRSTRLEN];
        if (!DanteReadExact(fd, rest, &off, a, 16) || !inet_ntop(AF_INET6, a, s, sizeof(s))) { close(fd); return; }
        host = [NSString stringWithUTF8String:s];
    }
    uint8_t pb[2];
    if (!host || !DanteReadExact(fd, rest, &off, pb, 2)) { close(fd); return; }
    uint16_t port = (uint16_t)((pb[0] << 8) | pb[1]);

    
    NSData *initial = (rest && off < rest.length)
        ? [rest subdataWithRange:NSMakeRange(off, rest.length - off)] : nil;
    const uint8_t okBytes[10] = {5, 0, 0, 1, 0, 0, 0, 0, 0, 0};
    const uint8_t failBytes[10] = {5, 5, 0, 1, 0, 0, 0, 0, 0, 0};
    NSData *ok = [NSData dataWithBytes:okBytes length:sizeof(okBytes)];

    if (hdr[1] != 1) {   
        const uint8_t unsupported[10] = {5, 7, 0, 1, 0, 0, 0, 0, 0, 0};
        send(fd, unsupported, sizeof(unsupported), 0);
        close(fd);
        return;
    }
    
    struct timeval none = {0, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof(none));
    DLog(@"[socks] %@:%u", host, port);
    PowerConfig *pc = [DanteHTTPProxy sharedProxy].powerConfig;
    if (pc) {
        [DanteHTTPProxy sharedProxy].lastClientAt = [NSDate timeIntervalSinceReferenceDate];
        PowerSession *session = [[PowerSession alloc] initWithConfig:pc];
        if ([session relayClient:fd host:host port:port okReply:ok initialData:initial]) return;
        DLog(@"[socks] через свой сервер до %@:%u не дошли", host, port);
    } else if (DanteIsLocalHost(host)) {
        DanteRelayDirect(fd, host, port, ok, initial, @"");
        return;
    } else {
        DLog(@"[socks] %@:%u — Power не включён", host, port);
    }
    send(fd, failBytes, sizeof(failBytes), 0);
    close(fd);
}

- (void)processClientInline:(int)fd initialData:(NSData *)initData {
    @autoreleasepool {
        
        if (initData.length == 0) {
            uint8_t first[512];
            struct timeval tv0 = {30, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv0, sizeof(tv0));
            ssize_t n = recv(fd, first, sizeof(first), 0);
            if (n <= 0) { close(fd); return; }
            initData = [NSData dataWithBytes:first length:(NSUInteger)n];
        }
        if (((const uint8_t *)initData.bytes)[0] == 5) {
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            DanteHandleSOCKS5(fd, initData);
            return;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int bufSize = 256 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));

        struct timeval tv = {30, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        
        NSMutableData *buf = [NSMutableData dataWithData:initData];
        NSRange end = NSMakeRange(NSNotFound, 0);
        NSData *crlf2 = [NSData dataWithBytes:"\r\n\r\n" length:4];
        end = [buf rangeOfData:crlf2 options:0 range:NSMakeRange(0, buf.length)];

        uint8_t chunk[4096];
        while (end.location == NSNotFound && buf.length < kMaxHead) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) { close(fd); return; }
            [buf appendBytes:chunk length:(NSUInteger)n];
            end = [buf rangeOfData:crlf2 options:0 range:NSMakeRange(0, buf.length)];
        }
        if (end.location == NSNotFound) { close(fd); return; }

        
        struct timeval none = {0, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof(none));

        NSUInteger headLen = end.location + 4;
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)]
                                               encoding:NSISOLatin1StringEncoding];
        NSData *rest = [buf subdataWithRange:NSMakeRange(headLen, buf.length - headLen)];
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) { DanteSendAndClose(fd, kBadGateway); return; }

        NSArray *parts = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
        if (parts.count < 2) { DanteSendAndClose(fd, kBadGateway); return; }
        NSString *method = [parts objectAtIndex:0];
        NSString *target = [parts objectAtIndex:1];
        NSString *version = parts.count > 2 ? [parts objectAtIndex:2] : @"HTTP/1.1";
        DLogVerbose(@"[HTTP proxy] client %d: %@ %@ (rest %lu b)", fd, method, target, (unsigned long)rest.length);

        
        
        BOOL isConnect = [method caseInsensitiveCompare:@"CONNECT"] == NSOrderedSame;
        if (isConnect) {
            NSString *h = nil;
            uint16_t p = 443;
            if (DanteSplitAuthority(target, 443, &h, &p) && DanteIsLocalHost(h)) {
                NSData *ok = [@"HTTP/1.1 200 Connection Established\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
                DanteRelayDirect(fd, h, p, ok, rest, kBadGateway);
                return;
            }
        }

        
        
        AmneziaWGManager *mgr = [AmneziaWGManager sharedManager];
        if (isConnect && self.powerConfig) {
            NSString *host = nil;
            uint16_t port = 443;
            if (!DanteSplitAuthority(target, 443, &host, &port)) {
                DanteSendAndClose(fd, kBadGateway);
                return;
            }
            NSData *ok = [@"HTTP/1.1 200 Connection Established\r\n\r\n"
                          dataUsingEncoding:NSUTF8StringEncoding];
            if (DanteRelayViaPower(fd, host, port, ok, rest, kBadGateway)) return;
        }
        if (isConnect && !mgr.isConnected) {
            DLog(@"[proxy] запрос %@, но туннель не подключён", target);
            DanteSendAndClose(fd, kBadGateway);
            return;
        }

        
        if ([method caseInsensitiveCompare:@"CONNECT"] == NSOrderedSame) {
            NSString *host = nil;
            uint16_t port = 443;
            if (!DanteSplitAuthority(target, 443, &host, &port)) {
                DanteSendAndClose(fd, kBadGateway);
                return;
            }
            NSData *okReply = [@"HTTP/1.1 200 Connection Established\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            NSData *failReply = [kBadGateway dataUsingEncoding:NSUTF8StringEncoding];
            BOOL adopted = [mgr relayProxiedClientInline:fd host:host port:port
                                                 okReply:okReply failReply:failReply initialData:rest];
            if (!adopted) {
                DanteSendAndClose(fd, kBadGateway);
            }
            return;
        }

        
        NSString *host = nil;
        uint16_t port = 80;
        NSString *path = @"/";

        if ([target hasPrefix:@"http://"]) {
            NSString *withoutScheme = [target substringFromIndex:7];
            NSRange slash = [withoutScheme rangeOfString:@"/"];
            NSString *auth = (slash.location == NSNotFound) ? withoutScheme : [withoutScheme substringToIndex:slash.location];
            path = (slash.location == NSNotFound) ? @"/" : [withoutScheme substringFromIndex:slash.location];
            if (!DanteSplitAuthority(auth, 80, &host, &port)) {
                DanteSendAndClose(fd, kBadGateway);
                return;
            }
        } else if ([target hasPrefix:@"/"] || [target isEqualToString:@"*"]) {
            path = target;
            for (NSUInteger i = 1; i < lines.count; i++) {
                NSString *line = [lines objectAtIndex:i];
                if ([line rangeOfString:@"host:" options:NSCaseInsensitiveSearch].location == 0) {
                    NSString *val = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    DanteSplitAuthority(val, 80, &host, &port);
                    break;
                }
            }
            if (host.length == 0) {
                DanteSendAndClose(fd, kBadGateway);
                return;
            }
        } else {
            DanteSendAndClose(fd, kBadGateway);
            return;
        }

        
        NSMutableString *rebuilt = [NSMutableString stringWithFormat:@"%@ %@ %@\r\n", method, path, version];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *line = [lines objectAtIndex:i];
            if (line.length == 0) continue;
            if ([line rangeOfString:@"proxy-connection:" options:NSCaseInsensitiveSearch].location == 0) {
                [rebuilt appendString:@"Connection: close\r\n"];
            } else if ([line rangeOfString:@"proxy-authorization:" options:NSCaseInsensitiveSearch].location == 0) {
                continue;
            } else {
                [rebuilt appendString:line];
                [rebuilt appendString:@"\r\n"];
            }
        }
        [rebuilt appendString:@"\r\n"];

        NSMutableData *reqData = [NSMutableData dataWithData:[rebuilt dataUsingEncoding:NSISOLatin1StringEncoding]];
        if (rest.length > 0) [reqData appendData:rest];

        if (DanteIsLocalHost(host)) {
            DanteRelayDirect(fd, host, port, nil, reqData, kBadGateway);
            return;
        }
        if (self.powerConfig && DanteRelayViaPower(fd, host, port, nil, reqData, kBadGateway)) {
            return;
        }
        if (!mgr.isConnected) {
            DLog(@"[proxy] запрос %@, но туннель не подключён", target);
            DanteSendAndClose(fd, kBadGateway);
            return;
        }

        NSData *failReply = [kBadGateway dataUsingEncoding:NSUTF8StringEncoding];
        BOOL adopted = [mgr relayProxiedClientInline:fd host:host port:port
                                             okReply:nil failReply:failReply initialData:reqData];
        if (!adopted) {
            DanteSendAndClose(fd, kBadGateway);
        }
    }
}

@end