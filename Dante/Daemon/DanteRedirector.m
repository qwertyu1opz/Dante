

#import "DanteRedirector.h"
#import "DanteUtun.h"
#import "AmneziaWGManager.h"
#import "PowerSession.h"
#import "DebugLog.h"
#import "DanteTunNAT.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

const uint16_t kDanteRedirectPort = 10809;
const uint16_t kDanteDNSPort = 10853;
const uint16_t kDanteTunTCPPort = 10807;

static NSString * const kPFConfPath = @"/var/run/dante-pf.conf";
static NSString * const kPFMarkerPath = @"/var/run/dante-pf.active";

#pragma mark - DIOCNATLOOK

struct dante_pf_addr {
    union {
        struct in_addr v4;
        struct in6_addr v6;
        uint8_t addr8[16];
        uint16_t addr16[8];
        uint32_t addr32[4];
    } pfa;
};

union dante_pf_state_xport {
    uint16_t port;
    uint16_t call_id;
    uint32_t spi;
};

struct dante_pfioc_natlook {
    struct dante_pf_addr saddr;
    struct dante_pf_addr daddr;
    struct dante_pf_addr rsaddr;
    struct dante_pf_addr rdaddr;
    union dante_pf_state_xport sxport;
    union dante_pf_state_xport dxport;
    union dante_pf_state_xport rsxport;
    union dante_pf_state_xport rdxport;
    sa_family_t af;
    uint8_t proto;
    uint8_t proto_variant;
    uint8_t direction;
};

typedef char dante_natlook_size_check[(sizeof(struct dante_pfioc_natlook) == 84) ? 1 : -1];

#define DANTE_DIOCNATLOOK _IOWR('D', 23, struct dante_pfioc_natlook)
#define DANTE_PF_OUT 2

@interface DanteDNSCacheEntry : NSObject
@property (nonatomic, strong) NSData *answer;
@property (nonatomic, assign) NSTimeInterval expiresAt;
@end
@implementation DanteDNSCacheEntry
@end

@interface DanteDNSWaiter : NSObject
@property (nonatomic, strong) NSData *peer;
@property (nonatomic, assign) int fd;          
@property (nonatomic, assign) uint16_t txid;
@end
@implementation DanteDNSWaiter
@end

static uint32_t DanteParseDNSTTL(const uint8_t *bytes, size_t len) {
    if (len < 12) return 60;
    uint16_t qdcount = ntohs(*(const uint16_t *)(bytes + 4));
    uint16_t ancount = ntohs(*(const uint16_t *)(bytes + 6));
    if (ancount == 0) return 15; 

    size_t offset = 12;
    
    for (uint16_t i = 0; i < qdcount; i++) {
        while (offset < len) {
            uint8_t l = bytes[offset++];
            if (l == 0) break;
            if ((l & 0xc0) == 0xc0) {
                offset++; 
                break;
            }
            offset += l;
        }
        offset += 4; 
        if (offset > len) return 60;
    }

    
    if (offset >= len) return 60;
    
    while (offset < len) {
        uint8_t l = bytes[offset++];
        if (l == 0) break;
        if ((l & 0xc0) == 0xc0) {
            offset++;
            break;
        }
        offset += l;
    }
    offset += 4; 
    if (offset + 4 <= len) {
        uint32_t ttl = ntohl(*(const uint32_t *)(bytes + offset));
        if (ttl < 15) return 15;
        if (ttl > 300) return 300; 
        return ttl;
    }
    return 60;
}

@implementation DanteRedirector {
    int _pfFd;
    int _tcpFd;
    int _dnsFd;
    BOOL _enabled;
    NSMutableDictionary *_dnsCache;      
    NSMutableDictionary *_dnsInFlight;   
    NSLock *_dnsLock;
    dispatch_queue_t _dnsQueue;
    PowerConfig *_powerConfig;           
    int _tunTCPFd, _tunDNSFd;            
    struct in_addr _tunAddr, _tunFake;
    NSTimeInterval _lastClientAt;        
}

@synthesize powerConfig = _powerConfig;
@synthesize lastClientAt = _lastClientAt;

