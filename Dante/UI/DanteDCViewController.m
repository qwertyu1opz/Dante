

#import "DanteDCViewController.h"
#import "DanteControl.h"
#import "DanteFixer.h"

@interface DanteDCRow : NSObject
@property (nonatomic, copy) NSString *endpoint, *colo, *city, *country;
@property (nonatomic, assign) NSUInteger ms;
@property (nonatomic, assign) BOOL current;
@end
@implementation DanteDCRow
@end

@implementation DanteDCViewController {
    NSArray *_rows;
    NSArray *_sections;       
    BOOL _autoMode;
    NSString *_busyText;      
    NSString *_pendingColo;   
    BOOL _scanning;
    NSTimer *_timer;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = @"Страна";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Проверить" style:UIBarButtonItemStyleBordered
                                        target:self action:@selector(scan)];
    [self reload];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Служба

- (void)reload {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *list = DanteControlSend(@"DCLIST", 3.0);
        NSString *status = (self->_pendingColo || self->_scanning) ? DanteControlSend(@"STATUS", 3.0) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyList:list status:status]; });
    });
}

- (void)applyList:(NSString *)list status:(NSString *)status {
    NSArray *lines = [list componentsSeparatedByString:@"\n"];
    NSArray *head = [(lines.count ? [lines objectAtIndex:0] : @"") componentsSeparatedByString:@"\t"];
    BOOL scanning = head.count >= 2 && [[head objectAtIndex:1] isEqualToString:@"1"];

    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSArray *f = [[lines objectAtIndex:i] componentsSeparatedByString:@"\t"];
        if (f.count < 6) continue;
        DanteDCRow *r = [[DanteDCRow alloc] init];
        r.endpoint = [f objectAtIndex:0];
        r.colo = [f objectAtIndex:1];
        r.city = [f objectAtIndex:2];
        r.ms = (NSUInteger)[[f objectAtIndex:3] integerValue];
        r.current = [[f objectAtIndex:4] isEqualToString:@"1"];
        r.country = [f objectAtIndex:5];
        [rows addObject:r];
    }
    if (list) {
        _rows = rows;
        _autoMode = head.count < 5 || [[head objectAtIndex:4] isEqualToString:@"1"];
        
        NSMutableArray *sections = [NSMutableArray array];
        NSMutableArray *cur = nil;
        NSString *curColo = nil;
        for (DanteDCRow *r in rows) {
            NSString *key = r.country;
            if (!cur || ![curColo isEqualToString:key]) {
                cur = [NSMutableArray array];
                [sections addObject:cur];
                curColo = key;
            }
            [cur addObject:r];
        }
        _sections = sections;
    }

    
    NSArray *st = [status componentsSeparatedByString:@"\t"];
    NSInteger state = st.count >= 5 ? [[st objectAtIndex:1] integerValue] : -1;
    if (_pendingColo || _scanning) {
        BOOL running = scanning || state == DanteFixerStateRunning;
        if (running) {
            _busyText = st.count >= 5 ? [st objectAtIndex:4] : @"Подключаюсь…";
        } else if (state == DanteFixerStateFixed || state == DanteFixerStateFailed || !status) {
            _busyText = (state == DanteFixerStateFailed) ? @"Не удалось подключиться" : nil;
            _pendingColo = nil;
            _scanning = NO;
        }
    }
    if (!list) _busyText = @"Служба Dante не отвечает";

    BOOL busy = _pendingColo || _scanning;
    self.navigationItem.rightBarButtonItem.enabled = !busy;
    if (busy && !_timer) {
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(reload)
                                                userInfo:nil repeats:YES];
    } else if (!busy && _timer) {
        [_timer invalidate];
        _timer = nil;
    }
    [self.tableView reloadData];
}

- (void)send:(NSString *)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *reply = DanteControlSend(command, 5.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![reply hasPrefix:@"OK"]) {
                self->_pendingColo = nil;
                self->_scanning = NO;
                self->_busyText = reply.length ? reply : @"Служба Dante не отвечает";
            }
            [self reload];
        });
    });
}

- (void)scan {
    _scanning = YES;
    _busyText = @"Проверяю дата-центры…";
    [self.tableView reloadData];
    [self send:@"DCSCAN"];
}

#pragma mark - Таблица

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1 + (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return (NSInteger)[[_sections objectAtIndex:(NSUInteger)section - 1] count];
}

- (DanteDCRow *)rowAt:(NSIndexPath *)indexPath {
    return [[_sections objectAtIndex:(NSUInteger)indexPath.section - 1] objectAtIndex:(NSUInteger)indexPath.row];
}

- (DanteDCRow *)currentRow {
    for (DanteDCRow *r in _rows) if (r.current) return r;
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return _busyText;
    DanteDCRow *first = [[_sections objectAtIndex:(NSUInteger)section - 1] objectAtIndex:0];
    return [NSString stringWithFormat:@"%@ — %@", first.country, first.city];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Dante сам ставит самый быстрый адрес, а если он перестал отвечать — следующий.";
    }
    if (section == (NSInteger)_sections.count) {
        return @"Меняется город, через который идёт трафик. Сайты по-прежнему видят твою страну — "
                "так Cloudflare помечает адреса WARP. «Проверить» найдёт новые адреса.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ident = @"dc";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ident];
    BOOL busy = _pendingColo || _scanning;
    NSString *key;
    BOOL checked;
    if (indexPath.section == 0) {
        DanteDCRow *cur = [self currentRow];
        cell.textLabel.text = @"Авто";
        cell.detailTextLabel.text = cur
            ? [NSString stringWithFormat:@"сейчас: %@ — %@, %@", cur.country, cur.city, cur.endpoint]
            : @"самый быстрый адрес";
        key = @"auto";
        checked = _autoMode;
    } else {
        DanteDCRow *r = [self rowAt:indexPath];
        cell.textLabel.text = r.endpoint;
        cell.detailTextLabel.text = r.ms
            ? [NSString stringWithFormat:@"%@ · %lu мс", r.colo, (unsigned long)r.ms]
            : [NSString stringWithFormat:@"%@ · не проверен", r.colo];
        key = r.endpoint;
        checked = !_autoMode && r.current;
    }
    if ([_pendingColo isEqualToString:key]) {
        UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
                                         initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        [spin startAnimating];
        cell.accessoryView = spin;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = (checked && !busy) ? UITableViewCellAccessoryCheckmark
                                                : UITableViewCellAccessoryNone;
    }
    cell.selectionStyle = busy ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleBlue;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_pendingColo || _scanning) return;
    if (indexPath.section == 0) {
        _pendingColo = @"auto";
        _busyText = @"Авто: подключаюсь…";
        [tableView reloadData];
        [self send:@"DCAUTO"];
        return;
    }
    DanteDCRow *r = [self rowAt:indexPath];
    _pendingColo = r.endpoint;
    _busyText = [NSString stringWithFormat:@"Подключаюсь: %@…", r.country];
    [tableView reloadData];
    [self send:[@"DCSET " stringByAppendingString:r.endpoint]];
}

@end
