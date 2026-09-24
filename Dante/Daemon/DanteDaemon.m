

#import "DanteDaemon.h"
#import "DanteControl.h"
#import "DanteRedirector.h"
#import "AWGConfig.h"
#import "DanteFixer.h"
#import "DanteNetworkProbe.h"
#import "AmneziaWGManager.h"
#import "DebugLog.h"
#import "DanteHTTPProxy.h"
#import "DanteSystemProxy.h"
#import "DanteUtun.h"
#import "DanteDCScanner.h"
#import "PowerSelector.h"
#import "PowerSubscriptions.h"
#import "PowerSession.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <sys/utsname.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

static NSString * const kEnabledKey = @"dante_enabled";

static int DanteKernelMajor(void) {
    struct utsname u;
    if (uname(&u) != 0) return 0;
    return atoi(u.release);
}

static const NSTimeInterval kWatchdogInterval = 20.0;

static NSString * const kDantePowerMotto = @"Now be both strong and bold.";

static const int kWatchdogMaxFailures = 2;

static const NSTimeInterval kRetryAfterFailure = 60.0;

static const NSTimeInterval kRetryInRestricted = 300.0;

@implementation DanteDaemon {
    dispatch_queue_t _routingQueue;   
    dispatch_source_t _sigterm;
    int _listenFd;

    
    BOOL _systemOn;
    uint16_t _routedPort;
    NSString *_systemNote;

    BOOL _redirectReady;
    NSString *_redirectError;

    int _watchdogFailures;
    BOOL _watchdogBusy;
    NSTimeInterval _failedAt;
    BOOL _dcScanning;   
    NSString *_uplink;  
    NSString *_failedNetwork;   
}

+ (void)runForever {
    static DanteDaemon *daemon;
    daemon = [[DanteDaemon alloc] init];
    [daemon start];
    [[NSRunLoop mainRunLoop] run];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _routingQueue = dispatch_queue_create("org.dante.routing", NULL);
        _listenFd = -1;
        _systemNote = @"";
    }
    return self;
}

- (BOOL)enabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey];
}

- (void)setEnabled:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Запуск и остановка

- (void)start {
    
    DebugLogSetGated(YES);
    DebugLogSetForced([[NSUserDefaults standardUserDefaults] boolForKey:@"dante_debuglog"]);
    DebugLogInitWithPath(@"/tmp/dante_debug.log");
    
    
    if (lseek(STDERR_FILENO, 0, SEEK_END) > 1024 * 1024) ftruncate(STDERR_FILENO, 0);
    DLog(@"Служба Dante запущена (pid %d, uid %d)", getpid(), getuid());
    signal(SIGPIPE, SIG_IGN);

    
    
    signal(SIGTERM, SIG_IGN);
    _sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                      dispatch_get_main_queue());
    dispatch_source_set_event_handler(_sigterm, ^{
        DLog(@"SIGTERM — откатываю маршрутизацию и выхожу");
        if (DanteKernelMajor() < 13) {
            [[DanteUtun sharedUtun] disable];
            [DanteSystemProxy disableProxyWithError:nil];
        } else {
            [[DanteRedirector sharedRedirector] setPowerConfig:nil];
            [[DanteUtun sharedUtun] disable];
            [[DanteRedirector sharedRedirector] disable];
        }
        [[AmneziaWGManager sharedManager] disconnect];
        exit(0);
    });
    dispatch_resume(_sigterm);

    [self migrateMobilePreferences];
    [AmneziaWGManager sharedManager].preferredSOCKSPort = kDanteSOCKSPort;
    
    
    
    [self applyUplinkSettings];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(fixerUpdated:)
                                                 name:kDanteFixerDidUpdateNotification
                                               object:nil];

    if (![self startControlServer]) {
        DLog(@"Не удалось открыть порт управления %u — выхожу", kDanteControlPort);
        exit(1);
    }

    NSString *proxyErr = nil;
    if (![[DanteHTTPProxy sharedProxy] startWithError:&proxyErr]) {
        DLog(@"[proxy] HTTP-прокси недоступен: %@", proxyErr);
    }

    NSString *err = nil;
    _redirectReady = [[DanteRedirector sharedRedirector] startListenersWithError:&err];
    if (!_redirectReady) {
        DLog(@"[redirect] системный режим недоступен: %@", err);
        _redirectError = err;
    }

    
    dispatch_async(_routingQueue, ^{
        if (DanteKernelMajor() < 13) {
            
            [[DanteUtun sharedUtun] restoreLeftovers];
            if (![self enabled]) {
                [DanteSystemProxy disableProxyWithError:nil];
            }
        } else {
            [[DanteRedirector sharedRedirector] disable];
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            
            DanteDCScanner *scanner = [DanteDCScanner sharedScanner];
            NSString *best = scanner.autoMode ? [scanner autoEndpointAfter:nil] : nil;
            if (best && [scanner resultForEndpoint:best].ms > 0) {
                [self applyEndpoint:best why:@"авто, самый быстрый"];
            }
        });
        if ([self enabled]) {
            DLog(@"Служба была включена — чиню при старте");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[DanteFixer sharedFixer] fixInternet];
            });
        }
    });

    [NSTimer scheduledTimerWithTimeInterval:kWatchdogInterval target:self
                                   selector:@selector(watchdogTick) userInfo:nil
                                    repeats:YES];
}

- (void)migrateMobilePreferences {
    if (getuid() != 0) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *domain = [[NSBundle mainBundle] bundleIdentifier] ?: @"org.dante.fixer";
    NSDictionary *mine = [ud persistentDomainForName:domain];
    if ([mine objectForKey:@"awg_configs_key"]) return;
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", domain];
    NSDictionary *theirs = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![theirs objectForKey:@"awg_configs_key"]) return;
    NSMutableDictionary *merged = [theirs mutableCopy];
    [merged addEntriesFromDictionary:mine ?: @{}];
    [ud setPersistentDomain:merged forName:domain];
    [ud synchronize];
    DLog(@"Настройки перенесены из %@ (%lu ключей)", path, (unsigned long)merged.count);
}