+ (instancetype)sharedRedirector {
    static DanteRedirector *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[DanteRedirector alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pfFd = -1;
        _tcpFd = -1;
        _dnsFd = -1;
        _tunTCPFd = _tunDNSFd = -1;
        _dnsCache = [NSMutableDictionary dictionary];
        _dnsInFlight = [NSMutableDictionary dictionary];
        _dnsLock = [[NSLock alloc] init];
        _dnsQueue = dispatch_queue_create("org.dante.redirector.dns", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (BOOL)enabled {
    @synchronized (self) { return _enabled; }
}

#pragma mark - pfctl

static int DanteRunPfctl(NSArray *args, NSString **output) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);

    NSUInteger argc = args.count + 1;
    char **argv = calloc(argc + 1, sizeof(char *));
    argv[0] = "/sbin/pfctl";
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = (char *)[[args objectAtIndex:i] UTF8String];
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/sbin/pfctl", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(pipefd[1]);

    NSMutableData *out = [NSMutableData data];
    char buf[512];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) [out appendBytes:buf length:(NSUInteger)n];
    close(pipefd[0]);
    if (rc != 0) return -1;

    int status = 0;
    waitpid(pid, &status, 0);
    if (output) {
        NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
        *output = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

- (NSString *)rulesWithBypassIPs:(NSArray *)bypassIPs {
    NSMutableArray *bypass = [@[@"127.0.0.0/8", @"10.0.0.0/8", @"100.64.0.0/10", @"169.254.0.0/16",
                                @"172.16.0.0/12", @"192.168.0.0/16", @"224.0.0.0/4",
                                @"255.255.255.255/32"] mutableCopy];
    for (NSString *ip in bypassIPs) {
        struct in_addr a;
        if (ip.length && inet_pton(AF_INET, [ip UTF8String], &a) == 1) [bypass addObject:ip];
    }
    NSString *table = [bypass componentsJoinedByString:@", "];
    
    
    char ifname[IFNAMSIZ] = {0};
    BOOL cellular = NO;
    NSString *uplink = DNPrimaryUplink(ifname, sizeof(ifname), NULL, NULL, &cellular)
                     ? [NSString stringWithUTF8String:ifname] : @"en0";
    DLog(@"[redirect] канал наружу: %@%@", uplink, cellular ? @" (сотовая связь)" : @"");
    
    
    
    return [NSString stringWithFormat:
        @"set timeout { tcp.closing 10, tcp.finwait 10, tcp.closed 5 }\n"
        @"set limit states 10000\n"
        @"table <dante_bypass> persist { %@ }\n"
        @"nat on %@ inet proto tcp from any to ! <dante_bypass> -> 127.0.0.1\n"
        @"rdr pass on lo0 inet proto tcp from any to ! <dante_bypass> -> 127.0.0.1 port %u\n"
        @"rdr pass on lo0 inet proto udp from any to any port 53 -> 127.0.0.1 port %u\n"
        @"pass out quick on %@ inet proto tcp from any to <dante_bypass> flags S/SA keep state\n"
        @"pass out quick on %@ route-to (lo0 127.0.0.1) inet proto tcp from any to ! <dante_bypass> flags S/SA keep state\n"
        @"pass out quick on %@ route-to (lo0 127.0.0.1) inet proto udp from any to any port 53 keep state\n"
        @"block return out quick on %@ inet proto udp from any to ! <dante_bypass> port 443\n"
        @"block return out quick on %@ inet6 all\n"
        @"pass out on %@ all keep state\n"
        @"pass in all keep state\n",
        table, uplink, kDanteRedirectPort, kDanteDNSPort,
        uplink, uplink, uplink, uplink, uplink, uplink];
}

- (BOOL)enableWithBypassIPs:(NSArray *)bypassIPs error:(NSString **)error {
    NSString *rules = [self rulesWithBypassIPs:bypassIPs];
    if (![rules writeToFile:kPFConfPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (error) *error = @"не записать правила pf (служба не от root?)";
        return NO;
    }
    
    [[NSFileManager defaultManager] createFileAtPath:kPFMarkerPath contents:nil attributes:nil];

    NSString *out = nil;
    DanteRunPfctl(@[@"-e"], &out);   
    int rc = DanteRunPfctl(@[@"-f", kPFConfPath], &out);
    if (rc != 0) {
        DLog(@"[redirect] pfctl -f: %d %@", rc, out);
        [self disableLocked];
        if (error) *error = [NSString stringWithFormat:@"pf не принял правила: %@", out];
        return NO;
    }
    
    DanteRunPfctl(@[@"-F", @"states"], &out);
    @synchronized (self) { _enabled = YES; }
    DLog(@"[redirect] pf включён: TCP -> :%u, DNS -> :%u", kDanteRedirectPort, kDanteDNSPort);
    return YES;
}

- (void)disable {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kPFMarkerPath]) {
        @synchronized (self) { _enabled = NO; }
        return;
    }
    [self disableLocked];
    DLog(@"[redirect] pf выключен");
}

- (void)disableLocked {
    NSString *out = nil;
    DanteRunPfctl(@[@"-F", @"all"], &out);
    DanteRunPfctl(@[@"-d"], &out);
    [[NSFileManager defaultManager] removeItemAtPath:kPFMarkerPath error:nil];
    @synchronized (self) { _enabled = NO; }
}

#pragma mark - Приёмники

static int DanteBindLoopback(int type, uint16_t port) {
    int fd = socket(AF_INET, type, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        (type == SOCK_STREAM && listen(fd, 128) != 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)startListenersWithError:(NSString **)error {
    if (_tcpFd >= 0) return YES;
    _pfFd = open("/dev/pf", O_RDWR);
    if (_pfFd < 0) {
        if (error) *error = [NSString stringWithFormat:@"/dev/pf: %s", strerror(errno)];
        return NO;
    }
    _tcpFd = DanteBindLoopback(SOCK_STREAM, kDanteRedirectPort);
    _dnsFd = DanteBindLoopback(SOCK_DGRAM, kDanteDNSPort);
    if (_tcpFd < 0 || _dnsFd < 0) {
        if (error) *error = [NSString stringWithFormat:@"порты %u/%u заняты", kDanteRedirectPort, kDanteDNSPort];
        return NO;
    }
    [NSThread detachNewThreadSelector:@selector(tcpAcceptLoop) toTarget:self withObject:nil];
    [NSThread detachNewThreadSelector:@selector(dnsLoop:) toTarget:self withObject:@(_dnsFd)];
    DLog(@"[redirect] приёмники: TCP 127.0.0.1:%u, DNS 127.0.0.1:%u", kDanteRedirectPort, kDanteDNSPort);
    return YES;
}

- (BOOL)originalDestinationForFd:(int)fd ip:(NSString **)ip port:(uint16_t *)port {
    struct sockaddr_in peer, local;
    socklen_t plen = sizeof(peer), llen = sizeof(local);
    if (getpeername(fd, (struct sockaddr *)&peer, &plen) != 0 ||
        getsockname(fd, (struct sockaddr *)&local, &llen) != 0) return NO;

    struct dante_pfioc_natlook nl;
    memset(&nl, 0, sizeof(nl));
    nl.saddr.pfa.v4 = peer.sin_addr;
    nl.sxport.port = peer.sin_port;
    nl.daddr.pfa.v4 = local.sin_addr;
    nl.dxport.port = local.sin_port;
    nl.af = AF_INET;
    nl.proto = IPPROTO_TCP;
    nl.direction = DANTE_PF_OUT;
    if (ioctl(_pfFd, DANTE_DIOCNATLOOK, &nl) != 0) {
        DLogVerbose(@"[redirect] DIOCNATLOOK: %s", strerror(errno));
        return NO;
    }
    char buf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &nl.rdaddr.pfa.v4, buf, sizeof(buf));
    {
        char a[INET_ADDRSTRLEN], b[INET_ADDRSTRLEN], c[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &nl.rsaddr.pfa.v4, a, sizeof(a));
        inet_ntop(AF_INET, &nl.saddr.pfa.v4, b, sizeof(b));
        inet_ntop(AF_INET, &nl.daddr.pfa.v4, c, sizeof(c));
        DLogVerbose(@"[redirect] natlook %s:%u -> %s:%u => rs %s:%u rd %s:%u", b, ntohs(nl.sxport.port),
                    c, ntohs(nl.dxport.port), a, ntohs(nl.rsxport.port), buf, ntohs(nl.rdxport.port));
    }
    *ip = [NSString stringWithUTF8String:buf];
    *port = ntohs(nl.rdxport.port);
    return YES;
}

- (void)tcpAcceptLoop {
    for (;;) {
        @autoreleasepool {
            int fd = accept(_tcpFd, NULL, NULL);
            if (fd < 0) continue;
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            int bufSize = 1048576; 
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));

            NSString *ip = nil;
            uint16_t port = 0;
            if (![self originalDestinationForFd:fd ip:&ip port:&port] ||
                [ip isEqualToString:@"127.0.0.1"]) {
                DLogVerbose(@"[redirect] не узнать адрес назначения (%@:%u)", ip ?: @"?", port);
                close(fd);
                continue;
            }
            PowerConfig *pc = self.powerConfig;
            if (pc) {
                
                self.lastClientAt = [NSDate timeIntervalSinceReferenceDate];
                NSDictionary *job = [NSDictionary dictionaryWithObjectsAndKeys:
                                     [NSNumber numberWithInt:fd], @"fd",
                                     ip, @"ip",
                                     [NSNumber numberWithUnsignedInt:port], @"port",
                                     pc, @"config", nil];
                [NSThread detachNewThreadSelector:@selector(powerRelayJob:)
                                         toTarget:self withObject:job];
            } else if (![[AmneziaWGManager sharedManager] adoptTransparentClient:fd host:ip port:port]) {
                DLogVerbose(@"[redirect] %@:%u — туннеля нет", ip, port);
                close(fd);   
            }
        }
    }
}

