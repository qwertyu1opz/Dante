

#import "DanteDCScanner.h"
#import "AmneziaWGManager.h"
#import "AWGConfig.h"
#import "AWGTunnel.h"
#import "AWGWarpRegistrar.h"
#import "DanteNetworkProbe.h"
#import "DebugLog.h"

@implementation DanteDCResult
@end

static NSString * const kDCResultsKey = @"dante_dc_results";
static NSString * const kDCManualKey  = @"dante_dc_manual";   

static NSArray *DCSeedHosts(void) {
    return @[ @[@"188.114.99.1", @"DME"], @[@"8.35.211.1", @"DME"], @[@"8.34.70.1", @"DME"],
              @[@"188.114.97.1", @"HEL"], @[@"8.39.125.1", @"HEL"],
              @[@"162.159.192.1", @"ARN"], @[@"8.47.69.1", @"ARN"] ];
}

static NSString *DCTraceField(NSString *trace, NSString *key) {
    for (NSString *line in [trace componentsSeparatedByString:@"\n"]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([l hasPrefix:[key stringByAppendingString:@"="]]) return [l substringFromIndex:key.length + 1];
    }
    return nil;
}

static NSString *DCCurrentPort(void) {
    NSString *current = [AmneziaWGManager sharedManager].currentConfig.peerEndpoint ?: @"";
    NSRange colon = [current rangeOfString:@":" options:NSBackwardsSearch];
    return colon.location != NSNotFound ? [current substringFromIndex:colon.location + 1] : @"2408";
}

@implementation DanteDCScanner {
    NSMutableArray *_known;   
}

+ (instancetype)sharedScanner {
    static DanteDCScanner *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DanteDCScanner alloc] init]; });
    return s;
}

#pragma mark - Режим

- (BOOL)autoMode {
    return ![[NSUserDefaults standardUserDefaults] boolForKey:kDCManualKey];
}

- (void)setAutoMode:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:!on forKey:kDCManualKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Известные адреса

- (NSMutableArray *)knownLocked {
    if (_known) return _known;
    _known = [NSMutableArray array];
    for (NSDictionary *d in [[NSUserDefaults standardUserDefaults] arrayForKey:kDCResultsKey]) {
        DanteDCResult *r = [[DanteDCResult alloc] init];
        r.endpoint = [d objectForKey:@"endpoint"];
        r.colo = [d objectForKey:@"colo"];
        r.ms = [[d objectForKey:@"ms"] unsignedIntegerValue];
        if (r.endpoint.length && r.colo.length) [_known addObject:r];
    }
    NSString *port = DCCurrentPort();
    for (NSArray *e in DCSeedHosts()) {
        NSString *host = [[e objectAtIndex:0] stringByAppendingString:@":"];
        BOOL have = NO;
        for (DanteDCResult *r in _known) if ([r.endpoint hasPrefix:host]) have = YES;
        if (have) continue;
        DanteDCResult *r = [[DanteDCResult alloc] init];
        r.endpoint = [host stringByAppendingString:port];
        r.colo = [e objectAtIndex:1];
        [_known addObject:r];
    }
    return _known;
}

static NSComparisonResult DCCompare(DanteDCResult *a, DanteDCResult *b) {
    NSComparisonResult c = [[DanteDCScanner countryForColo:a.colo] compare:[DanteDCScanner countryForColo:b.colo]];
    if (c != NSOrderedSame) return c;
    
    NSUInteger am = a.ms ?: NSUIntegerMax, bm = b.ms ?: NSUIntegerMax;
    if (am != bm) return am < bm ? NSOrderedAscending : NSOrderedDescending;
    return [a.endpoint compare:b.endpoint];
}

- (NSArray *)results {
    @synchronized (self) {
        return [[self knownLocked] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return DCCompare(a, b);
        }];
    }
}

- (DanteDCResult *)resultForEndpoint:(NSString *)endpoint {
    @synchronized (self) {
        for (DanteDCResult *r in [self knownLocked]) {
            if ([r.endpoint isEqualToString:endpoint]) return r;
        }
    }
    return nil;
}

- (void)recordEndpoint:(NSString *)endpoint colo:(NSString *)colo ms:(NSUInteger)ms {
    NSMutableArray *known = [self knownLocked];
    for (NSUInteger i = 0; i < known.count; i++) {
        if ([[[known objectAtIndex:i] endpoint] isEqualToString:endpoint]) {
            [known removeObjectAtIndex:i];
            break;
        }
    }
    if (!colo) return;
    DanteDCResult *r = [[DanteDCResult alloc] init];
    r.endpoint = endpoint;
    r.colo = colo;
    r.ms = ms;
    [known addObject:r];
}

