

#import "DanteViewController.h"
#import "DanteFixer.h"
#import "DanteControl.h"
#import "DanteSkin.h"
#import "DanteChrome.h"
#import "DanteJailbreakButton.h"
#import "DanteLCDView.h"
#import "DanteLogBackdrop.h"
#import "DanteDCViewController.h"
#import <QuartzCore/QuartzCore.h>
#include <spawn.h>

extern char **environ;

static BOOL DanteIsPhone(void) {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
}
static const NSInteger kAlertStop = 1;
static const NSInteger kAlertRegister = 2;

@interface DanteViewController () <UIAlertViewDelegate>
@end

@implementation DanteViewController {
    DanteLogBackdrop *_backdrop;
    UIView *_console;
    UILabel *_titleLabel;
    NSInteger _shownState;       
    BOOL _syncing;               
    NSString *_syncResult;       
    NSTimeInterval _syncResultUntil;
    UILabel *_taglineLabel;
    DanteJailbreakButton *_button;
    DanteLCDView *_lcd;
    DanteMetalButton *_registerButton;

    NSTimer *_pollTimer;
    BOOL _polling;
    int _missedPolls;
    NSTimeInterval _lastKick;
    NSInteger _daemonState;   
}

- (void)dealloc {
    [_pollTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Вид

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    root.backgroundColor = [UIColor blackColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;

    _backdrop = [[DanteLogBackdrop alloc] initWithFrame:root.bounds];
    _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:_backdrop];

    
    
    
    BOOL phone = DanteIsPhone();
    CGFloat kConsoleWidth = phone ? 340 : 520;
    CGFloat kButtonSide = phone ? 250 : 330;
    CGFloat headerH = phone ? 80 : 108;
    CGFloat gap = phone ? 8 : 12;
    CGFloat lcdH = [DanteLCDView preferredHeight];
    CGFloat consoleH = headerH + kButtonSide + gap + lcdH + gap + 52;
    _console = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kConsoleWidth, consoleH)];
    _console.backgroundColor = [UIColor clearColor];
    [root addSubview:_console];

    
    CGFloat titleSize = phone ? 40 : 50;
    UIColor *phosphor = DanteHex(0x3dff6e, 1);
    _titleLabel = [[UILabel alloc] initWithFrame:
                   CGRectMake(0, phone ? 4 : 10, kConsoleWidth, titleSize + 6)];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont fontWithName:@"Courier-Bold" size:titleSize]
                    ?: [UIFont boldSystemFontOfSize:titleSize - 2];
    _titleLabel.textColor = phosphor;
    _titleLabel.textAlignment = UITextAlignmentCenter;
    _titleLabel.text = @"Dante";
    
    _titleLabel.layer.shadowColor = phosphor.CGColor;
    _titleLabel.layer.shadowOffset = CGSizeZero;
    _titleLabel.layer.shadowRadius = 6;
    _titleLabel.layer.shadowOpacity = 0.9f;
    _titleLabel.layer.shouldRasterize = YES;
    _titleLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
    [_console addSubview:_titleLabel];

    _taglineLabel = [[UILabel alloc] initWithFrame:
                     CGRectMake(0, CGRectGetMaxY(_titleLabel.frame) + (phone ? 0 : 4), kConsoleWidth, 18)];
    _taglineLabel.backgroundColor = [UIColor clearColor];
    _taglineLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:phone ? 12 : 14]
                      ?: [UIFont fontWithName:@"Courier" size:phone ? 12 : 14];
    _taglineLabel.textColor = DanteHex(0x3dff6e, 0.62f);
    _taglineLabel.textAlignment = UITextAlignmentCenter;
    _taglineLabel.text = @"version 1.0";
    [_console addSubview:_taglineLabel];

    
    _button = [[DanteJailbreakButton alloc] initWithFrame:
               CGRectMake((kConsoleWidth - kButtonSide) / 2, headerH, kButtonSide, kButtonSide)];
    [_button addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    
    
    UILongPressGestureRecognizer *sync = [[UILongPressGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(buttonHeld:)];
    sync.minimumPressDuration = 3.0;
    [_button addGestureRecognizer:sync];
    [_console addSubview:_button];

    
    CGFloat lcdInset = phone ? 0 : 20;
    _lcd = [[DanteLCDView alloc] initWithFrame:CGRectMake(lcdInset, CGRectGetMaxY(_button.frame) + gap,
                                                          kConsoleWidth - 2 * lcdInset, lcdH)];
    [_console addSubview:_lcd];

    
    _registerButton = [[DanteMetalButton alloc] initWithFrame:
                       CGRectMake((kConsoleWidth - 250) / 2, CGRectGetMaxY(_lcd.frame) + gap, 250, 52)];
    _registerButton.title = @"Новый ключ WARP";
    [_registerButton addTarget:self action:@selector(registerTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [_console addSubview:_registerButton];
    
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(registerHeld:)];
    hold.minimumPressDuration = 3.0;
    [_registerButton addGestureRecognizer:hold];

    _daemonState = -2;   
    _shownState = -2;
    [self applyStatus:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(willEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    CGSize size = _console.bounds.size;
    CGFloat margin = DanteIsPhone() ? 6 : 24;
    CGFloat scale = MIN(1.0f, MIN((b.size.width - 2 * margin) / size.width,
                                  (b.size.height - 2 * margin) / size.height));
    _console.transform = CGAffineTransformMakeScale(scale, scale);
    _console.center = CGPointMake(roundf((float)CGRectGetMidX(b)), roundf((float)CGRectGetMidY(b)));
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restartAnimations];
    [self poll];
    [_pollTimer invalidate];
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                selector:@selector(poll)
                                                userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)willEnterForeground {
    [self restartAnimations];
    [self poll];
}

- (void)restartAnimations {
    [_backdrop restartAnimations];
    [_button restartAnimations];
    [_lcd restartAnimations];
}

#pragma mark - Опрос службы

- (void)poll {
    if (_polling) return;
    _polling = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        
        
        NSString *status = DanteControlSend(@"STATUS", 3.0);
        NSString *log = status ? DanteControlSend(@"LOG", 3.0) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_polling = NO;

            [self kickDaemonIfSilent:(status == nil)];
            if (log) [self->_backdrop setLogText:log];
            [self applyStatus:status];
        });
    });
}

