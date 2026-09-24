

#import "AWGTunnel.h"
#import "AWGConfig.h"
#import "AWGHandshake.h"
#import "AWGCrypto.h"
#import "AWGIPStack.h"
#import "monocypher.h"
#import "DebugLog.h"
#import "DanteHTTPProxy.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static const size_t kWGTagLen = 16;

static const NSTimeInterval kAWGClientDrainTimeout = 180.0;

volatile uint32_t gAWGTxSent = 0, gAWGTxRetried = 0, gAWGTxDropped = 0;

static const NSUInteger kAWGSendBacklogCap = 262144;

int awg_grow_sockbuf(int fd, int opt, int want)
{
    for (int size = want; size >= 65536; size /= 2) {
        if (setsockopt(fd, SOL_SOCKET, opt, &size, sizeof(size)) == 0) {
            int got = 0; socklen_t len = sizeof(got);
            if (getsockopt(fd, SOL_SOCKET, opt, &got, &len) == 0) return got;
            return size;
        }
    }
    return 0;
}

@interface AWGTunnel () {
    AWGConfig *_config;
    AWGHandshake *_handshake;
    AWGHandshake *_previousHandshake;
    NSTimeInterval _previousHandshakeRetiredAt;
    AWGIPStack *_ipStack;
    int _udpFd;
    uint16_t _socksPort;
    int _socksListenFd;
    NSThread *_readThread;
    volatile int _utunFd;
    NSThread *_socksThread;
    BOOL _running;
    NSDate *_handshakeDate;
    uint64_t _bytesSent;
    uint64_t _bytesReceived;
    uint64_t _sendCounter;
    uint64_t _recvCounter;
    uint64_t _maxRecvCounter;
    uint64_t _recvBitmap;
    BOOL _recvCounterInit;
    dispatch_queue_t _writeQueue;
    NSMutableDictionary *_socksClients;    
    dispatch_source_t _awakeTimer;
    volatile NSTimeInterval _lastRxAt;
    volatile NSTimeInterval _lastTxAt;
}
@end

@implementation AWGTunnel

- (void)resetCounters {
    _sendCounter = 0;
    _recvCounter = 0;
    _maxRecvCounter = 0;
    _recvBitmap = 0;
    _recvCounterInit = NO;
}

- (instancetype)initWithConfig:(AWGConfig *)config {
    self = [super init];
    if (self) {
        _config = config;
        _utunFd = -1;   
        _handshake = [[AWGHandshake alloc] initWithConfig:config];
        _udpFd = -1;
        _socksListenFd = -1;
        _state = AWGTunnelStateIdle;
        _writeQueue = dispatch_queue_create("com.youtube.awg.write", DISPATCH_QUEUE_SERIAL);
        _socksClients = [NSMutableDictionary dictionary];
        [self resetCounters];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Public API

- (void)startWithCompletion:(void(^)(BOOL success, NSError *  error))completion {
    if (_state == AWGTunnelStateConnecting || _state == AWGTunnelStateConnected) {
        if (completion) completion(YES, nil);
        return;
    }
    _state = AWGTunnelStateConnecting;
    [self notifyState];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        DLog(@"[AWG] connecting to %@ (%@)", self->_config.peerEndpoint, self->_config.label);
        BOOL ok = [self setupUDPSocket:&err];
        if (!ok) DLog(@"[AWG] socket setup failed: %@", err.localizedDescription);
        if (ok) {
            
            
            ok = [self performHandshakeWithError:&err];
            if (!ok) {
                DLog(@"[AWG] handshake failed on %@: %@", self->_config.peerEndpoint,
                     err.localizedDescription);
                [self->_handshake reset];
                if (self->_config.preferredPorts.count > 1) {
                    NSString *base = [self->_config.peerEndpoint componentsSeparatedByString:@":"][0];
                    NSNumber *port = self->_config.preferredPorts[arc4random_uniform((uint32_t)self->_config.preferredPorts.count)];
                    self->_config.peerEndpoint = [NSString stringWithFormat:@"%@:%@", base, port];
                    DLog(@"[AWG] retrying on %@", self->_config.peerEndpoint);
                    if (self->_udpFd >= 0) { close(self->_udpFd); self->_udpFd = -1; }
                    if ([self setupUDPSocket:&err]) ok = [self performHandshakeWithError:&err];
                    if (!ok) DLog(@"[AWG] retry failed: %@", err.localizedDescription);
                }
            }
        }
        if (ok) {
            self->_ipStack = [[AWGIPStack alloc] initWithTunnel:self
                                                      localIPv4:self->_config.ipv4Address
                                                      localIPv6:self->_config.ipv6Address];
            
            
            for (NSString *raw in [self->_config.dnsServers componentsSeparatedByString:@","]) {
                NSString *candidate = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                struct in_addr probe;
                if (candidate.length && inet_pton(AF_INET, [candidate UTF8String], &probe) == 1) {
                    self->_ipStack.dnsServerIPv4 = candidate;
                    break;
                }
            }
            
            
            
            
            
            
            NSInteger mtuOverride = [[NSUserDefaults standardUserDefaults] integerForKey:@"dante_mtu"];
            self->_ipStack.tunnelMTU = (mtuOverride >= 576 && mtuOverride <= 1500)
                                        ? (NSUInteger)mtuOverride
                                        : 1400;
            DLog(@"[AWG] tunnel DNS server: %@, MTU %lu", self->_ipStack.dnsServerIPv4,
                 (unsigned long)self->_ipStack.tunnelMTU);
            ok = [self startSOCKS5ProxyWithError:&err];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                self->_state = AWGTunnelStateConnected;
                self->_handshakeDate = [NSDate date];
                [self notifyState];
                if (completion) completion(YES, nil);
            } else {
                self->_state = AWGTunnelStateFailed;
                [self notifyState];
                if (completion) completion(NO, err);
            }
        });
    });
}