- (void)saveResults {
    NSMutableArray *save = [NSMutableArray array];
    for (DanteDCResult *r in self.results) {
        [save addObject:@{ @"endpoint": r.endpoint, @"colo": r.colo, @"ms": @(r.ms) }];
    }
    [[NSUserDefaults standardUserDefaults] setObject:save forKey:kDCResultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)autoEndpointAfter:(NSString *)after {
    NSArray *byMs = [self.results sortedArrayUsingComparator:^NSComparisonResult(DanteDCResult *a, DanteDCResult *b) {
        NSUInteger am = a.ms ?: NSUIntegerMax, bm = b.ms ?: NSUIntegerMax;
        if (am == bm) return NSOrderedSame;
        return am < bm ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (byMs.count == 0) return nil;
    if (after) {
        for (NSUInteger i = 0; i < byMs.count; i++) {
            if ([[[byMs objectAtIndex:i] endpoint] isEqualToString:after]) {
                return [[byMs objectAtIndex:(i + 1) % byMs.count] endpoint];
            }
        }
    }
    return [[byMs objectAtIndex:0] endpoint];
}

#pragma mark - Проверка

- (NSString *)probeEndpoint:(NSString *)endpoint archived:(NSData *)archived ms:(NSUInteger *)msOut {
    AWGConfig *cfg = [NSKeyedUnarchiver unarchiveObjectWithData:archived];
    cfg.peerEndpoint = endpoint;
    cfg.preferredPorts = nil;   

    AWGTunnel *tunnel = [[AWGTunnel alloc] initWithConfig:cfg];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL up = NO;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    __block NSTimeInterval t1 = 0;
    [tunnel startWithCompletion:^(BOOL success, NSError *error) {
        up = success;
        t1 = [NSDate timeIntervalSinceReferenceDate];
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC));
    dispatch_release(sem);

    NSString *colo = nil;
    if (up) {
        if (msOut) *msOut = (NSUInteger)((t1 - t0) * 1000.0);
        colo = DCTraceField([DanteNetworkProbe traceOnSOCKSPort:tunnel.socksPort timeout:5.0], @"colo");
    }
    [tunnel stop];
    DLog(@"[dc] %@ -> %@", endpoint, colo.length ? colo : @"нет ответа");
    return colo.length ? colo : nil;
}

- (void)beginWithTotal:(NSUInteger)total target:(NSString *)colo {
    @synchronized (self) {
        _scanning = YES;
        _targetColo = [colo copy];
        _done = 0;
        _total = total;
    }
}

- (void)finish {
    @synchronized (self) {
        _scanning = NO;
        _targetColo = nil;
    }
    [self saveResults];
}

- (BOOL)scan {
    AWGConfig *base = [AmneziaWGManager sharedManager].currentConfig;
    if (!base) return NO;
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:base];
    NSString *port = DCCurrentPort();

    
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *prefix in [AWGWarpRegistrar warpPrefixes]) {
        for (NSString *host in @[@"1", @"7"]) {
            [candidates addObject:[NSString stringWithFormat:@"%@.%@:%@", prefix, host, port]];
        }
    }
    for (DanteDCResult *r in self.results) {
        if (![candidates containsObject:r.endpoint]) [candidates addObject:r.endpoint];
    }
    [self beginWithTotal:candidates.count target:nil];
    DLog(@"[dc] проверяю %lu адресов WARP (порт %@)", (unsigned long)candidates.count, port);

    for (NSString *ep in candidates) {
        @autoreleasepool {
            NSUInteger ms = 0;
            NSString *colo = [self probeEndpoint:ep archived:archived ms:&ms];
            @synchronized (self) {
                [self recordEndpoint:ep colo:colo ms:ms];
                _done++;
            }
        }
    }
    [self finish];
    DLog(@"[dc] готово: %lu рабочих адресов", (unsigned long)self.results.count);
    return YES;
}

- (NSString *)findEndpointForColo:(NSString *)colo {
    AWGConfig *base = [AmneziaWGManager sharedManager].currentConfig;
    if (!base || colo.length == 0) return nil;
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:base];
    NSString *port = DCCurrentPort();

    NSMutableArray *candidates = [NSMutableArray array];
    for (DanteDCResult *r in self.results) {
        if ([r.colo isEqualToString:colo]) [candidates addObject:r.endpoint];
    }
    for (NSString *prefix in [AWGWarpRegistrar warpPrefixes]) {
        NSString *ep = [NSString stringWithFormat:@"%@.1:%@", prefix, port];
        if (![candidates containsObject:ep]) [candidates addObject:ep];
    }
    [self beginWithTotal:candidates.count target:colo];
    DLog(@"[dc] ищу выход через %@ (%@)", [DanteDCScanner countryForColo:colo], colo);
    NSString *found = nil;
    for (NSString *ep in candidates) {
        @autoreleasepool {
            NSUInteger ms = 0;
            NSString *got = [self probeEndpoint:ep archived:archived ms:&ms];
            @synchronized (self) {
                [self recordEndpoint:ep colo:got ms:ms];
                _done++;
            }
            if ([got isEqualToString:colo]) { found = ep; break; }
        }
    }
    [self finish];
    return found;
}

