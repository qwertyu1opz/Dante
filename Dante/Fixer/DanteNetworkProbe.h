

#import <Foundation/Foundation.h>

@interface DanteNetworkProbe : NSObject

+ (BOOL)detectWhitelistMode;

+ (BOOL)verifyTunnelOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout;

+ (NSString *)traceOnSOCKSPort:(uint16_t)port timeout:(NSTimeInterval)timeout;

+ (NSString *)randomSNIFromResource:(NSString *)name;

@end