#pragma mark - Отражение из utun

static int DanteBindAddress(int type, struct in_addr addr, uint16_t port) {
    int fd = socket(AF_INET, type, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr = addr;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0 ||
        (type == SOCK_STREAM && listen(fd, 256) != 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)startTunListenersOn:(struct in_addr)addr fake:(struct in_addr)fake error:(NSString **)error {
    
    
    
    
    
    @synchronized (self) {
        if (_tunTCPFd >= 0) {
            if (addr.s_addr == _tunAddr.s_addr) { _tunFake = fake; return YES; }
            if (error) *error = @"приёмники отражения уже заняты другим адресом";
            return NO;
        }
    }
    int tcp = DanteBindAddress(SOCK_STREAM, addr, kDanteTunTCPPort);
    int dns = DanteBindAddress(SOCK_DGRAM, addr, kDanteDNSPort);
    if (tcp < 0 || dns < 0) {
        if (error) *error = [NSString stringWithFormat:@"приёмник на %s: %s", inet_ntoa(addr), strerror(errno)];
        if (tcp >= 0) close(tcp);
        if (dns >= 0) close(dns);
        return NO;
    }
    @synchronized (self) {
        _tunTCPFd = tcp;
        _tunDNSFd = dns;
        _tunAddr = addr;
        _tunFake = fake;
    }
    [NSThread detachNewThreadSelector:@selector(tunAcceptLoop:) toTarget:self withObject:@(tcp)];
    [NSThread detachNewThreadSelector:@selector(dnsLoop:) toTarget:self withObject:@(dns)];
    DLog(@"[redirect] отражение: TCP %s:%u, DNS :%u", inet_ntoa(addr), kDanteTunTCPPort, kDanteDNSPort);
    return YES;
}

- (void)tunAcceptLoop:(NSNumber *)fdNumber {
    int listenFd = fdNumber.intValue;
    for (;;) {
        @autoreleasepool {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int fd = accept(listenFd, (struct sockaddr *)&peer, &plen);
            if (fd < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                usleep(100000);                          
                continue;
            }
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

            struct in_addr dst;
            uint16_t dport = 0;
            PowerConfig *pc = self.powerConfig;
            if (peer.sin_addr.s_addr != _tunFake.s_addr ||
                !DNNatLookupTCP(ntohs(peer.sin_port), &dst, &dport) || !pc) {
                DLogVerbose(@"[redirect] отражение: чужой клиент или Power выключен");
                close(fd);
                continue;
            }
            self.lastClientAt = [NSDate timeIntervalSinceReferenceDate];
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &dst, ip, sizeof(ip));
            NSDictionary *job = [NSDictionary dictionaryWithObjectsAndKeys:
                                 [NSNumber numberWithInt:fd], @"fd",
                                 [NSString stringWithUTF8String:ip], @"ip",
                                 [NSNumber numberWithUnsignedInt:dport], @"port",
                                 pc, @"config", nil];
            NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(powerRelayJob:) object:job];
            t.stackSize = 128 * 1024;
            [t start];
        }
    }
}