#pragma mark - Команды

static int DanteTryConnect(struct addrinfo *res, int timeoutSec, int *elapsed) {
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *elapsed = 0; return errno; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int err = 0;
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set w;
        FD_ZERO(&w);
        FD_SET(fd, &w);
        struct timeval tv = { timeoutSec, 0 };
        if (select(fd + 1, NULL, &w, NULL, &tv) <= 0) {
            err = ETIMEDOUT;
        } else {
            socklen_t len = sizeof(err);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        }
    } else if (rc != 0) {
        err = errno;
    }
    gettimeofday(&t1, NULL);
    *elapsed = (int)((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000);
    close(fd);
    return err;
}

static NSString *DanteConnectVerdict(int err) {
    if (err == 0) return @"ПУСКАЮТ — соединились";
    if (err == ECONNREFUSED) return @"отказ: либо сеть режет адрес, либо порт закрыт";
    if (err == ETIMEDOUT) return @"молчит: пакеты пропадают";
    return [NSString stringWithUTF8String:strerror(err)] ?: @"ошибка";
}

static NSString *DanteScanProviders(void) {
    static const char *kProbes[] = {
        "Aeza (РФ)",        "95.181.177.125",
        "Timeweb",          "185.65.148.89",
        "Timeweb Cloud",    "178.248.239.157",
        "Beget",            "178.248.236.146",
        "Reg.ru",           "194.67.72.31",
        "Vdsina",           "91.215.41.84",
        "Яндекс Облако",    "213.180.193.243",
        "VK Cloud",         "95.163.53.117",
        "RuVDS",            "186.2.163.33",
        "Hetzner (не РФ)",  "213.133.116.44",
        "Vultr (не РФ)",    "108.61.13.174",
    };
    NSMutableString *out = [NSMutableString stringWithString:@"OK\tгде можно брать сервер"];
    for (size_t i = 0; i < sizeof(kProbes) / sizeof(kProbes[0]); i += 2) {
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(kProbes[i + 1], "443", &hints, &res) != 0 || !res) continue;
        int ms = 0;
        int err = DanteTryConnect(res, 4, &ms);
        freeaddrinfo(res);
        
        
        [out appendFormat:@"\n%@\t%s\t%d мс\t%@",
         [NSString stringWithUTF8String:kProbes[i]] ?: @"?", kProbes[i + 1], ms,
         err == 0 ? @"открыт" : @"закрыт"];
    }
    [out appendString:@"\nОткрытый — сеть пускает к его адресам: сервер оттуда будет виден."];
    return out;
}

