

#import "DanteFixer.h"
#import "PowerSelector.h"
#import "PowerSubscriptions.h"
#import "PowerConfig.h"
#import "DanteNetworkProbe.h"
#import "AmneziaWGManager.h"
#import "AWGConfig.h"
#import "AWGWarpRegistrar.h"
#import "DebugLog.h"

NSString * const kDanteFixerDidUpdateNotification = @"DanteFixerDidUpdate";

static const NSUInteger kDanteSeedAttempts = 6;

static const NSTimeInterval kDanteConnectTimeout = 20.0;

@interface DanteFixer ()
@property (nonatomic, readwrite) DanteFixerState state;
@property (nonatomic, readwrite, copy) NSString *statusLine;
@property (nonatomic, readwrite, copy) NSString *logText;
@property (nonatomic, readwrite, copy) NSString *proxyAddress;
@property (nonatomic, readwrite) BOOL whitelistMode;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL forceRegistration;

@property (nonatomic, assign) BOOL holdFixed;
@end

@implementation DanteFixer {
    
    
    
    NSUInteger _generation, _activeGeneration;
    BOOL _restrictedNetwork;
    PowerConfig *_powerConfig;
    dispatch_queue_t _queue;
}

+ (instancetype)sharedFixer {
    static DanteFixer *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[DanteFixer alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("org.dante.fixer", NULL);
        _state = DanteFixerStateIdle;
        _statusLine = @"Готов к работе";
        _logText = @"";
    }
    return self;
}

#pragma mark - Публичное API

- (void)fixWithFreshIdentity {
    if (_state == DanteFixerStateRunning) return;
    _forceRegistration = YES;
    [self fixInternet];
}

- (BOOL)cancelled {
    return _cancelled || _activeGeneration != _generation;
}

- (void)fixInternet {
    if (_state == DanteFixerStateRunning) return;
    _state = DanteFixerStateRunning;
    _cancelled = NO;
    NSUInteger gen = ++_generation;
    _proxyAddress = nil;
    _powerConfig = nil;
    _logText = @"";
    [self log:@"=== Dante: начинаю починку ==="];
    DCon(@"fixd: repair start");
    [self notify:@"Проверяю сеть…"];
    dispatch_async(_queue, ^{
        self->_activeGeneration = gen;
        [self runFix];
    });
}

- (void)cancel {
    [self stop];
}

- (void)stop {
    BOOL wasRunning = _state == DanteFixerStateRunning;
    _cancelled = YES;
    ++_generation;                 
    [[PowerSelector sharedSelector] cancelSearch];
    [[AmneziaWGManager sharedManager] disconnect];
    
    
    _state = DanteFixerStateIdle;
    _proxyAddress = nil;
    _powerConfig = nil;
    [self notify:wasRunning ? @"Отменено" : @"Выключено"];
    DCon(wasRunning ? @"fixd: cancelled" : @"fixd: stopped");
}

- (void)markBroken:(NSString *)reason {
    if (_state != DanteFixerStateFixed) return;
    _state = DanteFixerStateFailed;
    _proxyAddress = nil;
    [self log:reason];
    [self notify:@"Связь пропала"];
    DCon(@"wdog: link lost, rearm");
}

#pragma mark - Основной цикл (фоновая очередь)