- (void)startAwakeTimer {
    if (!_keepRadioAwake || _awakeTimer) return;
    _awakeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _writeQueue);
    dispatch_source_set_timer(_awakeTimer, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                              50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak AWGTunnel *weakSelf = self;
    dispatch_source_set_event_handler(_awakeTimer, ^{
        AWGTunnel *t = weakSelf;
        if (!t || !t->_running) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        
        if (now - t->_lastTxAt < 0.05) return;
        [t encryptAndSendLocked:[NSData data]];   
    });
    dispatch_resume(_awakeTimer);
}

- (void)stopAwakeTimer {
    if (!_awakeTimer) return;
    dispatch_source_cancel(_awakeTimer);
    dispatch_release(_awakeTimer);
    _awakeTimer = NULL;
}

- (void)stop {
    [self stopAwakeTimer];
    _running = NO;
    if (_udpFd >= 0) { close(_udpFd); _udpFd = -1; }
    if (_socksListenFd >= 0) { close(_socksListenFd); _socksListenFd = -1; }
    _state = AWGTunnelStateIdle;
    [self notifyState];
}

- (void)rotateKeys {
    [_handshake reset];
    [self resetCounters];
    [self performHandshakeWithError:NULL];
}

- (NSTimeInterval)lastDataAt {
    return _lastRxAt;
}

- (NSTimeInterval)handshakeAge {
    if (!_handshakeDate) return 0;
    return -[_handshakeDate timeIntervalSinceNow];
}

#pragma mark - UDP socket

- (BOOL)setupUDPSocket:(NSError **)error {
    NSString *endpoint = _config.peerEndpoint;
    if (!endpoint) {
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No endpoint configured"}];
        return NO;
    }

    NSString *host = nil;
    NSString *portStr = nil;
    if ([endpoint hasPrefix:@"["]) {
        NSRange closeBracket = [endpoint rangeOfString:@"]:"];
        if (closeBracket.location != NSNotFound) {
            host = [endpoint substringWithRange:NSMakeRange(1, closeBracket.location - 1)];
            portStr = [endpoint substringFromIndex:closeBracket.location + 2];
        }
    } else {
        NSRange colon = [endpoint rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location != NSNotFound) {
            host = [endpoint substringToIndex:colon.location];
            portStr = [endpoint substringFromIndex:colon.location + 1];
        }
    }
    if (!host || !portStr) {
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Bad endpoint format"}];
        return NO;
    }

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;

    int rc = getaddrinfo([host UTF8String], [portStr UTF8String], &hints, &res);
    if (rc != 0 || !res) {
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"DNS failed: %s", gai_strerror(rc)]}];
        return NO;
    }

    _udpFd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (_udpFd < 0) {
        freeaddrinfo(res);
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:4 userInfo:@{NSLocalizedDescriptionKey: @"socket() failed"}];
        return NO;
    }

    int flags = fcntl(_udpFd, F_GETFL, 0);
    fcntl(_udpFd, F_SETFL, flags | O_NONBLOCK);

    int rcvbuf = awg_grow_sockbuf(_udpFd, SO_RCVBUF, 2097152);
    int sndbuf = awg_grow_sockbuf(_udpFd, SO_SNDBUF, 2097152);
    DLog(@"[AWG] буфер сокета: приём %d, отправка %d", rcvbuf, sndbuf);

    if (connect(_udpFd, res->ai_addr, res->ai_addrlen) != 0) {
        DLog(@"[AWG] UDP connect returned %d (%s)", errno, strerror(errno));
    }
    freeaddrinfo(res);
    return YES;
}

