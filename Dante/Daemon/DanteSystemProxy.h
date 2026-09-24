

#import <Foundation/Foundation.h>

@interface DanteSystemProxy : NSObject

+ (BOOL)enableProxyOnPort:(uint16_t)port error:(NSString **)error;
+ (BOOL)disableProxyWithError:(NSString **)error;
+ (BOOL)isProxyEnabled;

@end
