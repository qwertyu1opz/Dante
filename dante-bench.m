

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/time.h>

static double GetTimestamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static NSDictionary *TestHTTPThroughProxy(NSString *urlStr, uint16_t proxyPort, double timeout) {
    NSURL *url = [NSURL URLWithString:urlStr];
    NSString *host = [url host];
    int port = [[url port] intValue] ?: ([[[url scheme] lowercaseString] isEqualToString:@"https"] ? 443 : 80);
    BOOL isHTTPS = [[[url scheme] lowercaseString] isEqualToString:@"https"];

    double t0 = GetTimestamp();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return [NSDictionary dictionaryWithObject:@"socket() failed" forKey:@"error"];

    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in paddr;
    memset(&paddr, 0, sizeof(paddr));
    paddr.sin_family = AF_INET;
    paddr.sin_port = htons(proxyPort);
    paddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&paddr, sizeof(paddr)) != 0) {
        close(fd);
        return [NSDictionary dictionaryWithObject:@"connect to proxy failed" forKey:@"error"];
    }
    double tConnected = GetTimestamp();

    if (isHTTPS) {
        
        NSString *req = [NSString stringWithFormat:@"CONNECT %@:%d HTTP/1.1\r\nHost: %@:%d\r\n\r\n", host, port, host, port];
        NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
        send(fd, reqData.bytes, reqData.length, 0);

        char resp[512];
        ssize_t n = recv(fd, resp, sizeof(resp) - 1, 0);
        double tResponse = GetTimestamp();
        close(fd);
        if (n <= 0) return [NSDictionary dictionaryWithObject:@"no response to CONNECT" forKey:@"error"];
        resp[n] = 0;
        NSString *respStr = [NSString stringWithUTF8String:resp];
        BOOL ok = [respStr rangeOfString:@"200"].location != NSNotFound;
        return [NSDictionary dictionaryWithObjectsAndKeys:
            @"https", @"scheme",
            host, @"host",
            [NSNumber numberWithDouble:(tConnected - t0) * 1000.0], @"connect_time",
            [NSNumber numberWithDouble:(tResponse - tConnected) * 1000.0], @"ttfb",
            [NSNumber numberWithDouble:(tResponse - t0) * 1000.0], @"total_time",
            [NSNumber numberWithInt:ok ? 200 : 502], @"status",
            [NSNumber numberWithBool:ok], @"ok",
            nil];
    } else {
        
        NSString *path = [url path];
        if (path.length == 0) path = @"/";
        if ([url query]) path = [NSString stringWithFormat:@"%@?%@", path, [url query]];
        NSString *req = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\nUser-Agent: DanteBench/1.0\r\n\r\n", urlStr, host];
        NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
        send(fd, reqData.bytes, reqData.length, 0);

        NSMutableData *body = [NSMutableData data];
        char chunk[4096];
        double tFirstByte = 0;
        int httpCode = 0;

        for (;;) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            if (tFirstByte == 0) {
                tFirstByte = GetTimestamp();
                chunk[n < 64 ? n : 63] = 0;
                char *sp = strchr(chunk, ' ');
                if (sp) httpCode = atoi(sp + 1);
            }
            [body appendBytes:chunk length:n];
        }
        double tDone = GetTimestamp();
        close(fd);

        double speed = (body.length > 0 && (tDone - t0) > 0) ? (body.length / 1024.0) / (tDone - t0) : 0.0;

        return [NSDictionary dictionaryWithObjectsAndKeys:
            @"http", @"scheme",
            host, @"host",
            [NSNumber numberWithDouble:(tConnected - t0) * 1000.0], @"connect_time",
            [NSNumber numberWithDouble:(tFirstByte - tConnected) * 1000.0], @"ttfb",
            [NSNumber numberWithDouble:(tDone - t0) * 1000.0], @"total_time",
            [NSNumber numberWithUnsignedInteger:body.length], @"bytes",
            [NSNumber numberWithInt:httpCode], @"status",
            [NSNumber numberWithDouble:speed], @"speed_kbps",
            [NSNumber numberWithBool:httpCode >= 200 && httpCode < 400], @"ok",
            nil];
    }
}