#pragma mark - Handshake

- (BOOL)performHandshakeWithError:(NSError **)error {
    return [self performHandshake:_handshake error:error];
}

- (BOOL)performHandshake:(AWGHandshake *)handshake error:(NSError **)error {
    NSArray *datagrams = [handshake buildInitiationDatagrams];
    if (datagrams.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Failed to build initiation"}];
        return NO;
    }

    
    
    
    NSUInteger idx = 0;
    for (NSData *packet in datagrams) {
        if (send(_udpFd, packet.bytes, packet.length, 0) < 0) {
            if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:6 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"send() failed: %s", strerror(errno)]}];
            return NO;
        }
        _bytesSent += packet.length;
        idx++;
        
        if (idx < datagrams.count) usleep(2000);
    }
    DLog(@"[AWG] sent %lu handshake datagrams (%lu junk/signature + initiation)",
         (unsigned long)datagrams.count, (unsigned long)(datagrams.count - 1));

    
    
    
    uint8_t buf[4096];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(_udpFd, &fds);
        struct timeval tv = {0, 200000};
        int rc = select(_udpFd + 1, &fds, NULL, NULL, &tv);
        if (rc <= 0) continue;

        ssize_t n = recv(_udpFd, buf, sizeof(buf), 0);
        if (n <= 0) continue;
        _bytesReceived += n;

        NSData *packet = [NSData dataWithBytes:buf length:(NSUInteger)n];
        NSError *attemptError = nil;
        if ([handshake processResponse:packet error:&attemptError]) {
            if (handshake == _handshake) {
                _handshakeDate = [NSDate date];
                [self resetCounters];
                if (!_readThread) [self startReadThread];
            }
            return YES;
        }
        
        [self handleIncomingPacket:packet];
        [_ipStack flushPendingWork];
    }

    if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:7 userInfo:@{NSLocalizedDescriptionKey: @"Handshake timeout"}];
    return NO;
}

#pragma mark - Data path

- (void)startReadThread {
    _running = YES;
    _readThread = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop) object:nil];
    [_readThread start];
    [self startAwakeTimer];
}

static const NSTimeInterval kAWGRekeyAfterSeconds = 110.0;

- (BOOL)rekeyInline {
    NSError *err = nil;
    DLog(@"[AWG] session is %.0fs old — rekeying", self.handshakeAge);

    
    
    
    AWGHandshake *next = [[AWGHandshake alloc] initWithConfig:_config];
    if ([self performHandshake:next error:&err]) {
        _previousHandshake = _handshake;
        _previousHandshakeRetiredAt = [NSDate timeIntervalSinceReferenceDate];
        _handshake = next;
        _handshakeDate = [NSDate date];
        [self resetCounters];
        
        
        dispatch_sync(_writeQueue, ^{
            [self encryptAndSendLocked:[NSData data]];
        });
        DLog(@"[AWG] rekeyed (confirmed with keepalive, retaining previous session for 30s grace period)");
        return YES;
    }
    DLog(@"[AWG] rekey failed, keeping the current session: %@", err.localizedDescription);
    return NO;
}

@synthesize utunFd = _utunFd;

- (void)setUtunFd:(int)fd { _utunFd = fd; }
- (int)utunFd { return _utunFd; }

- (void)drainUtunLocked:(int)fd {
    uint8_t pkt[4096];
    for (int p = 0; p < 32; p++) {
        ssize_t n = read(fd, pkt, sizeof(pkt));
        if (n <= 0) break;
        if (n <= 4 || (pkt[4] >> 4) != 4) continue;   
        [self encryptAndSendLocked:pkt + 4 length:(size_t)n - 4];
    }
}

