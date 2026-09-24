

#import <Foundation/Foundation.h>

@class AWGConfig;

extern NSString * const kAWGWarpErrorDomain;

@interface AWGWarpRegistrar : NSObject

+ (void)generateConfigWithCompletion:(void(^)(AWGConfig *config, NSError *error))completion;

+ (void)generateConfigWithPrivateKey:(NSString *)privateKeyBase64
                          completion:(void(^)(AWGConfig *config, NSError *error))completion;

+ (AWGConfig *)bundledSeedConfig;

+ (NSString *)randomWarpEndpoint;

+ (NSArray *)warpPrefixes;

+ (void)rotateEndpointForConfig:(AWGConfig *)config;

+ (void)applyWarpObfuscationProfile:(AWGConfig *)config;

@end