static NSDictionary *TestSystemFoundation(NSString *urlStr, double timeout) {
    double t0 = GetTimestamp();
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:timeout];
    [req setValue:@"DanteSystemTest/1.0" forHTTPHeaderField:@"User-Agent"];

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    double tDone = GetTimestamp();

    if (err) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
            urlStr, @"url",
            [err localizedDescription] ?: @"unknown error", @"error",
            [NSNumber numberWithDouble:(tDone - t0) * 1000.0], @"total_time",
            [NSNumber numberWithBool:NO], @"ok",
            nil];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
        urlStr, @"url",
        [NSNumber numberWithInteger:[resp statusCode]], @"status",
        [NSNumber numberWithUnsignedInteger:data.length], @"bytes",
        [NSNumber numberWithDouble:(tDone - t0) * 1000.0], @"total_time",
        [NSNumber numberWithBool:[resp statusCode] >= 200 && [resp statusCode] < 400], @"ok",
        nil];
}

static NSDictionary *TestYouTubeBrowse(double timeout) {
    double t0 = GetTimestamp();
    NSURL *url = [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:timeout];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    NSString *body = @"{\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20240101.00.00\"}},\"browseId\":\"FEwhat_to_watch\"}";
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    double tDone = GetTimestamp();
    if (err) {
        return [NSDictionary dictionaryWithObjectsAndKeys:
            [err localizedDescription], @"error",
            [NSNumber numberWithDouble:(tDone - t0) * 1000.0], @"total_time",
            [NSNumber numberWithBool:NO], @"ok", nil];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInteger:[resp statusCode]], @"status",
        [NSNumber numberWithUnsignedInteger:data.length], @"bytes",
        [NSNumber numberWithDouble:(tDone - t0) * 1000.0], @"total_time",
        [NSNumber numberWithBool:[resp statusCode] == 200], @"ok", nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL sysOnly = (argc > 1 && strcmp(argv[1], "--sys") == 0);
        printf("\n============================================================\n");
        printf("         DANTE TUNNEL EXPLORER & BENCHMARK\n");
        printf("============================================================\n");

        uint16_t port = 10808;

        if (!sysOnly) {
        
        printf("\n[1] Cloudflare Edge & WARP Status:\n");
        NSDictionary *traceRes = TestHTTPThroughProxy(@"http://www.cloudflare.com/cdn-cgi/trace", port, 8.0);
        if ([[traceRes objectForKey:@"ok"] boolValue]) {
            printf("    ✓ HTTP Proxy CONNECT OK: TTFB = %.1f ms, Status = %d\n",
                   [[traceRes objectForKey:@"ttfb"] doubleValue],
                   [[traceRes objectForKey:@"status"] intValue]);
        } else {
            printf("    ✗ Trace error: %s\n", [[traceRes objectForKey:@"error"] UTF8String] ?: "status error");
        }

        
        printf("\n[2] Multi-Domain Survey (HTTP & HTTPS):\n");
        NSArray *targets = [NSArray arrayWithObjects:
            @"http://www.cloudflare.com/",
            @"https://www.cloudflare.com/",
            @"http://www.apple.com/",
            @"https://www.apple.com/",
            @"http://www.google.com/",
            @"https://www.google.com/",
            @"https://telegram.org/",
            @"http://ru.wikipedia.org/",
            @"https://ru.wikipedia.org/",
            @"https://www.youtube.com/",
            nil
        ];

        int passed = 0, total = (int)targets.count;
        for (NSString *t in targets) {
            NSDictionary *r = TestHTTPThroughProxy(t, port, 10.0);
            if ([[r objectForKey:@"ok"] boolValue]) {
                passed++;
                printf("    ✓ [%-5s] %-28s : %3d (connect: %5.1f ms, ttfb: %5.1f ms)\n",
                       [[r objectForKey:@"scheme"] UTF8String],
                       [[r objectForKey:@"host"] UTF8String],
                       [[r objectForKey:@"status"] intValue],
                       [[r objectForKey:@"connect_time"] doubleValue],
                       [[r objectForKey:@"ttfb"] doubleValue]);
            } else {
                printf("    ✗ [%-5s] %-28s : FAILED (%s)\n",
                       [t hasPrefix:@"https"] ? "https" : "http",
                       [[[NSURL URLWithString:t] host] UTF8String],
                       [[r objectForKey:@"error"] UTF8String] ?: [[[r objectForKey:@"status"] stringValue] UTF8String]);
            }
        }
        printf("    Результат: %d/%d успешно\n", passed, total);

        
        printf("\n[3] Throughput & MTU/MSS Benchmark (Cloudflare CDN):\n");
        NSArray *sizes = [NSArray arrayWithObjects:
            [NSNumber numberWithLong:102400],
            [NSNumber numberWithLong:512000],
            [NSNumber numberWithLong:1048576],
            [NSNumber numberWithLong:2097152],
            [NSNumber numberWithLong:5242880],
            [NSNumber numberWithLong:10485760],
            [NSNumber numberWithLong:20971520],
            nil
        ];
        for (NSNumber *sz in sizes) {
            long b = [sz longValue];
            NSString *url = [NSString stringWithFormat:@"http://speed.cloudflare.com/__down?bytes=%ld", b];
            NSDictionary *sr = TestHTTPThroughProxy(url, port, 30.0);
            if ([[sr objectForKey:@"ok"] boolValue]) {
                double speed = [[sr objectForKey:@"speed_kbps"] doubleValue];
                double mbps = (speed * 8.0) / 1024.0;
                printf("    ✓ %6.1f KB chunk: %7.1f ms -> %6.1f KB/s (%4.2f Mbps) [%lu bytes received]\n",
                       b / 1024.0,
                       [[sr objectForKey:@"total_time"] doubleValue],
                       speed, mbps,
                       [[sr objectForKey:@"bytes"] unsignedLongValue]);
            } else {
                printf("    ✗ %6.1f KB chunk: FAILED (%s)\n",
                       b / 1024.0, [[sr objectForKey:@"error"] UTF8String] ?: "status error");
            }
        }
        } 

        
        printf("\n[4] YouTube Innertube API POST (JSON browse) FIRST:\n");
        NSDictionary *ytRes = TestYouTubeBrowse(12.0);
        if ([[ytRes objectForKey:@"ok"] boolValue]) {
            printf("    ✓ YouTube browse POST : %d OK (%.1f ms, %lu bytes)\n",
                   [[ytRes objectForKey:@"status"] intValue],
                   [[ytRes objectForKey:@"total_time"] doubleValue],
                   [[ytRes objectForKey:@"bytes"] unsignedLongValue]);
        } else {
            printf("    ✗ YouTube browse POST : FAILED status=%d (%s)\n",
                   [[ytRes objectForKey:@"status"] intValue],
                   [[ytRes objectForKey:@"error"] UTF8String] ?: "error");
        }

        printf("\n[4b] iOS System CFNetwork Targets:\n");
        NSArray *sysTargets = [NSArray arrayWithObjects:
            @"http://www.cloudflare.com/cdn-cgi/trace",
            @"http://captive.apple.com/",
            @"http://www.google.com/",
            @"https://www.cloudflare.com/cdn-cgi/trace",
            @"https://www.google.com/",
            @"https://www.youtube.com/",
            @"https://www.youtube.com/youtubei/v1/browse?prettyPrint=false",
            @"https://i.ytimg.com/generate_204",
            nil
        ];
        for (NSString *st in sysTargets) {
            NSDictionary *res = TestSystemFoundation(st, 10.0);
            if ([[res objectForKey:@"ok"] boolValue]) {
                printf("    ✓ %-38s : %d OK (%5.1f ms, %lu bytes)\n",
                       [st UTF8String],
                       [[res objectForKey:@"status"] intValue],
                       [[res objectForKey:@"total_time"] doubleValue],
                       [[res objectForKey:@"bytes"] unsignedLongValue]);
            } else {
                printf("    ✗ %-38s : FAILED status=%d (%s)\n",
                       [st UTF8String],
                       [[res objectForKey:@"status"] intValue],
                       [[res objectForKey:@"error"] UTF8String] ?: "HTTP status error");
            }
        }

        printf("\n============================================================\n");
        printf("Исследование завершено.\n\n");
    }
    return 0;
}
