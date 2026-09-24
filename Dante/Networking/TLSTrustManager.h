

#import <Foundation/Foundation.h>

@interface TLSTrustManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly) BOOL hasModernRoots;
@property (nonatomic, readonly) NSUInteger rootCount;

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust forHost:(NSString *)host;

- (BOOL)handleAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
                        forConnection:(NSURLConnection *)connection;

@end