- (void)kickDaemonIfSilent:(BOOL)silent {
    if (!silent) { _missedPolls = 0; return; }
    if (++_missedPolls < 3) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastKick < 20) return;
    _lastKick = now;
    char *argv[] = { "/usr/bin/dante-kick", NULL };
    pid_t pid;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) == 0) {
        NSLog(@"[Dante] служба не отвечает — запустил dante-kick (pid %d)", pid);
    }
}

- (void)applyStatus:(NSString *)status {
    NSArray *f = [status componentsSeparatedByString:@"\t"];
    BOOL ok = f.count >= 6 && [[f objectAtIndex:0] isEqualToString:@"OK"];
    if (!ok) {
        if (_daemonState == -2 && !status) {
            
            _button.faceStyle = DanteFaceGrey;
            _button.title = @"JAILBREAK";
            _button.subtitle = DanteIsPhone() ? @"связываюсь со службой…" : @"";
            _lcd.headline = @"BOOTING…";
            _lcd.detail = @"Жду службу…";
            _registerButton.enabled = NO;
            return;
        }
        _daemonState = -1;
        _shownState = -1;
        _button.faceStyle = DanteFaceGrey;
        _button.lockOpen = NO;
        _button.spinning = NO;
        _button.glowing = NO;
        _button.title = @"JAILBREAK";
        _button.subtitle = DanteIsPhone() ? @"служба не отвечает" : @"";
        _lcd.headline = @"NO DAEMON";
        _lcd.detail = @"Служба не запущена";
        _lcd.showsProgress = NO;
        _lcd.daemonOn = NO;
        _lcd.tunnelOn = NO;
        _lcd.systemOn = NO;
        _registerButton.enabled = NO;
        return;
    }

    _daemonState = [[f objectAtIndex:1] integerValue];
    BOOL system = [[f objectAtIndex:2] isEqualToString:@"1"];
    NSString *proxy = [f objectAtIndex:3];
    NSString *statusLine = [f objectAtIndex:4];
    NSString *note = [f objectAtIndex:5];

    _lcd.daemonOn = YES;
    _lcd.tunnelOn = (_daemonState == DanteFixerStateFixed);
    _lcd.systemOn = system;
    _registerButton.enabled = (_daemonState != DanteFixerStateRunning);

    
    
    NSArray *pr = f.count >= 7 ? [[f objectAtIndex:6] componentsSeparatedByString:@"/"] : nil;
    NSInteger done = pr.count == 2 ? [[pr objectAtIndex:0] integerValue] : 0;
    NSInteger total = pr.count == 2 ? [[pr objectAtIndex:1] integerValue] : 0;
    NSInteger shownState = total > 0 ? DanteFixerStateRunning : _daemonState;
    _shownState = shownState;   

    switch (shownState) {
        case DanteFixerStateRunning: {
            _button.faceStyle = DanteFaceAmber;
            _button.lockOpen = NO;
            _button.spinning = YES;
            _button.glowing = YES;
            _button.title = @"JAILBREAKING";
            _button.subtitle = DanteIsPhone() ? @"нажми, чтобы отменить" : @"";
            if (total > 0) {
                _lcd.headline = @"EXPLOITING…";
                _lcd.detail = [NSString stringWithFormat:@"payload %ld/%ld", (long)done, (long)total];
                _lcd.progress = (CGFloat)done / (CGFloat)total;
            } else {
                _lcd.headline = @"JAILBREAKING…";
                _lcd.detail = statusLine;
                _lcd.progress = -1;
            }
            _lcd.showsProgress = YES;
            break;
        }
        case DanteFixerStateFixed:
            _button.faceStyle = DanteFaceGreen;
            _button.lockOpen = YES;
            _button.spinning = NO;
            _button.glowing = YES;
            _button.title = @"JAILBROKEN";
            _button.subtitle = DanteIsPhone() ? @"нажми, чтобы выключить" : @"";
            _lcd.headline = system ? @"UNTETHERED" : @"TETHERED";
            _lcd.detail = note.length ? note : [NSString stringWithFormat:@"SOCKS5 %@", proxy];
            _lcd.showsProgress = NO;
            break;
        case DanteFixerStateFailed:
            _button.faceStyle = DanteFaceRed;
            _button.lockOpen = NO;
            _button.spinning = NO;
            _button.glowing = NO;
            _button.title = @"RETRY";
            _button.subtitle = DanteIsPhone() ? @"не вышло — ещё раз" : @"";
            _lcd.headline = @"FAILED";
            _lcd.detail = statusLine;
            _lcd.showsProgress = NO;
            break;
        default:
            _button.faceStyle = DanteFaceRed;
            _button.lockOpen = NO;
            _button.spinning = NO;
            _button.glowing = NO;
            _button.title = @"JAILBREAK";
            _button.subtitle = DanteIsPhone() ? @"починить интернет" : @"";
            _lcd.headline = @"READY.";
            _lcd.detail = statusLine;
            _lcd.showsProgress = NO;
            break;
    }
    [self applySyncOverlay];
}