- (void)runFix {
    AmneziaWGManager *mgr = [AmneziaWGManager sharedManager];

    
    
    
    
    PWNetworkKind kind = [[PowerSelector sharedSelector] fingerprintNetwork];
    if (kind == PWNetworkRestricted) {
        _restrictedNetwork = YES;
        [self notify:@"Белый список"];
        DCon(@"netd: filter=whitelist, cloudflare unreachable");
        [self log:@"До Cloudflare не достучаться — WARP здесь не поднимется. "
                  @"Пробую свои серверы (Power)."];
        if ([self tryPowerServers]) return;
        if (self.cancelled) return;
        _state = DanteFixerStateFailed;
        [self notify:@"Белый список"];
        [self log:@"Рабочего сервера на разрешённом адресе нет. Добавить: POWER ADD <ссылка>."];
        DCon(@"fixd: failed, no usable node");
        return;
    }
    if (self.cancelled) return;
    if (kind == PWNetworkOffline) {
        _restrictedNetwork = NO;
        _state = DanteFixerStateFailed;
        [self notify:@"Нет связи"];
        DCon(@"netd: no route to internet");
        [self log:@"Не отвечает вообще никто — сети нет."];
        return;
    }
    _restrictedNetwork = NO;
    DCon(@"netd: filter=none");

    
    self.whitelistMode = [DanteNetworkProbe detectWhitelistMode];
    [self log:self.whitelistMode
        ? @"Сеть в режиме белых списков — опорные хосты не отвечают"
        : @"Обычная фильтрация — опорные хосты доступны"];
    NSString *maskSNI = nil;
    if (self.whitelistMode) {
        maskSNI = [DanteNetworkProbe randomSNIFromResource:@"white"];
        if (maskSNI) [self log:[NSString stringWithFormat:@"Маскировочный SNI: %@", maskSNI]];
    }

    
    
    
    
    
    BOOL force = self.forceRegistration;
    self.forceRegistration = NO;
    if (!force && [self tryOwnIdentity:mgr maskSNI:maskSNI]) {
        
    } else if (!self.cancelled) {
        
        
        
        
        
        
        
        [self registerThroughCarriers:mgr maskSNI:maskSNI force:force];
    }

    if (self.cancelled) {
        [self log:@"Отменено пользователем"];   
        return;
    }

    if (_state == DanteFixerStateFixed) return;
    if (self.cancelled) return;

    
    
    
    
    
    [mgr disconnect];
    DCon(@"fixd: warp failed, falling back to exploit");
    [self log:@"WARP не поднялся — пробую свои серверы (Power)."];
    if ([self tryPowerServers]) return;
    if (self.cancelled) return;

    _state = DanteFixerStateFailed;
    [self notify:@"Не вышло"];
    [self log:@"Ни WARP, ни свои серверы не подошли. Попробуйте ещё раз позже."];
    DCon(@"fixd: failed, candidates exhausted");
}

- (BOOL)restrictedNetwork { return _restrictedNetwork; }

- (PowerConfig *)powerConfig { return _powerConfig; }

- (void)useServer:(PowerConfig *)config {
    if (!config) return;
    _powerConfig = config;
    _restrictedNetwork = YES;
    _proxyAddress = [NSString stringWithFormat:@"power:%@", config.name];
    _state = DanteFixerStateFixed;
    [self log:[NSString stringWithFormat:@"Сервер назначен вручную: %@", [config summary]]];
    DCon(@"exploit: payload pinned");
    [self notify:@"Power"];
}

- (BOOL)tryPowerServers {
    NSArray *lines = [[PowerSubscriptions shared] allLines];
    if (!lines.count) {
        [self log:@"Своих серверов не добавлено."];
        DCon(@"exploit: no payloads installed");
        return NO;
    }
    NSMutableArray *configs = [NSMutableArray array];
    for (NSString *line in lines) {
        PowerConfig *c = [PowerConfig configFromURI:line];
        if (c) [configs addObject:c];
    }
    PowerConfig *winner = [[PowerSelector sharedSelector] chooseWorkingFrom:configs timeout:8.0];
    [self log:[[PowerSelector sharedSelector] lastReport]];
    if (!winner || self.cancelled) return NO;
    _powerConfig = winner;
    _proxyAddress = [NSString stringWithFormat:@"power:%@", winner.name];
    _state = DanteFixerStateFixed;
    [self notify:@"Power"];
    [self log:[NSString stringWithFormat:@"Рабочий сервер: %@. Перенаправитель "
               @"перевожу на него — системный трафик пойдёт через Power.", winner.name]];
    return YES;
}

#pragma mark - Кандидаты

static BOOL DanteIsOwnIdentity(AWGConfig *c) {
    return [c.label isEqualToString:@"Cloudflare WARP"];
}

- (BOOL)tryOwnIdentity:(AmneziaWGManager *)mgr maskSNI:(NSString *)maskSNI {
    NSArray *configs = mgr.savedConfigs;
    for (NSInteger i = (NSInteger)configs.count - 1; i >= 0; i--) {
        AWGConfig *c = [configs objectAtIndex:(NSUInteger)i];
        if (!DanteIsOwnIdentity(c)) continue;
        [self notify:@"Подключаю WARP…"];
        [self log:[NSString stringWithFormat:@"Кандидат: своя личность (%@, %@)",
                   c.ipv4Address, c.peerEndpoint]];
        DCon(@"warp: identity %@ -> %@", c.ipv4Address, c.peerEndpoint);
        [mgr selectConfigAtIndex:(NSUInteger)i];
        if (maskSNI) mgr.currentConfig.preferredSNI = maskSNI;
        return [self connectAndVerify:mgr];
    }
    return NO;
}