- (void)powerRelayJob:(NSDictionary *)job {
    @autoreleasepool {
        int fd = [[job objectForKey:@"fd"] intValue];
        [[[PowerSession alloc] initWithConfig:[job objectForKey:@"config"]]
         relayClient:fd host:[job objectForKey:@"ip"]
         port:(uint16_t)[[job objectForKey:@"port"] unsignedIntValue]];
        
    }
}

- (void)dnsLoop:(NSNumber *)fdNumber {
    int dnsFd = fdNumber.intValue;
    uint8_t buf[1500];
    for (;;) {
        @autoreleasepool {
            struct sockaddr_in from;
            socklen_t flen = sizeof(from);
            ssize_t n = recvfrom(dnsFd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &flen);
            if (n < 12) continue;

            uint16_t clientTxid = *(const uint16_t *)buf;
            NSData *key = [NSData dataWithBytes:(buf + 2) length:(NSUInteger)(n - 2)];
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

            
            NSData *cachedAnswer = nil;
            [_dnsLock lock];
            DanteDNSCacheEntry *entry = _dnsCache[key];
            if (entry) {
                if (now < entry.expiresAt) {
                    cachedAnswer = entry.answer;
                } else {
                    [_dnsCache removeObjectForKey:key];
                }
            }

            if (cachedAnswer) {
                [_dnsLock unlock];
                NSMutableData *reply = [cachedAnswer mutableCopy];
                if (reply.length >= 2) {
                    [reply replaceBytesInRange:NSMakeRange(0, 2) withBytes:&clientTxid];
                    sendto(dnsFd, reply.bytes, reply.length, 0,
                           (const struct sockaddr *)&from, flen);
                }
                continue;
            }

            
            NSData *peer = [NSData dataWithBytes:&from length:flen];
            DanteDNSWaiter *waiter = [[DanteDNSWaiter alloc] init];
            waiter.peer = peer;
            waiter.txid = clientTxid;
            waiter.fd = dnsFd;

            NSMutableArray *waiters = _dnsInFlight[key];
            if (waiters) {
                [waiters addObject:waiter];
                [_dnsLock unlock];
                continue;
            }

            waiters = [NSMutableArray arrayWithObject:waiter];
            _dnsInFlight[key] = waiters;
            [_dnsLock unlock];

            NSData *query = [NSData dataWithBytes:buf length:(NSUInteger)n];
            dispatch_async(_dnsQueue, ^{
                @autoreleasepool {
                    [self resolveAndAnswerDNS:query key:key];
                }
            });
        }
    }
}

