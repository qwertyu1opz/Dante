

#import "DebugLog.h"
#import <UIKit/UIKit.h>

static NSFileHandle *gLogFileHandle = nil;
static NSDateFormatter *gLogDateFormatter = nil;

static void BootMarker(const char *msg) {
    FILE *f = fopen("/tmp/dante_boot.log", "a");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
}

static void DanteUncaughtExceptionHandler(NSException *exception) {
    FILE *f = fopen("/tmp/dante_boot.log", "a");
    if (f) {
        fprintf(f, "UNCAUGHT EXCEPTION: %s: %s\n",
                [[exception name] UTF8String], [[exception reason] UTF8String]);
        fclose(f);
    }
    WriteCrashReport(exception);
}

static NSString *gLogPath = @"/tmp/dante_debug.log";

void DebugLogInit(void) {
    DebugLogInitWithPath(@"/tmp/dante_debug.log");
}

void DebugLogInitWithPath(NSString *path) {
    gLogPath = [path copy];
    BootMarker("DebugLogInit: begin");
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = [paths objectAtIndex:0];
    [[NSFileManager defaultManager] createDirectoryAtPath:docsDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *logPath = [docsDir stringByAppendingPathComponent:@"debug.log"];
    BootMarker([[NSString stringWithFormat:@"DebugLogInit: docs=%@", docsDir] UTF8String]);

    
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
    BOOL okDocs = [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:nil];
    BOOL okTmp = [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
    BootMarker([[NSString stringWithFormat:@"DebugLogInit: createDocs=%d createTmp=%d", okDocs, okTmp] UTF8String]);

    gLogFileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!gLogFileHandle) {
        gLogFileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    BootMarker(gLogFileHandle ? "DebugLogInit: handle OK" : "DebugLogInit: handle NIL");
    NSSetUncaughtExceptionHandler(&DanteUncaughtExceptionHandler);

    gLogDateFormatter = [[NSDateFormatter alloc] init];
    [gLogDateFormatter setDateFormat:@"HH:mm:ss.SSS"];

    DLog(@"=== Dante Debug Log Started ===");
    DLog(@"Device: %@ %@", [[UIDevice currentDevice] systemName], [[UIDevice currentDevice] systemVersion]);
    DLog(@"Model: %@", [[UIDevice currentDevice] model]);
    DLog(@"Documents dir: %@", docsDir);
}

NSString *DebugLogPath(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:gLogPath]) {
        return gLogPath;
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"debug.log"];
}

NSString *DebugLogContents(void) {
    NSString *path = DebugLogPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return @"(no log data)";
}

void WriteCrashReport(NSException *exception) {
    NSString *path = DebugLogPath();
    NSMutableString *crash = [NSMutableString string];
    [crash appendString:@"\n\n========== CRASH REPORT ==========\n"];
    [crash appendFormat:@"Name: %@\n", [exception name]];
    [crash appendFormat:@"Reason: %@\n", [exception reason]];
    NSString *symbols = [exception callStackSymbols] ? [[exception callStackSymbols] componentsJoinedByString:@"\n"] : @"(no symbols)";
    [crash appendFormat:@"Symbols: %@\n", symbols];
    [crash appendString:@"==================================\n"];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[crash dataUsingEncoding:NSUTF8StringEncoding]];
        [fh synchronizeFile];
        [fh closeFile];
    }
}

#pragma mark - Запись только при открытом приложении

static volatile BOOL gGated = NO;
static volatile BOOL gForced = NO;
static volatile CFAbsoluteTime gActiveUntil = 0;
static const CFAbsoluteTime kUIGrace = 6.0;

static CFAbsoluteTime gConsoleEpoch;

void DebugLogSetGated(BOOL gated) {
    gGated = gated;
    if (!gConsoleEpoch) gConsoleEpoch = CFAbsoluteTimeGetCurrent();   
}
void DebugLogSetForced(BOOL forced) { gForced = forced; }
BOOL DebugLogForced(void) { return gForced; }

BOOL DebugLogActive(void) {
    return !gGated || gForced || CFAbsoluteTimeGetCurrent() < gActiveUntil;
}

BOOL DebugLogUIPing(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL wasAway = now >= gActiveUntil;
    gActiveUntil = now + kUIGrace;
    return wasAway;
}

#pragma mark - Консоль

static NSMutableArray *gConsole;
static const NSUInteger kConsoleLines = 64;

void DCon(NSString *format, ...) {
    if (gGated && CFAbsoluteTimeGetCurrent() >= gActiveUntil) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    @synchronized ([NSProcessInfo processInfo]) {
        if (!gConsole) gConsole = [[NSMutableArray alloc] init];
        if (!gConsoleEpoch) gConsoleEpoch = CFAbsoluteTimeGetCurrent();
        
        [gConsole addObject:[NSString stringWithFormat:@"[%9.3f] %@",
                             CFAbsoluteTimeGetCurrent() - gConsoleEpoch, message]];
        if (gConsole.count > kConsoleLines) {
            [gConsole removeObjectsInRange:NSMakeRange(0, gConsole.count - kConsoleLines)];
        }
    }
    if (gForced) DLog(@"[con] %@", message);
}

NSString *DConText(void) {
    @synchronized ([NSProcessInfo processInfo]) {
        return gConsole.count ? [gConsole componentsJoinedByString:@"\n"] : @"";
    }
}

void DLog(NSString *format, ...) {
    if (!DebugLogActive()) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    
    
    
    if (!gLogFileHandle) NSLog(@"[YT] %@", message);

    
    if (gLogFileHandle && gLogDateFormatter) {
        NSString *timestamp = [gLogDateFormatter stringFromDate:[NSDate date]];
        NSString *logLine = [NSString stringWithFormat:@"%@ %@\n", timestamp, message];
        @synchronized(gLogFileHandle) {
            @try {
                
                
                unsigned long long end = [gLogFileHandle seekToEndOfFile];
                if (end > 4ull * 1024 * 1024) {
                    [gLogFileHandle truncateFileAtOffset:0];
                    [gLogFileHandle writeData:[@"(журнал превысил 4 МБ — начат заново)\n"
                                               dataUsingEncoding:NSUTF8StringEncoding]];
                }
                [gLogFileHandle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
            }
            @catch (NSException *e) {
                
            }
        }
    }
}