- (BOOL)tryFreshRegistration:(AmneziaWGManager *)mgr maskSNI:(NSString *)maskSNI {
    [self notify:@"Регистрирую WARP…"];
    [self log:@"Кандидат: свежая регистрация WARP (api.cloudflareclient.com)"];
    DCon(@"warp: register api.cloudflareclient.com");
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [mgr generateWarpConfigWithCompletion:^(BOOL success, NSString *errorMsg) {
        ok = success;
        err = errorMsg;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                               (int64_t)(60.0 * NSEC_PER_SEC)));
    dispatch_release(sem);
    if (!ok || !DanteIsOwnIdentity(mgr.currentConfig)) {
        [self log:[NSString stringWithFormat:@"Регистрация не удалась: %@",
                   err ?: (ok ? @"выдан только общий резерв" : @"таймаут")]];
        DCon(@"warp: register failed");
        return NO;
    }
    if (maskSNI) mgr.currentConfig.preferredSNI = maskSNI;
    if (![self connectAndVerify:mgr]) return NO;
    
    
    [mgr removeConfigsPassingTest:^BOOL(AWGConfig *c) { return DanteIsOwnIdentity(c); }];
    [self log:[NSString stringWithFormat:@"  новая личность: %@", mgr.currentConfig.ipv4Address]];
    DCon(@"warp: registered %@", mgr.currentConfig.ipv4Address);
    return YES;
}

static const NSUInteger kDanteRegistrationCarriers = 5;

- (void)registerThroughCarriers:(AmneziaWGManager *)mgr maskSNI:(NSString *)maskSNI force:(BOOL)force {
    NSMutableArray *carriers = [NSMutableArray array];
    if (force && mgr.currentConfig) [carriers addObject:mgr.currentConfig];
    AWGConfig *boot = [self bootstrapConfig];
    if (boot) [carriers addObject:boot];
    [carriers addObjectsFromArray:[self verifiedSeedConfigs]];

    AWGConfig *lastWorking = nil;
    NSUInteger tried = 0;
    for (AWGConfig *carrier in carriers) {
        if (self.cancelled || tried >= kDanteRegistrationCarriers) break;
        if (maskSNI) carrier.preferredSNI = maskSNI;
        [self notify:[NSString stringWithFormat:@"WARP %lu/%lu…",
                      (unsigned long)tried + 1, (unsigned long)kDanteRegistrationCarriers]];
        [self log:[NSString stringWithFormat:@"Несущий: %@ (%@)", carrier.label, carrier.peerEndpoint]];
        DCon(@"warp: carrier %lu/%lu -> %@", (unsigned long)tried + 1,
             (unsigned long)kDanteRegistrationCarriers, carrier.peerEndpoint);
        if (![mgr.savedConfigs containsObject:carrier]) [mgr addConfig:carrier];
        [mgr selectConfigAtIndex:[mgr.savedConfigs indexOfObject:carrier]];

        self.holdFixed = YES;
        BOOL up = [self connectAndVerify:mgr];
        self.holdFixed = NO;
        if (!up) continue;
        tried++;
        lastWorking = carrier;
        if ([self tryFreshRegistration:mgr maskSNI:maskSNI]) {
            
            [mgr removeConfigsPassingTest:^BOOL(AWGConfig *c) {
                return [c.label hasPrefix:@"WARP seed"] || [c.label hasPrefix:@"WARP bootstrap"];
            }];
            return;
        }
    }
    if (self.cancelled || !lastWorking) return;

    
    [self log:@"Своя личность не получилась — остаюсь на общем ключе (под нагрузкой возможны обрывы)"];
    DCon(@"warp: fallback to shared key");
    [mgr selectConfigAtIndex:[mgr.savedConfigs indexOfObject:lastWorking]];
    if (![self connectAndVerify:mgr]) {
        [self log:@"  и общий ключ больше не отвечает"];
    }
}

#pragma mark - Подключение и верификация

