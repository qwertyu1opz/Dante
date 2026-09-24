

#import "DanteSystemProxy.h"
#import "DebugLog.h"

#import <Foundation/Foundation.h>
#import <notify.h>
#include <dlfcn.h>

static NSString * const kPreferencesPath = @"/Library/Preferences/SystemConfiguration/preferences.plist";

typedef const void * SCDynamicStoreRef;

static SCDynamicStoreRef DanteDynamicStoreCreate(CFAllocatorRef allocator, CFStringRef name) {
    static SCDynamicStoreRef (*fn)(CFAllocatorRef, CFStringRef, void *, void *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (SCDynamicStoreRef (*)(CFAllocatorRef, CFStringRef, void *, void *))dlsym(RTLD_DEFAULT, "SCDynamicStoreCreate");
    });
    return fn ? fn(allocator, name, NULL, NULL) : NULL;
}

static BOOL DanteDynamicStoreSetValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value) {
    static Boolean (*fn)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (Boolean (*)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef))dlsym(RTLD_DEFAULT, "SCDynamicStoreSetValue");
    });
    return fn ? (BOOL)fn(store, key, value) : NO;
}

static BOOL DanteDynamicStoreNotifyValue(SCDynamicStoreRef store, CFStringRef key) {
    static Boolean (*fn)(SCDynamicStoreRef, CFStringRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (Boolean (*)(SCDynamicStoreRef, CFStringRef))dlsym(RTLD_DEFAULT, "SCDynamicStoreNotifyValue");
    });
    return fn ? (BOOL)fn(store, key) : NO;
}

static CFPropertyListRef DanteDynamicStoreCopyValue(SCDynamicStoreRef store, CFStringRef key) {
    static CFPropertyListRef (*fn)(SCDynamicStoreRef, CFStringRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (CFPropertyListRef (*)(SCDynamicStoreRef, CFStringRef))dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyValue");
    });
    return fn ? fn(store, key) : NULL;
}

@implementation DanteSystemProxy

static NSArray *DanteProxyExceptions(void) {
    return @[@"127.0.0.1", @"localhost", @"*.local", @"169.254/16",
             @"10.0.0.0/8", @"172.16.0.0/12", @"192.168.0.0/16"];
}

static NSArray *DanteFindWiFiServiceIDs(NSDictionary *plist) {
    NSMutableArray *ids = [NSMutableArray array];
    NSDictionary *allServices = [plist objectForKey:@"NetworkServices"];
    for (NSString *sID in allServices) {
        NSDictionary *sInfo = [allServices objectForKey:sID];
        NSString *name = [sInfo objectForKey:@"UserDefinedName"];
        NSString *dev = [[sInfo objectForKey:@"Interface"] objectForKey:@"DeviceName"];
        BOOL isWiFi = [name isEqualToString:@"Wi-Fi"] || [dev isEqualToString:@"en0"] || [sInfo objectForKey:@"Proxies"] != nil;
        if (isWiFi) {
            [ids addObject:sID];
        }
    }
    return ids;
}