#pragma mark - Действия

- (void)send:(NSString *)command {
    _button.enabled = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *reply = DanteControlSend(command, 5.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_button.enabled = YES;
            if (!reply) self->_lcd.detail = @"Служба молчит";
            [self poll];
        });
    });
}

- (void)buttonTapped {
    switch (_shownState) {
        case -1:
        case -2: {
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Служба не отвечает"
                message:@"Служба Dante не запущена. Переустановите пакет или перезагрузите устройство."
                delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [a show];
            break;
        }
        case DanteFixerStateRunning:
            [self send:@"STOP"];
            break;
        case DanteFixerStateFixed:
            [self send:@"STOP"];
            break;
        default:
            [self send:@"FIX"];
            break;
    }
}

- (void)registerTapped {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Новый ключ WARP"
        message:@"Зарегистрировать новую личность Cloudflare WARP? Соединение прервётся на несколько секунд."
        delegate:self cancelButtonTitle:@"Отмена" otherButtonTitles:@"Зарегистрировать", nil];
    a.tag = kAlertRegister;
    [a show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == alertView.cancelButtonIndex) return;
    if (alertView.tag == kAlertStop) [self send:@"STOP"];
    if (alertView.tag == kAlertRegister) [self send:@"REGISTER"];
}

#pragma mark - Подписки

- (void)buttonHeld:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || _syncing || _daemonState < 0) return;
    _syncing = YES;
    [self applySyncOverlay];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *reply = DanteControlSend(@"POWER REFRESH", 90.0);
        
        NSArray *f = [reply componentsSeparatedByString:@"\t"];
        NSString *line = f.count >= 2 && [[f objectAtIndex:0] isEqualToString:@"OK"]
                       ? [f objectAtIndex:1] : @"repo: sync failed";
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_syncing = NO;
            self->_syncResult = line;
            self->_syncResultUntil = [NSDate timeIntervalSinceReferenceDate] + 5;
            [self poll];
        });
    });
}

- (void)applySyncOverlay {
    if (_syncing) {
        _lcd.headline = @"SYNCING REPO…";
        _lcd.detail = @"refreshing sources";
        _lcd.progress = -1;
        _lcd.showsProgress = YES;
    } else if (_syncResult && [NSDate timeIntervalSinceReferenceDate] < _syncResultUntil) {
        _lcd.detail = _syncResult;
    }
}

#pragma mark - Дата-центры

- (void)registerHeld:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (_daemonState < 0) return;
    [self showCountries];
}

- (void)showCountries {
    if (self.presentedViewController) return;
    DanteDCViewController *dc = [[DanteDCViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:dc];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Ориентации

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    
    return DanteIsPhone() ? orientation == UIInterfaceOrientationPortrait : YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
    return DanteIsPhone() ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskAll;
}

@end