- (NSString *)commandPower:(NSString *)argument {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    
    NSArray *stored = [[PowerSubscriptions shared] allLines];
    NSArray *manual = [ud objectForKey:@"power_configs"] ?: @[];
    PowerSelector *selector = [PowerSelector sharedSelector];

    NSArray *words = [argument componentsSeparatedByString:@" "];
    NSString *verb = words.count ? [[words objectAtIndex:0] uppercaseString] : @"";

    if ([verb isEqualToString:@"ADD"]) {
        NSString *uri = [[argument substringFromIndex:3] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *parsed = [PowerConfig configsFromText:uri];
        if (!parsed.count) return @"ERR\tне разобрал ни одной ссылки";
        NSMutableArray *all = [NSMutableArray arrayWithArray:manual];
        
        for (NSString *line in [uri componentsSeparatedByCharactersInSet:
                                [NSCharacterSet newlineCharacterSet]]) {
            NSString *t = [line stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length && ![all containsObject:t]) [all addObject:t];
        }
        [ud setObject:all forKey:@"power_configs"];
        [ud synchronize];
        return [NSString stringWithFormat:@"OK\tдобавлено %lu, всего %lu",
                (unsigned long)parsed.count, (unsigned long)all.count];
    }

    if ([verb isEqualToString:@"LIST"]) {
        NSMutableString *out = [NSMutableString stringWithString:@"OK"];
        NSUInteger i = 0;
        for (NSString *line in stored) {
            PowerConfig *c = [PowerConfig configFromURI:line];
            [out appendFormat:@"\n%lu\t%@\t%@", (unsigned long)i++,
             c ? [c summary] : @"(не разобрано)",
             c ? ([c isSupported] ? @"поддержан" : [c unsupportedReason]) : @"—"];
        }
        if (!stored.count) [out appendString:@"\nсписок пуст"];
        return out;
    }

    if ([verb isEqualToString:@"PICK"]) {
        
        NSTimeInterval timeout = 8.0;
        if (words.count > 1) {
            NSTimeInterval t = [[words objectAtIndex:1] doubleValue];
            if (t >= 1.0 && t <= 30.0) timeout = t;
        }
        NSMutableArray *configs = [NSMutableArray array];
        for (NSString *line in stored) {
            PowerConfig *c = [PowerConfig configFromURI:line];
            if (c) [configs addObject:c];
        }
        PowerConfig *winner = [selector chooseWorkingFrom:configs timeout:timeout];
        return [NSString stringWithFormat:@"OK\t%@\n%@",
                winner ? winner.name : @"рабочей нет", [selector lastReport]];
    }

    
    if ([verb isEqualToString:@"TRACE"]) {
        extern volatile int gPWRealityTrace;
        gPWRealityTrace = words.count > 1 ? (int)[[words objectAtIndex:1] integerValue] : 1;
        return [NSString stringWithFormat:@"OK\tтрассировка REALITY %@",
                gPWRealityTrace ? @"включена" : @"выключена"];
    }

    
    if ([verb isEqualToString:@"SCAN"]) return DanteScanProviders();

    
    
    if ([verb isEqualToString:@"USE"]) {
        if (words.count < 2) return @"ERR\tнужно: POWER USE <номер из POWER LIST>";
        NSInteger index = [[words objectAtIndex:1] integerValue];
        if (index < 0 || index >= (NSInteger)stored.count) {
            return [NSString stringWithFormat:@"ERR\tнет такого номера (всего %lu)",
                    (unsigned long)stored.count];
        }
        PowerConfig *c = [PowerConfig configFromURI:[stored objectAtIndex:(NSUInteger)index]];
        if (!c) return @"ERR\tэта строка не разбирается";
        if (![c isSupported]) {
            return [NSString stringWithFormat:@"ERR\t%@", [c unsupportedReason]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DanteFixer sharedFixer] useServer:c];
        });
        return [NSString stringWithFormat:@"OK\t%@", [c summary]];
    }

    
    
    
    if ([verb isEqualToString:@"CHECK"]) {
        if (words.count < 2) return @"ERR\tнужно: POWER CHECK <хост> [порт]";
        NSString *host = [words objectAtIndex:1];
        NSString *port = words.count > 2 ? [words objectAtIndex:2] : @"443";
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo([host UTF8String], [port UTF8String], &hints, &res) != 0 || !res) {
            return [NSString stringWithFormat:@"ERR\tимя %@ не разрешилось", host];
        }
        char addr[INET_ADDRSTRLEN] = "";
        inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, addr, sizeof(addr));
        int elapsed = 0;
        int err = DanteTryConnect(res, 6, &elapsed);
        freeaddrinfo(res);
        return [NSString stringWithFormat:@"OK\t%@ (%s:%@)\t%d мс\t%@",
                host, addr, port, elapsed, DanteConnectVerdict(err)];
    }

    
    
    if ([verb isEqualToString:@"CLEAR"]) {
        [ud removeObjectForKey:@"power_configs"];
        [ud synchronize];
        return @"OK\tручные серверы очищены, подписки на месте";
    }

    
    
    if ([verb isEqualToString:@"SUB"]) {
        NSString *urlText = [[argument substringFromIndex:3]
                             stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *err = nil;
        NSString *r = [[PowerSubscriptions shared] addURL:urlText error:&err];
        return r ? [NSString stringWithFormat:@"OK\t%@", r]
                 : [NSString stringWithFormat:@"ERR\t%@", err ?: @"не скачалась"];
    }

    
    if ([verb isEqualToString:@"SUBS"]) {
        NSArray *subs = [[PowerSubscriptions shared] subscriptions];
        NSMutableString *out = [NSMutableString stringWithFormat:@"OK\tподписок %lu, ручных серверов %lu",
                                (unsigned long)subs.count, (unsigned long)manual.count];
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSUInteger i = 0;
        for (NSDictionary *d in subs) {
            double age = now - [[d objectForKey:@"fetchedAt"] doubleValue];
            NSString *err = [d objectForKey:@"lastError"];
            [out appendFormat:@"\n%lu\t%@\tсерверов %@\tобновлена %.0f мин назад%@",
             (unsigned long)i++, [d objectForKey:@"url"], [d objectForKey:@"count"], age / 60,
             err ? [NSString stringWithFormat:@"\tпоследняя попытка: %@", err] : @""];
        }
        return out;
    }

    
    if ([verb isEqualToString:@"UNSUB"]) {
        if (words.count < 2) return @"ERR\tнужно: POWER UNSUB <номер из POWER SUBS>";
        return [[PowerSubscriptions shared] removeAtIndex:(NSUInteger)[[words objectAtIndex:1] integerValue]]
             ? @"OK\tподписка убрана" : @"ERR\tнет такой подписки";
    }

    
    if ([verb isEqualToString:@"REFRESH"]) {
        return [NSString stringWithFormat:@"OK\t%@", [[PowerSubscriptions shared] refreshAllNow]];
    }

    
    PWNetworkKind kind = [selector fingerprintNetwork];
    NSString *name = kind == PWNetworkOpen ? @"открытая"
                   : kind == PWNetworkRestricted ? @"белый список" : @"нет связи";
    return [NSString stringWithFormat:@"OK\t%@\t%@\tсерверов %lu",
            name, [selector networkKey], (unsigned long)stored.count];
}

- (void)commandFix {
    [self commandFixFresh:NO];
}

- (void)commandFixFresh:(BOOL)fresh {
    [self setEnabled:YES];
    
    
    dispatch_async(_routingQueue, ^{
        [self disableRoutingLocked];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_watchdogFailures = 0;
            if (fresh) {
                [[DanteFixer sharedFixer] fixWithFreshIdentity];
            } else {
                [[DanteFixer sharedFixer] fixInternet];
            }
        });
    });
}

- (void)commandStop {
    [self setEnabled:NO];
    dispatch_async(_routingQueue, ^{
        [self disableRoutingLocked];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DanteFixer sharedFixer] stop];
        });
    });
}

- (void)consoleAttach {
    struct utsname u;
    uname(&u);
    DCon(@"dante: attach fixd pid %d, darwin %s %s", getpid(), u.release, u.machine);
    DanteFixer *fixer = [DanteFixer sharedFixer];
    NSString *uplink;
    @synchronized (self) { uplink = _uplink; }
    if (uplink) DCon(@"netd: uplink %@", uplink);
    NSString *route = [DanteUtun sharedUtun].isUp ? [DanteUtun sharedUtun].interfaceName
                    : ([DanteRedirector sharedRedirector].enabled ? @"pf" : @"proxy");
    switch (fixer.state) {
        case DanteFixerStateFixed:
            if (fixer.powerConfig) {
                DCon(@"state: online via exploit (%@)", route);
            } else {
                DCon(@"state: online via warp %@ (%@)",
                     [AmneziaWGManager sharedManager].currentConfig.peerEndpoint ?: @"?", route);
            }
            break;
        case DanteFixerStateRunning: DCon(@"state: repair in progress"); break;
        case DanteFixerStateFailed:  DCon(@"state: offline"); break;
        default:                     DCon(@"state: idle"); break;
    }
}

