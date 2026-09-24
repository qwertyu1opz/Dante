

#import "DanteLogBackdrop.h"
#import "DanteSkin.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kLogPad = 18;
static NSString * const kPrompt = @"root@dante:~# ";

#pragma mark - Накладка: скан-линии, затухание, ореол, виньетка

@interface DanteBackdropOverlay : UIView
@end

@implementation DanteBackdropOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    UIBezierPath *all = [UIBezierPath bezierPathWithRect:b];

    
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithPatternImage:DanteScanlineImage(0.45f)].CGColor);
    CGContextFillRect(ctx, b);

    
    CGFloat fadeLocs[] = {0, 0.45f};
    DanteFillLinear(ctx, all.CGPath, @[DanteHex(0x030604, 0.55f), DanteHex(0x030604, 0)], fadeLocs,
                    CGPointMake(0, 0), CGPointMake(0, b.size.height));

    
    CGFloat haloLocs[] = {0, 0.55f, 1};
    CGFloat haloR = MIN(b.size.width, b.size.height) * 0.62f;
    DanteFillRadial(ctx, all.CGPath,
                    @[DanteHex(0x030604, 0.5f), DanteHex(0x030604, 0.3f), DanteHex(0x030604, 0)],
                    haloLocs, c, haloR);

    
    CGFloat vigLocs[] = {0, 0.7f, 1};
    CGFloat far = sqrtf((float)(b.size.width * b.size.width + b.size.height * b.size.height)) / 2;
    DanteFillRadial(ctx, all.CGPath,
                    @[DanteHex(0x000000, 0), DanteHex(0x000000, 0.15f), DanteHex(0x000000, 0.7f)],
                    vigLocs, c, far);
}

@end

#pragma mark - Фон

@implementation DanteLogBackdrop {
    UIImageView *_art;
    UILabel *_logLabel;
    UIView *_cursor;
    DanteBackdropOverlay *_overlay;
    UIFont *_font;
    CGFloat _lineHeight;
    CGFloat _charWidth;
    NSString *_rawText;
    NSArray *_shownLines;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = DanteHex(0x030604, 1);
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;

        CGFloat size = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) ? 9 : 12;
        _font = [UIFont fontWithName:@"Menlo-Regular" size:size]
             ?: [UIFont fontWithName:@"Courier" size:size];
        _lineHeight = ceilf((float)_font.lineHeight);
        _charWidth = [@"M" sizeWithFont:_font].width;

        
        
        _art = [[UIImageView alloc] initWithFrame:self.bounds];
        _art.image = [UIImage imageNamed:@"DanteBackdrop.jpg"];
        _art.contentMode = UIViewContentModeScaleToFill;   
        _art.alpha = 0.9f;
        [self addSubview:_art];

        _logLabel = [[UILabel alloc] init];
        _logLabel.backgroundColor = [UIColor clearColor];
        _logLabel.font = _font;
        _logLabel.numberOfLines = 0;
        _logLabel.textColor = DanteHex(0x3dff6e, 0.62f);
        [self addSubview:_logLabel];

        _cursor = [[UIView alloc] init];
        _cursor.backgroundColor = DanteHex(0x3dff6e, 0.8f);
        [self addSubview:_cursor];

        _overlay = [[DanteBackdropOverlay alloc] initWithFrame:self.bounds];
        _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_overlay];

        [self restartAnimations];
    }
    return self;
}

- (NSUInteger)visibleLineCount {
    return (NSUInteger)MAX(1, floorf((float)((self.bounds.size.height - 2 * kLogPad) / _lineHeight)));
}

- (NSUInteger)visibleColumns {
    return (NSUInteger)MAX(10, floorf((float)((self.bounds.size.width - 2 * kLogPad) / _charWidth)));
}

- (NSArray *)linesForText:(NSString *)text {
    NSUInteger rows = [self visibleLineCount] - 1;   
    NSUInteger cols = [self visibleColumns];
    NSMutableArray *out = [NSMutableArray array];
    NSArray *all = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSInteger i = (NSInteger)all.count - 1; i >= 0 && out.count < rows; i--) {
        NSString *line = [all objectAtIndex:(NSUInteger)i];
        if (line.length == 0) continue;
        if (line.length > cols) line = [line substringToIndex:cols];
        [out insertObject:line atIndex:0];
    }
    return out;
}

- (CGRect)labelFrameForLineCount:(NSUInteger)count {
    CGFloat h = (count + 1) * _lineHeight;
    return CGRectMake(kLogPad, self.bounds.size.height - kLogPad - h,
                      self.bounds.size.width - 2 * kLogPad, h);
}

- (void)render:(BOOL)animated {
    NSArray *lines = [self linesForText:_rawText ?: @""];
    NSUInteger added = 0;
    if (animated && _shownLines.count > 0) {
        
        NSString *lastOld = [_shownLines lastObject];
        for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
            if ([[lines objectAtIndex:(NSUInteger)i] isEqualToString:lastOld]) {
                added = lines.count - 1 - (NSUInteger)i;
                break;
            }
        }
    }
    _shownLines = lines;

    NSString *body = [lines componentsJoinedByString:@"\n"];
    _logLabel.text = body.length ? [body stringByAppendingFormat:@"\n%@", kPrompt] : kPrompt;
    CGRect final = [self labelFrameForLineCount:lines.count];

    CGFloat promptW = [kPrompt sizeWithFont:_font].width;
    CGRect cursorFrame = CGRectMake(kLogPad + promptW, CGRectGetMaxY(final) - _lineHeight + 2,
                                    _charWidth, _lineHeight - 4);

    if (added > 0 && added < lines.count) {
        
        CGFloat shift = added * _lineHeight;
        _logLabel.frame = CGRectOffset(final, 0, shift);
        _cursor.frame = CGRectOffset(cursorFrame, 0, shift);
        [UIView animateWithDuration:MIN(0.6, 0.12 * added)
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self->_logLabel.frame = final;
            self->_cursor.frame = cursorFrame;
        } completion:nil];
    } else {
        _logLabel.frame = final;
        _cursor.frame = cursorFrame;
    }
}

- (void)setLogText:(NSString *)text {
    if ([text isEqualToString:_rawText]) return;
    _rawText = [text copy];
    [self render:YES];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    
    CGSize img = _art.image.size;
    if (img.width > 0 && img.height > 0) {
        CGSize b = self.bounds.size;
        CGFloat scale = MAX(b.width / img.width, b.height / img.height);
        CGFloat w = ceilf((float)(img.width * scale)), h = ceilf((float)(img.height * scale));
        _art.frame = CGRectMake(floorf((float)((b.width - w) / 2)), 0, w, h);
    }
    [self render:NO];
}

- (void)restartAnimations {
    [_cursor.layer removeAllAnimations];
    CAKeyframeAnimation *blink = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    blink.values = @[@1, @1, @0, @0];
    blink.keyTimes = @[@0, @0.5, @0.5, @1];
    blink.calculationMode = kCAAnimationDiscrete;
    blink.duration = 1.0;
    blink.repeatCount = HUGE_VALF;
    [_cursor.layer addAnimation:blink forKey:@"blink"];
}

@end
