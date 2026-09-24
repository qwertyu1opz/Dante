

#import "TLSTrustManager.h"
#import "DebugLog.h"
#import <Security/Security.h>
#import <dlfcn.h>

@interface TLSTrustManager ()
@property (nonatomic, strong) NSArray *anchors; 
@end

@implementation TLSTrustManager

+ (instancetype)sharedManager {
    static TLSTrustManager *mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[TLSTrustManager alloc] init]; });
    return mgr;
}

- (id)init {
    self = [super init];
    if (self) {
        [self loadAnchors];
    }
    return self;
}

- (void)loadAnchors {
    NSMutableArray *certs = [NSMutableArray array];

    
    NSArray *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"cer" inDirectory:@"Certs"];
    if (paths.count == 0) {
        
        paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"cer" inDirectory:nil];
    }

    for (NSString *path in paths) {
        NSData *der = [NSData dataWithContentsOfFile:path];
        if (!der) continue;
        SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
        if (cert) {
            [certs addObject:(__bridge_transfer id)cert];
        }
    }

    _anchors = certs;
    DLog(@"[TLSTrust] loaded %lu modern root anchors", (unsigned long)certs.count);
}

- (BOOL)hasModernRoots { return self.anchors.count > 0; }
- (NSUInteger)rootCount { return self.anchors.count; }

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forHost:(NSString *)host {
    if (!serverTrust) return YES;

    
    if (self.anchors.count > 0) {
        SecTrustSetAnchorCertificates(serverTrust, (__bridge CFArrayRef)self.anchors);
        SecTrustSetAnchorCertificatesOnly(serverTrust, false); 
    }

    
    typedef OSStatus (*SecTrustSetPoliciesFunc)(SecTrustRef, CFTypeRef);
    static SecTrustSetPoliciesFunc pSecTrustSetPolicies = NULL;
    static dispatch_once_t policyOnce;
    dispatch_once(&policyOnce, ^{
        pSecTrustSetPolicies = (SecTrustSetPoliciesFunc)dlsym(RTLD_DEFAULT, "SecTrustSetPolicies");
    });
    if (pSecTrustSetPolicies && host.length > 0) {
        SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
        if (policy) {
            pSecTrustSetPolicies(serverTrust, policy);
            CFRelease(policy);
        }
    }

    SecTrustResultType result = kSecTrustResultInvalid;
    (void)SecTrustEvaluate(serverTrust, &result);
    
    return YES;
}

- (BOOL)handleAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
                        forConnection:(NSURLConnection *)connection {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    if (![method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        return NO; 
    }

    SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
    NSString *host = challenge.protectionSpace.host;
    [self evaluateServerTrust:serverTrust forHost:host];

    
    NSURLCredential *cred = [NSURLCredential credentialForTrust:serverTrust];
    [challenge.sender useCredential:cred forAuthenticationChallenge:challenge];
    return YES;
}

@end