- (NSString *)statusLine {
    DanteFixer *fixer = [DanteFixer sharedFixer];
    DanteDCScanner *scanner = [DanteDCScanner sharedScanner];
    if (_dcScanning) {
        NSString *target = scanner.targetColo;
        NSString *what = target
            ? [NSString stringWithFormat:@"%@… (%lu/%lu)", [DanteDCScanner countryForColo:target],
               (unsigned long)scanner.done + 1, (unsigned long)scanner.total]
            : [NSString stringWithFormat:@"Дата-центры %lu/%lu…",
               (unsigned long)scanner.done, (unsigned long)scanner.total];
        return [NSString stringWithFormat:@"OK\t%ld\t0\t-\t%@\tПоиск страны",
                (long)DanteFixerStateRunning, what];
    }
    __block BOOL systemOn;
    __block NSString *note;
    
    @synchronized (self) {
        systemOn = _systemOn;
        note = _systemNote;
    }
    NSString *status = [fixer.statusLine stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    
    PowerSelector *sel = [PowerSelector sharedSelector];
    NSUInteger total = sel.progressTotal;
    NSString *progress = total
        ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)sel.progressDone, (unsigned long)total] : @"-";
    return [NSString stringWithFormat:@"OK\t%ld\t%d\t%@\t%@\t%@\t%@",
            (long)fixer.state, systemOn ? 1 : 0, fixer.proxyAddress ?: @"-",
            status ?: @"", note ?: @"", progress];
}

#pragma mark - Дата-центры

- (NSString *)commandDCScan {
    if (_dcScanning) return @"OK";
    if ([DanteFixer sharedFixer].state == DanteFixerStateRunning) return @"ERR идёт починка";
    if (![AmneziaWGManager sharedManager].currentConfig) return @"ERR нет личности WARP";
    _dcScanning = YES;
    DLog(@"[dc] выбор дата-центра: останавливаю основной туннель");
    
    dispatch_async(_routingQueue, ^{
        [self disableRoutingLocked];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DanteFixer sharedFixer] stop];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                DanteDCScanner *scanner = [DanteDCScanner sharedScanner];
                [scanner scan];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_dcScanning = NO;
                    if (scanner.autoMode) [self applyEndpoint:[scanner autoEndpointAfter:nil] why:@"авто, самый быстрый"];
                    if ([self enabled]) [self commandFix];
                });
            });
        });
    });
    return @"OK";
}

- (NSString *)commandDCList {
    DanteDCScanner *scanner = [DanteDCScanner sharedScanner];
    NSString *current = [AmneziaWGManager sharedManager].currentConfig.peerEndpoint ?: @"";
    NSMutableString *out = [NSMutableString stringWithFormat:@"OK\t%d\t%lu\t%lu\t%d",
                            self->_dcScanning ? 1 : 0, (unsigned long)scanner.done,
                            (unsigned long)scanner.total, scanner.autoMode ? 1 : 0];
    for (DanteDCResult *r in scanner.results) {
        [out appendFormat:@"\n%@\t%@\t%@\t%lu\t%d\t%@", r.endpoint, r.colo,
         [DanteDCScanner cityForColo:r.colo], (unsigned long)r.ms,
         [r.endpoint isEqualToString:current] ? 1 : 0, [DanteDCScanner countryForColo:r.colo]];
    }
    return out;
}

- (void)applyEndpoint:(NSString *)endpoint why:(NSString *)why {
    AmneziaWGManager *mgr = [AmneziaWGManager sharedManager];
    if (endpoint.length == 0 || [endpoint isEqualToString:mgr.currentConfig.peerEndpoint]) return;
    [mgr setEndpointForCurrentConfig:endpoint];
    DanteDCResult *r = [[DanteDCScanner sharedScanner] resultForEndpoint:endpoint];
    DLog(@"[dc] адрес %@ (%@) — %@", endpoint,
         r ? [DanteDCScanner countryForColo:r.colo] : @"?", why);
}

- (NSString *)commandDCAuto {
    if (_dcScanning) return @"ERR идёт проверка";
    DanteDCScanner *scanner = [DanteDCScanner sharedScanner];
    scanner.autoMode = YES;
    NSString *before = [AmneziaWGManager sharedManager].currentConfig.peerEndpoint;
    [self applyEndpoint:[scanner autoEndpointAfter:nil] why:@"авто, самый быстрый"];
    if (![before isEqualToString:[AmneziaWGManager sharedManager].currentConfig.peerEndpoint]) {
        [self commandFix];
    }
    return @"OK";
}

- (NSString *)commandDCSet:(NSString *)colo {
    if (_dcScanning) return @"ERR уже ищу";
    if (![AmneziaWGManager sharedManager].currentConfig) return @"ERR нет личности WARP";
    
    if ([colo rangeOfString:@":"].location != NSNotFound) {
        if (![[DanteDCScanner sharedScanner] resultForEndpoint:colo]) return @"ERR неизвестный адрес";
        [DanteDCScanner sharedScanner].autoMode = NO;
        [self applyEndpoint:colo why:@"выбран вручную"];
        [self commandFix];
        return @"OK";
    }
    if ([DanteFixer sharedFixer].state == DanteFixerStateRunning) return @"ERR идёт починка";
    if (colo.length != 3) return @"ERR нужен код дата-центра или адрес";
    [DanteDCScanner sharedScanner].autoMode = NO;
    _dcScanning = YES;
    [self setEnabled:YES];
    dispatch_async(_routingQueue, ^{
        [self disableRoutingLocked];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DanteFixer sharedFixer] stop];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *endpoint = [[DanteDCScanner sharedScanner] findEndpointForColo:colo];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_dcScanning = NO;
                    if (endpoint) {
                        [[AmneziaWGManager sharedManager] setEndpointForCurrentConfig:endpoint];
                        DLog(@"[dc] выход: %@ через %@", [DanteDCScanner countryForColo:colo], endpoint);
                    } else {
                        DLog(@"[dc] %@ сейчас недоступна — остаюсь на прежнем адресе",
                             [DanteDCScanner countryForColo:colo]);
                    }
                    [self commandFix];
                });
            });
        });
    });
    return @"OK";
}

