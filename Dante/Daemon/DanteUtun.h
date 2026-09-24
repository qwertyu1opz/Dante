

#import <Foundation/Foundation.h>

@class AWGConfig;

@interface DanteUtun : NSObject

+ (instancetype)sharedUtun;

@property (nonatomic, readonly) BOOL isUp;
@property (nonatomic, readonly) NSString *interfaceName;

@property (nonatomic, assign) NSUInteger clampMSS;

- (BOOL)enableForConfig:(AWGConfig *)config error:(NSString **)error;

- (BOOL)enableForPowerServer:(NSString *)host error:(NSString **)error;
@property (nonatomic, readonly) BOOL powerMode;

- (void)disable;

- (void)restoreLeftovers;

- (void)reassertDNS;

@end

#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
BOOL DNPrimaryUplink(char *nameOut, size_t cap, unsigned *ifindexOut,
                     struct in_addr *gwOut, BOOL *isCellularOut);

void DNRepairScopedRouteIfNeeded(void);
