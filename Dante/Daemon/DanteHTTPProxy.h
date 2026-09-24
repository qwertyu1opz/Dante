

#import <Foundation/Foundation.h>
#import "PowerConfig.h"

extern const uint16_t kDanteHTTPProxyPort;   

@interface DanteHTTPProxy : NSObject

+ (instancetype)sharedProxy;

@property (atomic, strong) PowerConfig *powerConfig;

@property (atomic, assign) NSTimeInterval lastClientAt;
- (BOOL)startWithError:(NSString **)error;

- (void)handleClient:(int)clientFd initialData:(NSData *)initialData;

- (void)processClientInline:(int)clientFd initialData:(NSData *)initialData;

@end
