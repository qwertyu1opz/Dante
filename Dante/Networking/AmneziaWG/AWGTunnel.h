

#import <Foundation/Foundation.h>

@class AWGConfig;
@class AWGHandshake;

typedef NS_ENUM(NSInteger, AWGTunnelState) {
    AWGTunnelStateIdle = 0,
    AWGTunnelStateConnecting,
    AWGTunnelStateConnected,
    AWGTunnelStateReconnecting,
    AWGTunnelStateFailed
};

@protocol AWGTunnelDelegate <NSObject>
@optional
- (void)tunnelDidChangeState:(AWGTunnelState)state;
- (void)tunnelDidFailWithError:(NSError *)error;
@end

typedef void (^AWGRawPacketHandler)(const uint8_t *bytes, size_t length);

int awg_grow_sockbuf(int fd, int opt, int want);

typedef struct { const uint8_t *bytes; size_t length; } AWGRawPacket;

@interface AWGTunnel : NSObject

@property (nonatomic, readonly) AWGTunnelState state;
@property (nonatomic, readonly) uint16_t socksPort;   
@property (nonatomic, weak) id<AWGTunnelDelegate> delegate;

@property (nonatomic, assign) uint16_t preferredSOCKSPort;

@property (nonatomic, assign) BOOL keepRadioAwake;

@property (atomic, copy) AWGRawPacketHandler rawPacketHandler;
@property (nonatomic, readonly) NSTimeInterval handshakeAge;

@property (nonatomic, readonly) NSTimeInterval lastDataAt;
@property (nonatomic, readonly) uint64_t bytesSent;
@property (nonatomic, readonly) uint64_t bytesReceived;

- (instancetype)initWithConfig:(AWGConfig *)config;

- (void)startWithCompletion:(void(^)(BOOL success, NSError *  error))completion;

- (void)stop;

- (void)rotateKeys;

- (NSString *)resolveHostThroughTunnel:(NSString *)host;

- (void)adoptTransparentClient:(int)fd host:(NSString *)host port:(uint16_t)port;

- (void)adoptProxiedClient:(int)fd host:(NSString *)host port:(uint16_t)port
                   okReply:(NSData *)okReply failReply:(NSData *)failReply
               initialData:(NSData *)initialData;

- (void)relayProxiedClientInline:(int)fd host:(NSString *)host port:(uint16_t)port
                         okReply:(NSData *)okReply failReply:(NSData *)failReply
                     initialData:(NSData *)initialData;

- (void)relayClient:(int)clientFd host:(NSString *)host port:(uint16_t)port
            okReply:(NSData *)okReply failReply:(NSData *)failReply
        initialData:(NSData *)initialData;

- (NSData *)relayDNSQuery:(NSData *)query;

- (void)sendRawIPPacket:(const uint8_t *)bytes length:(size_t)length;
- (void)sendRawIPPackets:(const AWGRawPacket *)packets count:(size_t)count;

@property (nonatomic, assign) int utunFd;

- (void)bindToInterfaceIndex:(unsigned)index;

- (void)sendTunnelPacket:(NSData *)packet;
- (void)sendTunnelPacketBytes:(const uint8_t *)bytes length:(size_t)length;
- (void)deliverData:(NSData *)data toConnection:(uint32_t)connectionID;
- (void)deliverData:(NSData *)data toFd:(int)clientFd connectionID:(uint32_t)connectionID;

@end