#pragma mark - Реакция на починку

- (void)fixerUpdated:(NSNotification *)note {
    DanteFixer *fixer = [DanteFixer sharedFixer];
    if (fixer.state == DanteFixerStateFixed) {
        _watchdogFailures = 0;
        if (fixer.powerConfig) {
            
            
            dispatch_async(_routingQueue, ^{
                if (DanteKernelMajor() >= 13 && self->_systemOn &&
                    self->_routedPort == kDanteRedirectPort) return;
                
                
                [self enableRoutingLockedForPower];
            });
            return;
        }
        uint16_t port = [AmneziaWGManager sharedManager].socksPort;
        dispatch_async(_routingQueue, ^{
            
            if (DanteKernelMajor() >= 13 && self->_systemOn && self->_routedPort == port) return;
            [self enableRoutingLockedOnPort:port];
        });
    } else if (fixer.state == DanteFixerStateFailed) {
        _failedAt = [NSDate timeIntervalSinceReferenceDate];
        _failedNetwork = [[PowerSelector sharedSelector] networkKey];
        dispatch_async(_routingQueue, ^{ [self disableRoutingLocked]; });
    } else if (fixer.state == DanteFixerStateIdle) {
        dispatch_async(_routingQueue, ^{ [self disableRoutingLocked]; });
    }
}

- (void)enableRoutingLockedForPower {
    PowerConfig *pc = [DanteFixer sharedFixer].powerConfig;
    if (!pc) return;
    if (DanteKernelMajor() < 13) {
        
        
        
        
        [DanteHTTPProxy sharedProxy].powerConfig = pc;
        if ([self enablePowerTunLocked:pc]) return;
        
        
        [[DanteUtun sharedUtun] disable];
        NSString *proxyErr = nil;
        if ([DanteSystemProxy enableProxyOnPort:kDanteHTTPProxyPort error:&proxyErr]) {
            [self setSystemOn:YES port:kDanteHTTPProxyPort
                         note:@"Power · только прокси"];
            DLog(@"[routing] iOS 5 — Power через прокси 127.0.0.1:%u, сервер %@",
                 kDanteHTTPProxyPort, pc.name);
            DCon(@"route: http proxy 127.0.0.1:%u -> exploit (fallback)", kDanteHTTPProxyPort);
        } else {
            [DanteHTTPProxy sharedProxy].powerConfig = nil;
            [self setSystemOn:NO port:0
                         note:[NSString stringWithFormat:@"прокси: %@", proxyErr]];
            DLog(@"[routing] iOS 5 — прокси под Power не включился: %@", proxyErr);
            DCon(@"route: failed");
        }
        return;
    }
    if (!_redirectReady) {
        
        if ([self enablePowerTunLocked:pc]) return;
        [self setSystemOn:NO port:0
                     note:@"Только SOCKS5"];
        return;
    }
    [[DanteRedirector sharedRedirector] setPowerConfig:pc];
    
    
    
    NSMutableArray *bypass = [NSMutableArray array];
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portText[8];
    snprintf(portText, sizeof(portText), "%u", pc.port);
    if (getaddrinfo([pc.host UTF8String], portText, &hints, &res) == 0 && res) {
        char addr[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr,
                      addr, sizeof(addr))) {
            [bypass addObject:[NSString stringWithUTF8String:addr]];
        }
        freeaddrinfo(res);
    } else {
        DLog(@"[routing] адрес сервера Power (%@) не разрешился — обходного правила не будет", pc.host);
    }
    NSString *err = nil;
    if ([[DanteRedirector sharedRedirector] enableWithBypassIPs:bypass error:&err]) {
        [self setSystemOn:YES port:kDanteRedirectPort
                     note:kDantePowerMotto];
        DLog(@"[routing] системный режим включён (Power: %@)", pc.name);
        DCon(@"pf: rdr tcp -> :%u, udp/53 -> :%u, exploit", kDanteRedirectPort, kDanteDNSPort);
    } else if ([self enablePowerTunLocked:pc]) {
        DLog(@"[routing] pf не включился (%@) — работаем через utun", err);
    } else {
        [[DanteRedirector sharedRedirector] setPowerConfig:nil];
        [self setSystemOn:NO port:0 note:[NSString stringWithFormat:@"pf: %@", err]];
        DLog(@"[routing] не включился: %@", err);
    }
}

- (BOOL)enablePowerTunLocked:(PowerConfig *)pc {
    
    
    BOOL already = [DanteUtun sharedUtun].powerMode && _systemOn && _routedPort == kDanteTunTCPPort &&
                   [[DanteRedirector sharedRedirector].powerConfig isEqual:pc];
    if (already) return YES;
    [[DanteRedirector sharedRedirector] setPowerConfig:pc];
    NSString *err = nil;
    if (![[DanteUtun sharedUtun] enableForPowerServer:pc.host error:&err]) {
        DLog(@"[routing] utun под Power не поднялся: %@", err);
        if (DanteKernelMajor() >= 13) [[DanteRedirector sharedRedirector] setPowerConfig:nil];
        return NO;
    }
    
    
    if (DanteKernelMajor() < 13 && [DanteSystemProxy isProxyEnabled]) {
        [DanteSystemProxy disableProxyWithError:nil];
    }
    [self setSystemOn:YES port:kDanteTunTCPPort
                 note:kDantePowerMotto];
    DLog(@"[routing] Power через utun: сервер %@", pc.name);
    DCon(@"route: 0/1 128/1 -> %@, tcp+dns -> exploit", [DanteUtun sharedUtun].interfaceName);
    return YES;
}

