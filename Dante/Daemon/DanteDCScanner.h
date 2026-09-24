

#import <Foundation/Foundation.h>

@interface DanteDCResult : NSObject
@property (nonatomic, copy) NSString *endpoint;   
@property (nonatomic, copy) NSString *colo;       
@property (nonatomic, assign) NSUInteger ms;      
@end

@interface DanteDCScanner : NSObject

+ (instancetype)sharedScanner;

@property (nonatomic, readonly) BOOL scanning;
@property (nonatomic, readonly) NSUInteger done;
@property (nonatomic, readonly) NSUInteger total;

@property (nonatomic, readonly, copy) NSString *targetColo;

@property (nonatomic, readonly) NSArray *results;

@property (nonatomic, assign) BOOL autoMode;

- (BOOL)scan;

- (NSString *)findEndpointForColo:(NSString *)colo;

- (NSString *)autoEndpointAfter:(NSString *)after;

- (DanteDCResult *)resultForEndpoint:(NSString *)endpoint;

+ (NSString *)cityForColo:(NSString *)colo;

+ (NSString *)countryForColo:(NSString *)colo;

@end
