

#import <Foundation/Foundation.h>

@class PowerConfig;

typedef NS_ENUM(NSInteger, DanteFixerState) {
    DanteFixerStateIdle = 0,
    DanteFixerStateRunning,
    DanteFixerStateFixed,
    DanteFixerStateFailed
};

extern NSString * const kDanteFixerDidUpdateNotification;

@interface DanteFixer : NSObject

@property (nonatomic, readonly) BOOL restrictedNetwork;

+ (instancetype)sharedFixer;

@property (nonatomic, readonly) DanteFixerState state;
@property (nonatomic, readonly, copy) NSString *statusLine;
@property (nonatomic, readonly, copy) NSString *logText;

@property (nonatomic, readonly, copy) NSString *proxyAddress;
@property (nonatomic, readonly) BOOL whitelistMode;

@property (nonatomic, readonly) PowerConfig *powerConfig;

- (void)useServer:(PowerConfig *)config;

- (void)fixInternet;

- (void)fixWithFreshIdentity;
- (void)cancel;

- (void)stop;

- (void)markBroken:(NSString *)reason;

@end