- (void)readLoop {
    uint8_t buf[4096];
    NSUInteger rekeyFailures = 0;
    NSTimeInterval nextRekeyAt = 0;
    while (_running && _udpFd >= 0) {
        
        
        
        
        
        
        NSTimeInterval nowTI = [NSDate timeIntervalSinceReferenceDate];
        if (_handshakeDate && self.handshakeAge >= kAWGRekeyAfterSeconds && nowTI >= nextRekeyAt) {
            if ([self rekeyInline]) {
                rekeyFailures = 0;
                nextRekeyAt = 0;
            } else {
                ++rekeyFailures;
                nextRekeyAt = nowTI + MIN(60.0, 2.0 * (1 << MIN(rekeyFailures, 5)));
                if (rekeyFailures == 3) {
                    DLog(@"[AWG] giving up on this endpoint after 3 failed rekeys");
                    self->_state = AWGTunnelStateReconnecting;
                    [self notifyState];
                }
            }
        }
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(_udpFd, &fds);
        int utun = _utunFd;
        int maxFd = _udpFd;
        if (utun >= 0) {
            FD_SET(utun, &fds);
            if (utun > maxFd) maxFd = utun;
        }
        struct timeval tv = {0, 20000};
        int rc = select(maxFd + 1, &fds, NULL, NULL, &tv);
        if (rc <= 0) continue;
        if (utun >= 0 && FD_ISSET(utun, &fds)) {
            
            
            dispatch_sync(_writeQueue, ^{ [self drainUtunLocked:utun]; });
        }
        if (!FD_ISSET(_udpFd, &fds)) continue;

        
        @autoreleasepool {
            for (;;) {
                int count = 0;
                for (int p = 0; p < 128 && _running && _udpFd >= 0; p++) {
                    ssize_t n = recv(_udpFd, buf, sizeof(buf), 0);
                    if (n <= 0) {
                        count = -1;
                        break;
                    }
                    count++;
                    _bytesReceived += n;
                    [self handleIncomingBytes:buf length:(size_t)n];
                }
                if (_ipStack.hasPendingWork) {
                    [_ipStack flushPendingWork];   
                }
                if (count < 128) {
                    break; 
                }
            }
        }
    }
}

static void awgRxStat(int reason) {
    static uint32_t stats[6];
    static NSTimeInterval last;
    @synchronized ([AWGTunnel class]) {
        stats[reason]++;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - last >= 5.0) {
            last = now;
            DLog(@"[AWG rx] ok %u, до ключей %u, не транспорт %u, старый счётчик %u, не расшифр. %u, keepalive %u",
                 stats[0], stats[1], stats[2], stats[3], stats[4], stats[5]);
            memset(stats, 0, sizeof(stats));
        }
    }
}

- (void)handleIncomingBytes:(const uint8_t *)bytes length:(size_t)length {
    if (!_handshake.isEstablished) { awgRxStat(1); return; }

    uint64_t counter = 0;
    AWGHandshake *sessionHs = _handshake;
    BOOL isPreviousSession = NO;
    NSUInteger offset = [sessionHs transportPayloadOffsetForBytes:bytes length:length counter:&counter];
    if (offset == NSNotFound && _previousHandshake) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _previousHandshakeRetiredAt < 30.0) {
            offset = [_previousHandshake transportPayloadOffsetForBytes:bytes length:length counter:&counter];
            if (offset != NSNotFound) {
                sessionHs = _previousHandshake;
                isPreviousSession = YES;
            }
        } else {
            _previousHandshake = nil;
        }
    }

    if (offset == NSNotFound) {
        awgRxStat(2);
        static NSTimeInterval lastDump;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (length >= 8 && now - lastDump > 5) {
            lastDump = now;
            DLog(@"[AWG rx] не транспорт: %lu байт, тип %u, получатель %u, наш индекс %u",
                 (unsigned long)length, (unsigned)bytes[0],
                 (unsigned)(bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | ((uint32_t)bytes[7] << 24)),
                 (unsigned)_handshake.localIndex);
        }
        return;
    }

    
    if (!isPreviousSession && _recvCounterInit) {
        if (counter > _maxRecvCounter) {
            
        } else {
            uint64_t diff = _maxRecvCounter - counter;
            if (diff >= 64) {
                awgRxStat(3); 
                return;
            }
            if (_recvBitmap & (1ULL << diff)) {
                awgRxStat(3); 
                return;
            }
        }
    }

    size_t cipherLen = length - offset;
    if (cipherLen < kWGTagLen) return;
    size_t plainLen = cipherLen - kWGTagLen;

    const uint8_t *cipher = bytes + offset;
    uint8_t plainBuf[2048];
    uint8_t *plainOut = (plainLen <= sizeof(plainBuf)) ? plainBuf : (uint8_t *)malloc(plainLen);

    uint8_t nonce[12];
    [AWGHandshake transportNonce:nonce forCounter:counter];

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, [sessionHs.receivingKey bytes], nonce);
    int rc = crypto_aead_read(&ctx, plainOut, cipher + plainLen,
                              NULL, 0, cipher, plainLen);
    crypto_wipe(&ctx, sizeof(ctx));
    if (rc != 0) {
        if (plainOut != plainBuf) free(plainOut);
        awgRxStat(4);
        return;
    }

    
    if (!isPreviousSession) {
        if (!_recvCounterInit) {
            _recvCounterInit = YES;
            _maxRecvCounter = counter;
            _recvBitmap = 1ULL;
        } else if (counter > _maxRecvCounter) {
            uint64_t shift = counter - _maxRecvCounter;
            if (shift < 64) {
                _recvBitmap = (_recvBitmap << shift) | 1ULL;
            } else {
                _recvBitmap = 1ULL;
            }
            _maxRecvCounter = counter;
        } else {
            uint64_t diff = _maxRecvCounter - counter;
            _recvBitmap |= (1ULL << diff);
        }
    }

    if (plainLen == 0) {
        if (plainOut != plainBuf) free(plainOut);
        awgRxStat(5); 
        return;
    }
    awgRxStat(0);
    _lastRxAt = [NSDate timeIntervalSinceReferenceDate];

    
    AWGRawPacketHandler raw = self.rawPacketHandler;
    if (raw && ![_ipStack claimsIncomingPacket:plainOut length:plainLen]) {
        raw(plainOut, plainLen);
        if (plainOut != plainBuf) free(plainOut);
        return;
    }

    [_ipStack handleIPPacketBytes:plainOut length:plainLen];
    if (plainOut != plainBuf) free(plainOut);
}