- (void)resolveAndAnswerDNS:(NSData *)query key:(NSData *)key {
    NSData *answer = nil;
    PowerConfig *pc = self.powerConfig;
    if (pc) {
        
        
        answer = [[[PowerSession alloc] initWithConfig:pc]
                  resolveTCPDNSQuery:query resolverHost:@"8.8.8.8" port:53 timeout:6.0];
        if (!answer) DLog(@"[redirect] DNS через Power (8.8.8.8 TCP) не ответил");
    } else {
        answer = [[AmneziaWGManager sharedManager] relayDNSQuery:query];
    }

    NSArray *waitersToNotify = nil;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    [_dnsLock lock];
    waitersToNotify = [_dnsInFlight[key] copy];
    [_dnsInFlight removeObjectForKey:key];

    if (answer && answer.length >= 12) {
        if (_dnsCache.count > 500) {
            [_dnsCache removeAllObjects];
        }
        uint32_t ttl = DanteParseDNSTTL(answer.bytes, answer.length);
        DanteDNSCacheEntry *entry = [[DanteDNSCacheEntry alloc] init];
        entry.answer = answer;
        entry.expiresAt = now + ttl;
        _dnsCache[key] = entry;
    }
    [_dnsLock unlock];

    if (!answer || answer.length < 2) return;

    for (DanteDNSWaiter *w in waitersToNotify) {
        NSMutableData *reply = [answer mutableCopy];
        uint16_t waiterTxid = w.txid;
        [reply replaceBytesInRange:NSMakeRange(0, 2) withBytes:&waiterTxid];
        sendto(w.fd, reply.bytes, reply.length, 0,
               (const struct sockaddr *)w.peer.bytes, (socklen_t)w.peer.length);
    }
}

@end