- (void)enableRoutingLockedOnPort:(uint16_t)port {
    if (port == 0) return;
    
    
    
    if (DanteKernelMajor() < 13) {
        NSString *err = nil;
        AWGConfig *config = [AmneziaWGManager sharedManager].currentConfig;
        if (config && [[DanteUtun sharedUtun] enableForConfig:config error:&err]) {
            [DanteSystemProxy disableProxyWithError:nil];
            [self setSystemOn:YES port:port note:@"WARP"];
            DCon(@"route: 0/1 128/1 -> %@, warp", [DanteUtun sharedUtun].interfaceName);
            return;
        }
        DLog(@"[routing] iOS 5 — utun не поднялся (%@), включаю HTTP-прокси", err);
        err = nil;
        if ([DanteSystemProxy enableProxyOnPort:port error:&err]) {
            [self setSystemOn:YES port:port note:@"WARP · только прокси"];
            DLog(@"[routing] iOS 5 — системный HTTP-прокси 127.0.0.1:%u включён", port);
            DCon(@"route: http proxy 127.0.0.1:%u -> warp (fallback)", port);
        } else {
            [self setSystemOn:NO port:0 note:[NSString stringWithFormat:@"прокси: %@", err]];
            DLog(@"[routing] iOS 5 — прокси не включился: %@", err);
        }
        return;
    }
    if (!_redirectReady) {
        [self setSystemOn:NO port:0
                     note:@"Только SOCKS5"];
        return;
    }
    
    NSString *endpoint = [AmneziaWGManager sharedManager].currentConfig.peerEndpoint;
    NSString *endpointIP = [[endpoint componentsSeparatedByString:@":"] objectAtIndex:0];
    NSString *err = nil;
    if ([[DanteRedirector sharedRedirector] enableWithBypassIPs:endpointIP ? @[endpointIP] : @[]
                                                          error:&err]) {
        [self setSystemOn:YES port:port note:@"WARP"];
        DLog(@"[routing] системный режим включён");
        DCon(@"pf: rdr tcp -> :%u, udp/53 -> :%u, warp", kDanteRedirectPort, kDanteDNSPort);
    } else {
        [self setSystemOn:NO port:0 note:[NSString stringWithFormat:@"pf: %@", err]];
        DLog(@"[routing] не включился: %@", err);
    }
}

- (void)disableRoutingLocked {
    [[DanteRedirector sharedRedirector] setPowerConfig:nil];
    if (DanteKernelMajor() < 13) {
        [DanteHTTPProxy sharedProxy].powerConfig = nil;
        [[DanteUtun sharedUtun] disable];
        if ([DanteSystemProxy isProxyEnabled]) [DanteSystemProxy disableProxyWithError:nil];
    } else {
        [[DanteUtun sharedUtun] disable];
        [[DanteRedirector sharedRedirector] disable];
    }
    if (_systemOn) {
        DLog(@"[routing] системный режим выключен");
        DCon(@"route: flushed");
    }
    [self setSystemOn:NO port:0 note:@""];
}

- (void)setSystemOn:(BOOL)on port:(uint16_t)port note:(NSString *)note {
    @synchronized (self) {
        _systemOn = on;
        _routedPort = port;
        _systemNote = note;
    }
}

#pragma mark - Сторож

- (NSString *)applyUplinkSettings {
    char ifname[IFNAMSIZ] = {0};
    BOOL cellular = NO;
    NSString *name = DNPrimaryUplink(ifname, sizeof(ifname), NULL, NULL, &cellular)
                   ? [NSString stringWithUTF8String:ifname] : nil;
    [AmneziaWGManager sharedManager].keepRadioAwake = !cellular;
    if (name && ![name isEqualToString:_uplink]) {
        DLog(@"[канал] наружу через %@%@", name, cellular ? @" (сотовая связь)" : @"");
    }
    _uplink = name;
    return name;
}