- (void)handleIncomingPacket:(NSData *)packet {
    [self handleIncomingBytes:packet.bytes length:packet.length];
}

- (void)sendTunnelPacketBytes:(const uint8_t *)bytes length:(size_t)length {
    if (_state != AWGTunnelStateConnected || !_handshake.isEstablished) return;
    dispatch_sync(_writeQueue, ^{ [self encryptAndSendLocked:bytes length:length]; });
}

- (void)sendTunnelPacket:(NSData *)packet {
    [self sendTunnelPacketBytes:packet.bytes length:packet.length];
}

- (void)sendRawIPPacket:(const uint8_t *)bytes length:(size_t)length {
    if (_state != AWGTunnelStateConnected || !_handshake.isEstablished) return;
    dispatch_sync(_writeQueue, ^{ [self encryptAndSendLocked:bytes length:length]; });
}

- (void)sendRawIPPackets:(const AWGRawPacket *)packets count:(size_t)count {
    if (count == 0) return;
    if (_state != AWGTunnelStateConnected || !_handshake.isEstablished) return;
    dispatch_sync(_writeQueue, ^{
        for (size_t i = 0; i < count; i++) {
            [self encryptAndSendLocked:packets[i].bytes length:packets[i].length];
        }
    });
}

- (void)bindToInterfaceIndex:(unsigned)index {
    dispatch_sync(_writeQueue, ^{
        if (self->_udpFd < 0 || index == 0) return;
        int idx = (int)index;
        
        
        if (setsockopt(self->_udpFd, IPPROTO_IP, 25, &idx, sizeof(idx)) != 0) {
            DLog(@"[AWG] IP_BOUND_IF %u: %s", index, strerror(errno));
        }
    });
}

- (void)encryptAndSendLocked:(NSData *)packet {
    [self encryptAndSendLocked:packet.bytes length:packet.length];
}

- (void)encryptAndSendLocked:(const void *)packetBytes length:(size_t)packetLen {
    if (_state != AWGTunnelStateConnected || !_handshake.isEstablished || _udpFd < 0) return;
    uint64_t c = _sendCounter;
    uint8_t outBuf[2048];
    if (16 + packetLen + kWGTagLen > sizeof(outBuf)) return;

    
    size_t hdrLen = [_handshake writeTransportHeader:outBuf counter:c];

    
    uint8_t nonce[12];
    [AWGHandshake transportNonce:nonce forCounter:c];

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, [_handshake.sendingKey bytes], nonce);
    crypto_aead_write(&ctx, outBuf + hdrLen, outBuf + hdrLen + packetLen,
                      NULL, 0, packetBytes, packetLen);
    crypto_wipe(&ctx, sizeof(ctx));

    size_t totalLen = hdrLen + packetLen + kWGTagLen;
    ssize_t sent = send(_udpFd, outBuf, totalLen, 0);
    if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
        gAWGTxRetried++;
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(_udpFd, &wfds);
        struct timeval tv = {0, 15000}; 
        if (select(_udpFd + 1, NULL, &wfds, NULL, &tv) > 0) {
            sent = send(_udpFd, outBuf, totalLen, 0);
        }
    }
    if (sent > 0) gAWGTxSent++; else gAWGTxDropped++;
    _sendCounter++;
    if (sent > 0) {
        _bytesSent += (NSUInteger)sent;
        _lastTxAt = [NSDate timeIntervalSinceReferenceDate];
    }
}

#pragma mark - SOCKS5 local proxy

