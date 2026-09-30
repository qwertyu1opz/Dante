
#import <Foundation/Foundation.h>

extern NSString * const kDanteCurlErrorDomain;

@interface DanteCurl : NSObject

// YES when bundled roots are loaded; without them HTTPS requests are refused.
+ (BOOL)isReady;

// Returns the body of any HTTP response (check *outStatus), or nil with an error
// when no response arrived. socksPort 0 connects directly (optionally to connectIP).
+ (NSData *)requestURL:(NSString *)url
                method:(NSString *)method
               headers:(NSDictionary *)headers
                  body:(NSData *)body
             socksPort:(uint16_t)socksPort
             connectIP:(NSString *)connectIP
               timeout:(NSTimeInterval)timeout
            statusCode:(NSInteger *)outStatus
                 error:(NSError **)error;

@end
