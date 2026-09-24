

#import <Foundation/Foundation.h>
#import "PowerConfig.h"
#include <netinet/in.h>

extern const uint16_t kDanteRedirectPort;   
extern const uint16_t kDanteDNSPort;        
extern const uint16_t kDanteTunTCPPort;     

@interface DanteRedirector : NSObject

+ (instancetype)sharedRedirector;

@property (atomic, strong) PowerConfig *powerConfig;

@property (atomic, assign) NSTimeInterval lastClientAt;

- (BOOL)startListenersWithError:(NSString **)error;

- (BOOL)enableWithBypassIPs:(NSArray *)bypassIPs error:(NSString **)error;

- (void)disable;

@property (nonatomic, readonly) BOOL enabled;

- (BOOL)startTunListenersOn:(struct in_addr)addr fake:(struct in_addr)fake error:(NSString **)error;

@end
