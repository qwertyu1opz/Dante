
#import "DanteCurl.h"
#import "DebugLog.h"
#include "dcurl.h"

NSString * const kDanteCurlErrorDomain = @"DanteCurl";

@implementation DanteCurl

static dc_ctx *DanteCurlContext(void) {
    static dc_ctx *ctx = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = dc_ctx_new();
        if (!ctx) {
            DLog(@"[dcurl] cannot create the TLS context");
            return;
        }
        NSArray *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"cer" inDirectory:@"Certs"];
        NSUInteger rejected = 0;
        for (NSString *path in paths) {
            NSData *der = [NSData dataWithContentsOfFile:path];
            if (der.length == 0 || dc_ctx_add_ca_der(ctx, der.bytes, der.length) != 0) rejected++;
        }
        DLog(@"[dcurl] %lu trusted roots loaded, %lu rejected",
             (unsigned long)dc_ctx_ca_count(ctx), (unsigned long)rejected);
    });
    return ctx;
}

+ (BOOL)isReady {
    return dc_ctx_ca_count(DanteCurlContext()) > 0;
}

+ (NSData *)requestURL:(NSString *)url
                method:(NSString *)method
               headers:(NSDictionary *)headers
                  body:(NSData *)body
             socksPort:(uint16_t)socksPort
             connectIP:(NSString *)connectIP
               timeout:(NSTimeInterval)timeout
            statusCode:(NSInteger *)outStatus
                 error:(NSError **)error {
    if (outStatus) *outStatus = 0;

    NSUInteger count = headers.count, i = 0;
    char **lines = (char **)calloc(count + 1, sizeof(char *));
    for (NSString *key in headers) {
        NSString *line = [NSString stringWithFormat:@"%@: %@", key, headers[key]];
        lines[i++] = strdup([line UTF8String]);
    }

    dc_request req;
    memset(&req, 0, sizeof(req));
    req.method = method.length ? [method UTF8String] : NULL;
    req.url = [url UTF8String];
    req.headers = (const char *const *)lines;
    req.body = body.bytes;
    req.body_len = body.length;
    req.socks5_port = socksPort;
    req.connect_ip = connectIP.length ? [connectIP UTF8String] : NULL;
    req.timeout_ms = timeout > 0 ? (int)(timeout * 1000.0) : 0;

    dc_response resp;
    int rc = dc_perform(DanteCurlContext(), &req, &resp);

    for (i = 0; i < count; i++) free(lines[i]);
    free(lines);

    if (rc != 0) {
        NSString *reason = [NSString stringWithUTF8String:resp.error] ?: @"request failed";
        DLog(@"[dcurl] %@ failed: %@", url, reason);
        dc_response_free(&resp);
        if (error) *error = [NSError errorWithDomain:kDanteCurlErrorDomain code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: reason}];
        return nil;
    }

    if (outStatus) *outStatus = resp.status;
    NSData *payload = [NSData dataWithBytes:resp.body length:resp.body_len];
    DLog(@"[dcurl] %@: HTTP %ld, %lu bytes", url, (long)resp.status, (unsigned long)resp.body_len);
    dc_response_free(&resp);
    return payload;
}

@end
