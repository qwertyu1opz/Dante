

#import "AppDelegate.h"
#import "DanteViewController.h"
#import "DanteControl.h"
#import "DebugLog.h"
#import <objc/message.h>

CGImageRef UIGetScreenImage(void);

@implementation AppDelegate {
    BOOL _autoFixScheduled;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    DebugLogInitWithPath(@"/tmp/dante_app.log");
    DLog(@"Dante запущен");

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [[DanteViewController alloc] init];
    [self.window makeKeyAndVisible];

    NSURL *url = [launchOptions objectForKey:UIApplicationLaunchOptionsURLKey];
    if ([self isFixURL:url]) {
        [self handleURL:url];
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/dante_autorun"]) {
        DLog(@"Обнаружен /tmp/dante_autorun — автозапуск починки");
        [self scheduleAutoFix];
    }
    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    if ([self isFixURL:url]) {
        [self handleURL:url];
        return YES;
    }
    return NO;
}

- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url {
    if ([self isFixURL:url]) {
        [self handleURL:url];
        return YES;
    }
    return NO;
}

- (BOOL)isFixURL:(NSURL *)url {
    if (![[url scheme] isEqualToString:@"dante"]) return NO;
    DLog(@"Открыт URL: %@", url);
    return YES;
}

- (void)handleURL:(NSURL *)url {
    
    
    if ([[url host] isEqualToString:@"shot"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CGImageRef shot = UIGetScreenImage();
            if (!shot) return;
            [UIImagePNGRepresentation([UIImage imageWithCGImage:shot])
                writeToFile:@"/tmp/dante_shot.png" atomically:YES];
            CGImageRelease(shot);
        });
        return;
    }
    if ([[url host] isEqualToString:@"rotate"]) {
        NSInteger o = [[[url query] stringByReplacingOccurrencesOfString:@"o=" withString:@""] integerValue];
        if (o >= 1 && o <= 4) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)([UIDevice currentDevice],
                                                         NSSelectorFromString(@"setOrientation:"), o);
        }
        return;
    }
    if ([[url host] isEqualToString:@"countries"]) {
        UIViewController *root = self.window.rootViewController;
        if ([root respondsToSelector:@selector(showCountries)]) [(id)root showCountries];
        return;
    }
    if ([[url host] isEqualToString:@"stop"]) {
        [self sendToDaemon:@"STOP"];
    } else if ([[url host] isEqualToString:@"fix"]) {
        [self scheduleAutoFix];
    }
}

- (void)scheduleAutoFix {
    if (_autoFixScheduled) return;
    _autoFixScheduled = YES;
    DLog(@"Автозапуск починки");
    [self sendToDaemon:@"FIX"];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ self->_autoFixScheduled = NO; });
}

- (void)sendToDaemon:(NSString *)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *reply = DanteControlSend(command, 5.0);
        DLog(@"Служба: %@ -> %@", command, reply ?: @"не отвечает");
    });
}

@end