- (BOOL)startSOCKS5ProxyWithError:(NSError **)error {
    _socksListenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_socksListenFd < 0) {
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:9 userInfo:@{NSLocalizedDescriptionKey: @"SOCKS socket() failed"}];
        return NO;
    }

    int reuse = 1;
    setsockopt(_socksListenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(_preferredSOCKSPort);
    if (_preferredSOCKSPort && bind(_socksListenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        DLog(@"[AWG] SOCKS-порт %u занят (%s), беру любой свободный",
             _preferredSOCKSPort, strerror(errno));
        addr.sin_port = 0;
    } else if (_preferredSOCKSPort) {
        goto bound;
    }
    if (bind(_socksListenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(_socksListenFd);
        _socksListenFd = -1;
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:10 userInfo:@{NSLocalizedDescriptionKey: @"SOCKS bind() failed"}];
        return NO;
    }
bound:;
    socklen_t alen = sizeof(addr);
    if (getsockname(_socksListenFd, (struct sockaddr *)&addr, &alen) == 0) {
        _socksPort = ntohs(addr.sin_port);
    }
    if (listen(_socksListenFd, 128) != 0) {
        close(_socksListenFd);
        _socksListenFd = -1;
        if (error) *error = [NSError errorWithDomain:@"AWGTunnel" code:11 userInfo:@{NSLocalizedDescriptionKey: @"SOCKS listen() failed"}];
        return NO;
    }

    DLog(@"[AWG] SOCKS5 proxy listening on 127.0.0.1:%u", _socksPort);
    _socksThread = [[NSThread alloc] initWithTarget:self selector:@selector(socksAcceptLoop) object:nil];
    [_socksThread start];
    return YES;
}

- (void)socksAcceptLoop {
    @autoreleasepool {
        while (_running && _socksListenFd >= 0) {
            struct sockaddr_in clientAddr;
            socklen_t clen = sizeof(clientAddr);
            int client = accept(_socksListenFd, (struct sockaddr *)&clientAddr, &clen);
            if (client < 0) continue;
            int one = 1;
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            int bufSize = 256 * 1024;
            setsockopt(client, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
            setsockopt(client, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));

            
            
            
            
            NSThread *t = [[NSThread alloc] initWithTarget:self
                                                  selector:@selector(socksClientThread:)
                                                    object:@(client)];
            t.stackSize = 256 * 1024;
            [t start];
        }
    }
}

- (void)socksClientThread:(NSNumber *)fd {
    @autoreleasepool {
        [self handleSOCKSClient:[fd intValue]];
    }
}

- (void)handleSOCKSClient:(int)clientFd {
    uint8_t buf[512];
    ssize_t n = read(clientFd, buf, sizeof(buf));
    if (n <= 0) {
        close(clientFd);
        return;
    }
    if (buf[0] != 0x05) {
        NSData *initial = [NSData dataWithBytes:buf length:(NSUInteger)n];
        [[DanteHTTPProxy sharedProxy] processClientInline:clientFd initialData:initial];
        return;
    }
    if (n < 3) {
        close(clientFd);
        return;
    }
    uint8_t nmethods = buf[1];
    BOOL noAuth = NO;
    for (int i = 0; i < nmethods; i++) {
        if (buf[2 + i] == 0x00) { noAuth = YES; break; }
    }
    uint8_t reply[2] = {0x05, noAuth ? 0x00 : 0xFF};
    write(clientFd, reply, 2);
    if (!noAuth) { close(clientFd); return; }

    n = read(clientFd, buf, sizeof(buf));
    if (n < 7 || buf[0] != 0x05 || buf[1] != 0x01) {
        close(clientFd);
        return;
    }
    uint8_t atyp = buf[3];
    NSString *host = nil;
    uint16_t port = 0;
    if (atyp == 0x01) {
        if (n < 10) { close(clientFd); return; }
        host = [NSString stringWithFormat:@"%u.%u.%u.%u", buf[4], buf[5], buf[6], buf[7]];
        port = (buf[8] << 8) | buf[9];
    } else if (atyp == 0x03) {
        uint8_t len = buf[4];
        if (n < 5 + len + 2) { close(clientFd); return; }
        host = [[NSString alloc] initWithBytes:buf + 5 length:len encoding:NSUTF8StringEncoding];
        port = (buf[5 + len] << 8) | buf[6 + len];
    } else if (atyp == 0x04) {
        close(clientFd);
        return;
    }
    if (!host || port == 0) {
        close(clientFd);
        return;
    }

    uint8_t ok[10] = {0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0};
    uint8_t fail[10] = {0x05, 0x04, 0x00, 0x01, 0,0,0,0, 0,0};
    [self relayClient:clientFd host:host port:port
              okReply:[NSData dataWithBytes:ok length:sizeof(ok)]
            failReply:[NSData dataWithBytes:fail length:sizeof(fail)]
          initialData:nil];
}

#pragma mark - Прозрачные клиенты (системный режим без SOCKS)

- (void)adoptTransparentClient:(int)fd host:(NSString *)host port:(uint16_t)port {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int bufSize = 1048576;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));

    NSThread *t = [[NSThread alloc] initWithTarget:self
                                          selector:@selector(transparentClientThread:)
                                            object:@[@(fd), host, @(port)]];
    t.stackSize = 256 * 1024;
    [t start];
}