- (BOOL)connectAndVerify:(AmneziaWGManager *)mgr {
    __block BOOL connected = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [mgr connectWithCompletion:^(BOOL success, NSString *errorMsg) {
        connected = success;
        err = errorMsg;
        dispatch_semaphore_signal(sem);
    }];
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(kDanteConnectTimeout * NSEC_PER_SEC)));
    dispatch_release(sem);
    if (waited != 0 || !connected) {
        [self log:[NSString stringWithFormat:@"  подключение не удалось: %@",
                   waited != 0 ? @"таймаут" : (err ?: @"неизвестная ошибка")]];
        DCon(@"warp: handshake %@", waited != 0 ? @"timeout" : @"failed");
        [mgr disconnect];
        return NO;
    }

    if ([self verifyCurrentTunnel:mgr]) return YES;
    [mgr disconnect];
    return NO;
}

- (BOOL)verifyCurrentTunnel:(AmneziaWGManager *)mgr {
    uint16_t port = mgr.socksPort;
    for (int attempt = 1; attempt <= 2; attempt++) {
        if (self.cancelled) break;
        if ([DanteNetworkProbe verifyTunnelOnSOCKSPort:port timeout:4.0]) {
            if (self.holdFixed) {
                [self log:@"  туннель жив — использую его, чтобы зарегистрировать свою личность"];
                return YES;
            }
            if (self.cancelled) return NO;
            _proxyAddress = [NSString stringWithFormat:@"127.0.0.1:%u", port];
            _state = DanteFixerStateFixed;
            [self notify:@"Готово"];
            DCon(@"warp: tunnel verified, online");
            [self log:[NSString stringWithFormat:
                       @"  туннель жив (warp=… подтверждён). SOCKS5: %@",
                       _proxyAddress]];
            return YES;
        }
        [self log:[NSString stringWithFormat:@"  проверка %d/2 не прошла", attempt]];
        DCon(@"warp: verify %d/2 failed", attempt);
    }
    return NO;
}

#pragma mark - Источники конфигов

- (AWGConfig *)bootstrapConfig {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"warp_bootstrap"
                                                     ofType:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [self log:@"warp_bootstrap.json не найден в бандле"];
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    AWGConfig *c = [AWGConfig configWithDefaults];
    c.label = @"WARP bootstrap";
    c.privateKey = [json objectForKey:@"private_key"];
    c.publicKey = [json objectForKey:@"public_key"];
    c.peerPublicKey = [json objectForKey:@"peer_pub"];
    c.peerEndpoint = [json objectForKey:@"peer_endpoint"];
    c.ipv4Address = [NSString stringWithFormat:@"%@/32", [json objectForKey:@"ipv4"]];
    if ([json objectForKey:@"ipv6"]) {
        c.ipv6Address = [NSString stringWithFormat:@"%@/128", [json objectForKey:@"ipv6"]];
    }
    [AWGWarpRegistrar applyWarpObfuscationProfile:c];
    return c;
}

- (NSArray *)verifiedSeedConfigs {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"warp_verified_seeds"
                                                     ofType:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [self log:@"warp_verified_seeds.json не найден в бандле"];
        return @[];
    }
    NSArray *seeds = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![seeds isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *shuffled = [seeds mutableCopy];
    for (NSUInteger i = shuffled.count - 1; i > 0; i--) {
        [shuffled exchangeObjectAtIndex:i
                     withObjectAtIndex:arc4random_uniform((uint32_t)i + 1)];
    }

    NSMutableArray *configs = [NSMutableArray array];
    for (NSDictionary *seed in shuffled) {
        if (configs.count >= kDanteSeedAttempts) break;
        NSString *raw = [seed objectForKey:@"raw_config"];
        AWGConfig *c = [AWGConfig configFromWireguardString:raw];
        if (!c) continue;
        c.label = [NSString stringWithFormat:@"WARP seed %@",
                   [seed objectForKey:@"source_file"] ?: @"?"];
        [configs addObject:c];
    }
    return configs;
}

#pragma mark - Лог и нотификации

- (void)log:(NSString *)message {
    DLog(@"%@", message);
    @synchronized (self) {
        _logText = [_logText stringByAppendingFormat:@"%@\n", message];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kDanteFixerDidUpdateNotification
                          object:self
                        userInfo:[NSDictionary dictionaryWithObject:message
                                                             forKey:@"message"]];
    });
}

- (void)notify:(NSString *)status {
    _statusLine = status;
    DLog(@"[статус] %@", status);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kDanteFixerDidUpdateNotification
                          object:self
                        userInfo:nil];
    });
}

@end
