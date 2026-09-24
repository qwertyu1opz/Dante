

#import <Foundation/Foundation.h>

void DLog(NSString *format, ...);

#if DANTE_VERBOSE_LOG
#define DLogVerbose(...) DLog(__VA_ARGS__)
#else
#define DLogVerbose(...) do { } while (0)
#endif

void DebugLogInit(void);

void DebugLogInitWithPath(NSString *path);

NSString *DebugLogPath(void);

NSString *DebugLogContents(void);

void WriteCrashReport(NSException *exception);

void DebugLogSetGated(BOOL gated);

BOOL DebugLogUIPing(void);
BOOL DebugLogActive(void);

void DebugLogSetForced(BOOL forced);
BOOL DebugLogForced(void);

void DCon(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *DConText(void);