- (void)transparentClientThread:(NSArray *)args {
    @autoreleasepool {
        [self relayClient:[[args objectAtIndex:0] intValue]
                     host:[args objectAtIndex:1]
                     port:(uint16_t)[[args objectAtIndex:2] unsignedShortValue]
                  okReply:nil failReply:nil initialData:nil];
    }
}

- (void)adoptProxiedClient:(int)fd host:(NSString *)host port:(uint16_t)port
                   okReply:(NSData *)okReply failReply:(NSData *)failReply
               initialData:(NSData *)initialData {
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@(fd), host, @(port),
                            okReply ?: [NSNull null], failReply ?: [NSNull null],
                            initialData ?: [NSNull null], nil];
    NSThread *t = [[NSThread alloc] initWithTarget:self
                                          selector:@selector(proxiedClientThread:)
                                            object:args];
    t.stackSize = 256 * 1024;
    [t start];
}

- (void)proxiedClientThread:(NSArray *)args {
    @autoreleasepool {
        id ok = [args objectAtIndex:3], fail = [args objectAtIndex:4], initial = [args objectAtIndex:5];
        [self relayClient:[[args objectAtIndex:0] intValue]
                     host:[args objectAtIndex:1]
                     port:(uint16_t)[[args objectAtIndex:2] unsignedShortValue]
                  okReply:(ok == [NSNull null] ? nil : ok)
                failReply:(fail == [NSNull null] ? nil : fail)
              initialData:(initial == [NSNull null] ? nil : initial)];
    }
}

- (void)relayProxiedClientInline:(int)fd host:(NSString *)host port:(uint16_t)port
                         okReply:(NSData *)okReply failReply:(NSData *)failReply
                     initialData:(NSData *)initialData {
    [self relayClient:fd host:host port:port okReply:okReply failReply:failReply initialData:initialData];
}

- (NSData *)relayDNSQuery:(NSData *)query {
    if (!_ipStack || !_running) return nil;
    NSData *answer = [_ipStack relayDNSQuery:query timeout:2.5];
    if (!answer) answer = [_ipStack relayDNSQuery:query timeout:2.5];
    return answer;
}

- (void)relayClient:(int)clientFd host:(NSString *)host port:(uint16_t)port
            okReply:(NSData *)okReply failReply:(NSData *)failReply initialData:(NSData *)initialData {
    BOOL socks = (okReply.length == 10);
    
    
    if (port == 53) {
        if (okReply) write(clientFd, okReply.bytes, okReply.length);
        [self serveDNSOverTCPForClient:clientFd socks:NO];
        close(clientFd);
        return;
    }

    uint32_t connID = [_ipStack openTCPToHost:host port:port];
    if (connID == 0) {
        if (failReply) write(clientFd, failReply.bytes, failReply.length);
        close(clientFd);
        return;
    }

    @synchronized(_socksClients) {
        _socksClients[@(connID)] = @(clientFd);
    }
    [_ipStack setClientFd:clientFd forConnectionID:connID];

    
    if (![_ipStack waitForConnection:connID timeout:12.0]) {
        DLog(@"[AWG] %@: %@:%u did not come up", socks ? @"SOCKS5" : (okReply || failReply ? @"proxy" : @"redirect"), host, port);
        [_ipStack closeTCPConnection:connID];
        @synchronized(_socksClients) {
            [_socksClients removeObjectForKey:@(connID)];
        }
        if (failReply) send(clientFd, failReply.bytes, failReply.length, 0);
        close(clientFd);
        return;
    }

    if (okReply) {
        ssize_t w = write(clientFd, okReply.bytes, okReply.length);
        DLogVerbose(@"[AWG relay] conn %u clientFd %d: sent okReply %lu bytes (rc=%ld, errno=%d)",
             connID, clientFd, (unsigned long)okReply.length, (long)w, errno);
    }
    if (initialData.length) [_ipStack sendTCPData:initialData connectionID:connID];

    uint8_t buf[16384];
    int sinceCheck = 8;   
    while (_running) {
        
        
        
        
        
        
        if (++sinceCheck >= 8) {
            sinceCheck = 0;
            int waited = 0;
            while (_running && [_ipStack sendBacklogForConnection:connID] > kAWGSendBacklogCap
                   && waited < 60000) {
                usleep(2000);
                waited += 2;
            }
        }
        ssize_t n = read(clientFd, buf, sizeof(buf));
        if (n <= 0) {
            DLogVerbose(@"[AWG relay] conn %u clientFd %d: client closed / read %ld (errno=%d)",
                 connID, clientFd, (long)n, errno);
            break;
        }
        NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
        [_ipStack sendTCPData:data connectionID:connID];
    }
    [_ipStack closeTCPConnectionAndDrain:connID];
    @synchronized(_socksClients) {
        [_socksClients removeObjectForKey:@(connID)];
    }
    close(clientFd);
}