- (void)watchdogTick {
    DanteFixer *fixer = [DanteFixer sharedFixer];
    
    
    [[PowerSubscriptions shared] refreshIfStale];
    if (![self enabled] || _dcScanning) return;

    
    
    char nowIf[IFNAMSIZ] = {0};
    if (DNPrimaryUplink(nowIf, sizeof(nowIf), NULL, NULL, NULL)) {
        NSString *now = [NSString stringWithUTF8String:nowIf];
        if (_uplink && ![now isEqualToString:_uplink]) {
            DLog(@"[канал] был %@, стал %@ — перенастраиваю", _uplink, now);
            DCon(@"netd: uplink %@ -> %@", _uplink, now);
            [self applyUplinkSettings];
            [self commandFix];
            return;
        }
        if (!_uplink) [self applyUplinkSettings];
    }

    if (fixer.state == DanteFixerStateFailed || fixer.state == DanteFixerStateIdle) {
        
        
        
        NSTimeInterval wait = fixer.restrictedNetwork ? kRetryInRestricted : kRetryAfterFailure;
        NSString *nowKey = [[PowerSelector sharedSelector] networkKey];
        BOOL networkChanged = _failedNetwork && ![nowKey isEqualToString:_failedNetwork];
        if (networkChanged) {
            DLog(@"[watchdog] сеть сменилась (%@ -> %@) — пробую снова", _failedNetwork, nowKey);
        }
        if (networkChanged || [NSDate timeIntervalSinceReferenceDate] - _failedAt >= wait) {
            if (!networkChanged && fixer.restrictedNetwork) {
                DLog(@"[watchdog] сеть по-прежнему под белым списком — пробую ещё раз");
            } else if (!networkChanged) {
                DLog(@"[watchdog] служба включена, но интернета нет — пробую снова");
            }
            _failedNetwork = nowKey;
            [self commandFix];
        }
        return;
    }
    if (fixer.state != DanteFixerStateFixed || _watchdogBusy) return;

    
    
    
    PowerConfig *power = fixer.powerConfig;
    if (power) {
        
        
        
        NSTimeInterval lastClient = MAX([DanteRedirector sharedRedirector].lastClientAt,
                                        [DanteHTTPProxy sharedProxy].lastClientAt);
        if (lastClient > 0 && [NSDate timeIntervalSinceReferenceDate] - lastClient < 60.0) {
            _watchdogFailures = 0;
            return;
        }
    } else {
        NSTimeInterval lastData = [AmneziaWGManager sharedManager].lastDataAt;
        if (lastData > 0 && [NSDate timeIntervalSinceReferenceDate] - lastData < 3.0) {
            _watchdogFailures = 0;
            return;
        }
    }

    _watchdogBusy = YES;
    uint16_t port = power ? 0 : [AmneziaWGManager sharedManager].socksPort;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL alive;
        if (power) {
            
            
            alive = ([[[PowerSession alloc] initWithConfig:power]
                      probeThroughHost:@"www.google.com" port:80
                               timeout:6.0 latencyMillis:NULL] == PWProbeOK);
        } else {
            alive = port && [DanteNetworkProbe verifyTunnelOnSOCKSPort:port timeout:6.0];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_watchdogBusy = NO;
            if (fixer.state != DanteFixerStateFixed) return;
            if (alive) {
                self->_watchdogFailures = 0;
                
                dispatch_async(self->_routingQueue, ^{
                    
                    
                    
                    
                    if (!fixer.powerConfig && self->_systemOn && self->_routedPort != port) {
                        [self enableRoutingLockedOnPort:port];
                    }
                    [[DanteUtun sharedUtun] reassertDNS];
                });
                return;
            }
            self->_watchdogFailures++;
            DLog(@"[watchdog] %@ не отвечает (%d/%d)",
                 power ? @"сервер Power" : @"туннель",
                 self->_watchdogFailures, kWatchdogMaxFailures);
            DCon(@"wdog: %@ no reply %d/%d", power ? @"exploit" : @"warp",
                 self->_watchdogFailures, kWatchdogMaxFailures);
            if (self->_watchdogFailures >= kWatchdogMaxFailures) {
                DanteDCScanner *scanner = [DanteDCScanner sharedScanner];
                if (!power && scanner.autoMode) {
                    NSString *now = [AmneziaWGManager sharedManager].currentConfig.peerEndpoint;
                    [self applyEndpoint:[scanner autoEndpointAfter:now] why:@"авто, прежний не отвечает"];
                }
                [fixer markBroken:@"Туннель перестал отвечать — перечиниваю"];
                [self commandFix];
            }
        });
    });
}

#pragma mark - Сервер управления

- (BOOL)startControlServer {
    _listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) return NO;
    int one = 1;
    setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDanteControlPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(_listenFd, 16) != 0) {
        close(_listenFd);
        _listenFd = -1;
        return NO;
    }
    DLog(@"Управление: 127.0.0.1:%u", kDanteControlPort);
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    return YES;
}

- (void)acceptLoop {
    for (;;) {
        @autoreleasepool {
            int fd = accept(_listenFd, NULL, NULL);
            if (fd < 0) continue;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self serveClient:fd];
            });
        }
    }
}