#pragma mark - Названия

+ (NSString *)countryForColo:(NSString *)colo {
    static NSDictionary *countries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        countries = @{
            @"DME": @"Россия", @"SVO": @"Россия", @"VKO": @"Россия", @"LED": @"Россия",
            @"KJA": @"Россия", @"SVX": @"Россия", @"KZN": @"Россия", @"OVB": @"Россия",
            @"KHV": @"Россия", @"VVO": @"Россия",
            @"ARN": @"Швеция", @"HEL": @"Финляндия", @"OSL": @"Норвегия", @"CPH": @"Дания",
            @"RIX": @"Латвия", @"TLL": @"Эстония", @"VNO": @"Литва", @"WAW": @"Польша",
            @"KBP": @"Украина", @"OTP": @"Румыния", @"SOF": @"Болгария", @"BUD": @"Венгрия",
            @"VIE": @"Австрия", @"PRG": @"Чехия", @"FRA": @"Германия", @"MUC": @"Германия",
            @"DUS": @"Германия", @"HAM": @"Германия", @"TXL": @"Германия", @"BER": @"Германия",
            @"AMS": @"Нидерланды", @"BRU": @"Бельгия", @"LHR": @"Великобритания",
            @"MAN": @"Великобритания", @"CDG": @"Франция", @"MRS": @"Франция",
            @"ZRH": @"Швейцария", @"GVA": @"Швейцария", @"MXP": @"Италия", @"FCO": @"Италия",
            @"MAD": @"Испания", @"BCN": @"Испания", @"LIS": @"Португалия", @"ATH": @"Греция",
            @"IST": @"Турция", @"TBS": @"Грузия", @"EVN": @"Армения", @"GYD": @"Азербайджан",
            @"ALA": @"Казахстан", @"NQZ": @"Казахстан", @"TAS": @"Узбекистан", @"DXB": @"ОАЭ",
            @"TLV": @"Израиль", @"SIN": @"Сингапур", @"HKG": @"Гонконг", @"NRT": @"Япония",
            @"ICN": @"Корея", @"BOM": @"Индия", @"EWR": @"США", @"IAD": @"США", @"ORD": @"США",
            @"DFW": @"США", @"LAX": @"США", @"SJC": @"США", @"SEA": @"США", @"MIA": @"США",
            @"YYZ": @"Канада",
        };
    });
    return [countries objectForKey:colo] ?: colo;
}
+ (NSString *)cityForColo:(NSString *)colo {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"DME": @"Москва", @"SVO": @"Москва", @"VKO": @"Москва", @"LED": @"Санкт-Петербург",
            @"KJA": @"Красноярск", @"SVX": @"Екатеринбург", @"KZN": @"Казань",
            @"OVB": @"Новосибирск", @"KHV": @"Хабаровск", @"VVO": @"Владивосток",
            @"ARN": @"Стокгольм", @"HEL": @"Хельсинки", @"OSL": @"Осло", @"CPH": @"Копенгаген",
            @"RIX": @"Рига", @"TLL": @"Таллин", @"VNO": @"Вильнюс", @"WAW": @"Варшава",
            @"KBP": @"Киев", @"OTP": @"Бухарест", @"SOF": @"София", @"BUD": @"Будапешт",
            @"VIE": @"Вена", @"PRG": @"Прага", @"FRA": @"Франкфурт", @"MUC": @"Мюнхен",
            @"DUS": @"Дюссельдорф", @"HAM": @"Гамбург", @"TXL": @"Берлин", @"BER": @"Берлин",
            @"AMS": @"Амстердам", @"BRU": @"Брюссель", @"LHR": @"Лондон", @"MAN": @"Манчестер",
            @"CDG": @"Париж", @"MRS": @"Марсель", @"ZRH": @"Цюрих", @"GVA": @"Женева",
            @"MXP": @"Милан", @"FCO": @"Рим", @"MAD": @"Мадрид", @"BCN": @"Барселона",
            @"LIS": @"Лиссабон", @"ATH": @"Афины", @"IST": @"Стамбул", @"TBS": @"Тбилиси",
            @"EVN": @"Ереван", @"GYD": @"Баку", @"ALA": @"Алматы", @"NQZ": @"Астана",
            @"TAS": @"Ташкент", @"DXB": @"Дубай", @"TLV": @"Тель-Авив", @"SIN": @"Сингапур",
            @"HKG": @"Гонконг", @"NRT": @"Токио", @"ICN": @"Сеул", @"BOM": @"Мумбаи",
            @"EWR": @"Нью-Йорк", @"IAD": @"Вашингтон", @"ORD": @"Чикаго", @"DFW": @"Даллас",
            @"LAX": @"Лос-Анджелес", @"SJC": @"Сан-Хосе", @"SEA": @"Сиэтл", @"MIA": @"Майами",
            @"YYZ": @"Торонто",
        };
    });
    return [names objectForKey:colo] ?: colo;
}

@end