+ (BOOL)enableProxyOnPort:(uint16_t)port error:(NSString **)error {
    NSMutableDictionary *pl = [NSMutableDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    if (!pl) {
        if (error) *error = @"не удалось прочитать preferences.plist";
        return NO;
    }
    NSMutableDictionary *services = [[pl objectForKey:@"NetworkServices"] mutableCopy];
    if (!services) {
        if (error) *error = @"нет NetworkServices в preferences.plist";
        return NO;
    }
    NSArray *wifiIDs = DanteFindWiFiServiceIDs(pl);
    for (NSString *sID in wifiIDs) {
        NSMutableDictionary *sInfo = [[services objectForKey:sID] mutableCopy];
        if (!sInfo) continue;
        NSMutableDictionary *proxies = [[sInfo objectForKey:@"Proxies"] mutableCopy] ?: [NSMutableDictionary dictionary];
        [proxies setObject:@1 forKey:@"HTTPEnable"];
        [proxies setObject:@(port) forKey:@"HTTPPort"];
        [proxies setObject:@"127.0.0.1" forKey:@"HTTPProxy"];
        [proxies setObject:@1 forKey:@"HTTPProxyType"];
        [proxies setObject:@1 forKey:@"HTTPSEnable"];
        [proxies setObject:@(port) forKey:@"HTTPSPort"];
        [proxies setObject:@"127.0.0.1" forKey:@"HTTPSProxy"];
        [proxies setObject:@0 forKey:@"ProxyAutoConfigEnable"];
        [proxies setObject:DanteProxyExceptions() forKey:@"ExceptionsList"];
        [proxies setObject:@1 forKey:@"ExcludeSimpleHostnames"];
        [sInfo setObject:proxies forKey:@"Proxies"];
        [services setObject:sInfo forKey:sID];
    }
    [pl setObject:services forKey:@"NetworkServices"];
    if (![pl writeToFile:kPreferencesPath atomically:YES]) {
        if (error) *error = @"не удалось записать preferences.plist";
        return NO;
    }

    
    SCDynamicStoreRef store = DanteDynamicStoreCreate(kCFAllocatorDefault, CFSTR("DanteSystemProxy"));
    if (store) {
        NSDictionary *scopedEn0 = @{
            @"HTTPEnable": @1,
            @"HTTPPort": @(port),
            @"HTTPProxy": @"127.0.0.1",
            @"HTTPProxyType": @1,
            @"HTTPSEnable": @1,
            @"HTTPSPort": @(port),
            @"HTTPSProxy": @"127.0.0.1",
            @"ProxyAutoConfigEnable": @0,
            @"ExceptionsList": DanteProxyExceptions(),
            @"ExcludeSimpleHostnames": @1
        };
        NSDictionary *globalDict = @{
            @"HTTPEnable": @1,
            @"HTTPPort": @(port),
            @"HTTPProxy": @"127.0.0.1",
            @"HTTPProxyType": @1,
            @"HTTPSEnable": @1,
            @"HTTPSPort": @(port),
            @"HTTPSProxy": @"127.0.0.1",
            @"ProxyAutoConfigEnable": @0,
            @"ExceptionsList": DanteProxyExceptions(),
            @"ExcludeSimpleHostnames": @1,
            @"__SCOPED__": @{ @"en0": scopedEn0 }
        };
        DanteDynamicStoreSetValue(store, CFSTR("State:/Network/Global/Proxies"), (__bridge CFPropertyListRef)globalDict);
        DanteDynamicStoreNotifyValue(store, CFSTR("State:/Network/Global/Proxies"));
        for (NSString *sID in wifiIDs) {
            NSString *key = [NSString stringWithFormat:@"Setup:/Network/Service/%@/Proxies", sID];
            DanteDynamicStoreSetValue(store, (__bridge CFStringRef)key, (__bridge CFPropertyListRef)scopedEn0);
            DanteDynamicStoreNotifyValue(store, (__bridge CFStringRef)key);
        }
        CFRelease(store);
    }
    notify_post("com.apple.system.config.network_change");
    DLog(@"[system-proxy] включён прокси 127.0.0.1:%u", port);
    return YES;
}

+ (BOOL)disableProxyWithError:(NSString **)error {
    NSMutableDictionary *pl = [NSMutableDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    if (pl) {
        NSMutableDictionary *services = [[pl objectForKey:@"NetworkServices"] mutableCopy];
        if (services) {
            NSArray *wifiIDs = DanteFindWiFiServiceIDs(pl);
            for (NSString *sID in wifiIDs) {
                NSMutableDictionary *sInfo = [[services objectForKey:sID] mutableCopy];
                if (!sInfo) continue;
                NSMutableDictionary *proxies = [[sInfo objectForKey:@"Proxies"] mutableCopy];
                if (proxies) {
                    [proxies setObject:@0 forKey:@"HTTPEnable"];
                    [proxies setObject:@0 forKey:@"HTTPSEnable"];
                    [sInfo setObject:proxies forKey:@"Proxies"];
                    [services setObject:sInfo forKey:sID];
                }
            }
            [pl setObject:services forKey:@"NetworkServices"];
            [pl writeToFile:kPreferencesPath atomically:YES];
        }
    }

    SCDynamicStoreRef store = DanteDynamicStoreCreate(kCFAllocatorDefault, CFSTR("DanteSystemProxy"));
    if (store) {
        NSDictionary *disabledDict = @{
            @"HTTPEnable": @0,
            @"HTTPSEnable": @0,
            @"ProxyAutoConfigEnable": @0,
            @"__SCOPED__": @{
                @"en0": @{
                    @"HTTPEnable": @0,
                    @"HTTPSEnable": @0,
                    @"ProxyAutoConfigEnable": @0
                }
            }
        };
        DanteDynamicStoreSetValue(store, CFSTR("State:/Network/Global/Proxies"), (__bridge CFPropertyListRef)disabledDict);
        DanteDynamicStoreNotifyValue(store, CFSTR("State:/Network/Global/Proxies"));
        CFRelease(store);
    }
    notify_post("com.apple.system.config.network_change");
    DLog(@"[system-proxy] выключен прокси");
    return YES;
}

+ (BOOL)isProxyEnabled {
    SCDynamicStoreRef store = DanteDynamicStoreCreate(kCFAllocatorDefault, CFSTR("DanteSystemProxy"));
    if (store) {
        CFDictionaryRef dict = DanteDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/Proxies"));
        CFRelease(store);
        if (dict) {
            NSDictionary *d = (__bridge_transfer NSDictionary *)dict;
            return [[d objectForKey:@"HTTPEnable"] boolValue];
        }
    }
    return NO;
}

@end