- (void)serveClient:(int)fd {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buf[256];
    size_t len = 0;
    while (len < sizeof(buf) - 1) {
        ssize_t n = recv(fd, buf + len, sizeof(buf) - 1 - len, 0);
        if (n <= 0) break;
        len += (size_t)n;
        if (memchr(buf, '\n', len)) break;
    }
    buf[len] = 0;
    NSString *raw = [NSString stringWithUTF8String:buf] ?: @"";
    NSString *cmd = [[raw stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];

    if (![cmd isEqualToString:@"STATUS"] && ![cmd isEqualToString:@"LOG"] &&
        ![cmd isEqualToString:@"PERF"] && ![cmd isEqualToString:@"DCLIST"]) {
        DLog(@"Команда: %@", cmd);
    }
    NSString *reply;
    if ([cmd isEqualToString:@"STATUS"]) {
        
        
        if (DebugLogUIPing()) [self consoleAttach];
        reply = [self statusLine];
    } else if ([cmd isEqualToString:@"FIX"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self commandFix]; });
        reply = @"OK";
    } else if ([cmd isEqualToString:@"REGISTER"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self commandFixFresh:YES]; });
        reply = @"OK";
    } else if ([cmd isEqualToString:@"STOP"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self commandStop]; });
        reply = @"OK";
    } else if ([cmd hasPrefix:@"POWER"]) {
        
        
        
        NSString *rest = [[raw stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                          substringFromIndex:MIN((NSUInteger)5, raw.length)];
        rest = [rest stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        reply = [self commandPower:rest];
    } else if ([cmd hasPrefix:@"MERGE"]) {
        
        
        extern volatile int gDNMergeLoops;
        gDNMergeLoops = (int)[[cmd substringFromIndex:5] integerValue];
        [[NSUserDefaults standardUserDefaults] setInteger:gDNMergeLoops forKey:@"dante_merge"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        reply = [NSString stringWithFormat:@"OK\t%d", gDNMergeLoops];
    } else if ([cmd hasPrefix:@"BATCH"]) {
        
        
        extern volatile int gDNBatchSend;
        gDNBatchSend = (int)[[cmd substringFromIndex:5] integerValue];
        reply = [NSString stringWithFormat:@"OK\t%d", gDNBatchSend];
    } else if ([cmd hasPrefix:@"MTU"]) {
        
        
        NSInteger v = [[cmd substringFromIndex:3] integerValue];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if (v == 0) [ud removeObjectForKey:@"dante_mtu"];
        else [ud setInteger:v forKey:@"dante_mtu"];
        [ud synchronize];
        reply = [NSString stringWithFormat:@"OK\t%ld", (long)v];
    } else if ([cmd isEqualToString:@"PERF"]) {
        
        struct rusage ru;
        getrusage(RUSAGE_SELF, &ru);
        
        
        uint32_t udp[16] = {0};
        size_t udpLen = sizeof(udp);
        sysctlbyname("net.inet.udp.stats", udp, &udpLen, NULL, 0);
        
        extern volatile uint32_t gAWGRxOutOfOrder, gAWGRxDuplicate;
        
        
        NSMutableArray *threads = [NSMutableArray array];
        double sysTotal = 0;
        thread_act_array_t list = NULL;
        mach_msg_type_number_t count = 0;
        if (task_threads(mach_task_self(), &list, &count) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < count; i++) {
                thread_basic_info_data_t info;
                mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
                if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&info, &n) == KERN_SUCCESS) {
                    double u = info.user_time.seconds + info.user_time.microseconds / 1e6;
                    double sy = info.system_time.seconds + info.system_time.microseconds / 1e6;
                    sysTotal += sy;
                    if (u + sy >= 0.05) [threads addObject:@[@(u + sy), [NSString stringWithFormat:@"%.2f+%.2f", u, sy]]];
                }
                mach_port_deallocate(mach_task_self(), list[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_act_t));
        }
        [threads sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) {
            return [y[0] compare:x[0]];
        }];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSArray *t in threads) { [parts addObject:t[1]]; if (parts.count >= 6) break; }
        
        
        host_cpu_load_info_data_t load;
        mach_msg_type_number_t loadCount = HOST_CPU_LOAD_INFO_COUNT;
        unsigned cu = 0, cs = 0, ci = 0;
        mach_port_t host = mach_host_self();
        if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&load, &loadCount) == KERN_SUCCESS) {
            cu = load.cpu_ticks[CPU_STATE_USER] + load.cpu_ticks[CPU_STATE_NICE];
            cs = load.cpu_ticks[CPU_STATE_SYSTEM];
            ci = load.cpu_ticks[CPU_STATE_IDLE];
        }
        mach_port_deallocate(mach_task_self(), host);
        
        extern volatile uint32_t gDNUtunWritten, gDNUtunRetried, gDNUtunDropped;
        
        extern volatile uint32_t gAWGTxSent, gAWGTxRetried, gAWGTxDropped;
        reply = [NSString stringWithFormat:@"OK\t%.3f\t%.3f\t%u\t%u\t%u\t%@\t%u/%u/%u\t%u/%u/%u\t%u/%u/%u",
                 ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6, sysTotal, udp[6],
                 gAWGRxOutOfOrder, gAWGRxDuplicate, [parts componentsJoinedByString:@" "],
                 cu, cs, ci,
                 gDNUtunWritten, gDNUtunRetried, gDNUtunDropped,
                 gAWGTxSent, gAWGTxRetried, gAWGTxDropped];
    } else if ([cmd hasPrefix:@"RWND"]) {
        
        extern volatile uint32_t gAWGRecvWindow;
        NSInteger kb = [[cmd substringFromIndex:4] integerValue];
        if (kb >= 64 && kb <= 8192) gAWGRecvWindow = (uint32_t)kb * 1024;
        reply = [NSString stringWithFormat:@"OK\t%u", gAWGRecvWindow / 1024];
    } else if ([cmd isEqualToString:@"DCSCAN"]) {
        __block NSString *r;
        dispatch_sync(dispatch_get_main_queue(), ^{ r = [self commandDCScan]; });
        reply = r;
    } else if ([cmd isEqualToString:@"DCLIST"]) {
        __block NSString *r;
        dispatch_sync(dispatch_get_main_queue(), ^{ r = [self commandDCList]; });
        reply = r;
    } else if ([cmd hasPrefix:@"MSS"]) {
        
        NSString *arg = [[cmd substringFromIndex:3] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
        if (arg.length) [DanteUtun sharedUtun].clampMSS = (NSUInteger)[arg integerValue];
        reply = [NSString stringWithFormat:@"OK\t%lu", (unsigned long)[DanteUtun sharedUtun].clampMSS];
    } else if ([cmd isEqualToString:@"DCAUTO"]) {
        __block NSString *r;
        dispatch_sync(dispatch_get_main_queue(), ^{ r = [self commandDCAuto]; });
        reply = r;
    } else if ([cmd hasPrefix:@"DCSET "]) {
        NSString *endpoint = [[cmd substringFromIndex:6] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
        __block NSString *r;
        dispatch_sync(dispatch_get_main_queue(), ^{ r = [self commandDCSet:endpoint]; });
        reply = r;
    } else if ([cmd isEqualToString:@"LOG"]) {
        reply = DConText();
    } else if ([cmd hasPrefix:@"DEBUGLOG"]) {
        
        BOOL on = [[cmd substringFromIndex:8] integerValue] != 0;
        DebugLogSetForced(on);
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"dante_debuglog"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        reply = [NSString stringWithFormat:@"OK\t%d", on];
    } else {
        reply = @"ERR unknown command";
    }
    NSData *out = [[reply stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = out.bytes;
    size_t left = out.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n <= 0) break;
        p += n;
        left -= (size_t)n;
    }
    close(fd);
}

@end