static BOOL awgReadFull(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n > 0) { got += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return NO;
    }
    return YES;
}

static BOOL awgWriteFull(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return NO;
    }
    return YES;
}

- (void)serveDNSOverTCPForClient:(int)clientFd socks:(BOOL)socks {
    uint8_t okReply[10] = {0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0};
    if (socks && !awgWriteFull(clientFd, okReply, sizeof(okReply))) return;

    
    
    uint8_t lenBuf[2];
    uint8_t query[65535];
    while (_running && awgReadFull(clientFd, lenBuf, 2)) {
        size_t qlen = ((size_t)lenBuf[0] << 8) | lenBuf[1];
        if (qlen < 12 || !awgReadFull(clientFd, query, qlen)) break;
        NSData *q = [NSData dataWithBytes:query length:qlen];
        NSData *answer = [self relayDNSQuery:q];
        if (!answer) {
            DLog(@"[AWG] DNS/TCP: нет ответа от резолвера через туннель");
            break;
        }
        uint8_t alen[2] = { (uint8_t)(answer.length >> 8), (uint8_t)answer.length };
        if (!awgWriteFull(clientFd, alen, 2) ||
            !awgWriteFull(clientFd, answer.bytes, answer.length)) break;
    }
}

- (void)deliverData:(NSData *)data toFd:(int)clientFd connectionID:(uint32_t)connectionID {
    int fd = clientFd;
    if (fd <= 0) {
        NSNumber *fdNum = nil;
        @synchronized(_socksClients) {
            fdNum = _socksClients[@(connectionID)];
        }
        if (!fdNum) {
            DLog(@"[AWG] deliverData: conn %u без SOCKS-клиента (%lu байт потеряно)",
                 connectionID, (unsigned long)data.length);
            return;
        }
        fd = [fdNum intValue];
    }
    if (data.length == 0) {
        
        
        shutdown(fd, SHUT_RDWR);
        return;
    }

    const uint8_t *bytes = data.bytes;
    size_t total = data.length;
    size_t sent = 0;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + kAWGClientDrainTimeout;

    
    
    
    while (sent < total) {
        ssize_t written = write(fd, bytes + sent, total - sent);
        if (written > 0) { sent += (size_t)written; continue; }
        if (written < 0 && (errno == EINTR)) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if ([NSDate timeIntervalSinceReferenceDate] >= deadline) {
                
                
                
                
                
                
                DLog(@"[AWG] клиент %u не читает %.0f с — закрываю соединение",
                     connectionID, kAWGClientDrainTimeout);
                
                
                
                shutdown(fd, SHUT_RDWR);
                return;
            }
            
            
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(fd, &wfds);
            struct timeval tv = {0, 10000};
            select(fd + 1, NULL, &wfds, NULL, &tv);
            continue;
        }
        DLog(@"[AWG] write to client %u (fd %d) failed: %s", connectionID, fd, strerror(errno));
        break;
    }
}

- (void)deliverData:(NSData *)data toConnection:(uint32_t)connectionID {
    [self deliverData:data toFd:0 connectionID:connectionID];
}

#pragma mark - State notification

- (void)notifyState {
    if ([_delegate respondsToSelector:@selector(tunnelDidChangeState:)]) {
        [_delegate tunnelDidChangeState:_state];
    }
}

- (NSString *)resolveHostThroughTunnel:(NSString *)host {
    if (!_ipStack || host.length == 0) return nil;
    uint32_t ip = [_ipStack resolveIPv4:host];
    if (ip == 0) return nil;
    return [NSString stringWithFormat:@"%u.%u.%u.%u",
            ip & 0xff, (ip >> 8) & 0xff, (ip >> 16) & 0xff, (ip >> 24) & 0xff];
}

@end
