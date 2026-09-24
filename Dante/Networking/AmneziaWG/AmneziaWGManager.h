

#import <Foundation/Foundation.h>
#import "AWGTunnel.h"

@class AWGConfig;

extern NSString * const kAmneziaWGStatusDidChangeNotification;

@interface AmneziaWGManager : NSObject <AWGTunnelDelegate>

+ (instancetype)sharedManager;

@property (nonatomic, readonly) AWGTunnelState state;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) uint16_t socksPort;

@property (nonatomic, readonly) NSTimeInterval lastDataAt;

@property (nonatomic, assign) uint16_t preferredSOCKSPort;

@property (nonatomic, assign) BOOL keepRadioAwake;

@property (atomic, copy) AWGRawPacketHandler rawPacketHandler;
@property (nonatomic, readonly) AWGConfig *currentConfig;
@property (nonatomic, copy, readonly) NSString *statusDescription;
@property (nonatomic, copy, readonly) NSString *lastError;

@property (nonatomic, strong, readonly) NSArray *savedConfigs;
@property (nonatomic, assign, readonly) NSInteger activeIndex;

- (void)addConfig:(AWGConfig *)config;
- (void)removeConfigAtIndex:(NSUInteger)index;
- (void)removeAllConfigs;

- (void)removeConfigsPassingTest:(BOOL (^)(AWGConfig *config))test;
- (void)selectConfigAtIndex:(NSUInteger)index;

- (void)connectWithCompletion:(void(^)(BOOL success, NSString *  errorMsg))completion;
- (void)disconnect;
- (void)reconnect;

+ (AWGConfig *)generateConfigWithPrivateKey:(NSString * )privateKey
                                peerPublicKey:(NSString *)peerPublicKey
                                     endpoint:(NSString *)endpoint
                                       junkCount:(NSUInteger)jc
                                        junkMin:(NSUInteger)jmin
                                        junkMax:(NSUInteger)jmax;

- (void)generateWarpConfigWithCompletion:(void(^)(BOOL success, NSString *errorMsg))completion;

- (void)useBundledSeedWithCompletion:(void(^)(BOOL success, NSString *errorMsg))completion;

- (void)setEndpointForCurrentConfig:(NSString *)endpoint;

- (void)rotateEndpointAndReconnect;

- (BOOL)shouldRouteTrafficForHost:(NSString *)host;

- (BOOL)adoptTransparentClient:(int)fd host:(NSString *)host port:(uint16_t)port;

- (BOOL)adoptProxiedClient:(int)fd host:(NSString *)host port:(uint16_t)port
                   okReply:(NSData *)okReply failReply:(NSData *)failReply
               initialData:(NSData *)initialData;

- (BOOL)relayProxiedClientInline:(int)fd host:(NSString *)host port:(uint16_t)port
                         okReply:(NSData *)okReply failReply:(NSData *)failReply
                     initialData:(NSData *)initialData;

- (void)sendRawIPPacket:(const uint8_t *)bytes length:(size_t)length;
- (void)sendRawIPPackets:(const AWGRawPacket *)packets count:(size_t)count;

@property (nonatomic, assign) int utunFd;

- (BOOL)bindTunnelToInterfaceIndex:(unsigned)index;

- (NSData *)relayDNSQuery:(NSData *)query;

- (NSString *)resolveHostThroughTunnel:(NSString *)host;

@end
