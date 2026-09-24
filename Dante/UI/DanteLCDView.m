

#import "DanteLCDView.h"
#import "DanteSkin.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kGlassInset = 14;
static const CGFloat kGlassHeight = 92;
static const CGFloat kPlateHeight = 44;
static const uint32_t kLCDGreen = 0x7dff8c;

#pragma mark - Лампочка

@interface DanteLEDView : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, assign) uint32_t color;
@end

@implementation DanteLEDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        CGRect lamp = CGRectInset(self.bounds, 3, 3);
        
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:lamp].CGPath;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowRadius = 7;
    }
    return self;
}

- (void)setOn:(BOOL)on {
    if (on == _on) return;
    _on = on;
    [self refresh];
}

- (void)setColor:(uint32_t)color {
    _color = color;
    [self refresh];
}

- (void)refresh {
    self.layer.shadowColor = DanteHex(_color, 1).CGColor;
    self.layer.shadowOpacity = _on ? 0.95f : 0;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat R = MIN(b.size.width, b.size.height) / 2;

    UIBezierPath *socket = DanteCircle(c, R);
    DanteFillLinear(ctx, socket.CGPath, @[DanteHex(0x000000, 0.85f), DanteHex(0x8a8a8a, 1)], NULL,
                    CGPointMake(0, c.y - R), CGPointMake(0, c.y + R));

    CGFloat r = R - 3;
    UIBezierPath *lamp = DanteCircle(c, r);
    CGFloat locs[] = {0, 0.5f, 1};
    if (_on) {
        DanteFillRadial(ctx, lamp.CGPath,
                        @[DanteHex(0xffffff, 1), DanteHex(_color, 1), DanteHex(_color, 0.55f)],
                        locs, c, r);
    } else {
        DanteFillRadial(ctx, lamp.CGPath,
                        @[DanteHex(_color, 0.35f), DanteHex(_color, 0.18f), DanteHex(0x000000, 0.9f)],
                        locs, CGPointMake(c.x, c.y + r * 0.3f), r * 1.2f);
    }
    
    CGRect spec = CGRectMake(c.x - r * 0.55f, c.y - r * 0.8f, r * 1.1f, r * 0.75f);
    UIBezierPath *specPath = [UIBezierPath bezierPathWithOvalInRect:spec];
    DanteFillLinear(ctx, specPath.CGPath, @[DanteHex(0xffffff, 0.75f), DanteHex(0xffffff, 0)], NULL,
                    CGPointMake(0, CGRectGetMinY(spec)), CGPointMake(0, CGRectGetMaxY(spec)));
}

@end

#pragma mark - Полосатый прогресс-бар

@interface DanteStripeBar : UIView
- (void)restartAnimations;
@property (nonatomic, assign) CGFloat fraction;   
@end

@implementation DanteStripeBar {
    UIView *_clip;
    UIImageView *_stripes;
    CGFloat _period;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        _period = 18;
        _fraction = -1;
        _clip = [[UIView alloc] init];
        _clip.clipsToBounds = YES;   
        [self addSubview:_clip];
        _stripes = [[UIImageView alloc] init];
        [_clip addSubview:_stripes];
    }
    return self;
}

- (UIImage *)stripeImageOfSize:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *all = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, size.width, size.height)];
    DanteFillLinear(ctx, all.CGPath, @[DanteHex(0x9dff8a, 1), DanteHex(0x2fb83f, 1), DanteHex(0x157a22, 1)],
                    NULL, CGPointZero, CGPointMake(0, size.height));
    CGContextSetFillColorWithColor(ctx, DanteHex(0x000000, 0.22f).CGColor);
    for (CGFloat x = -size.height; x < size.width + size.height; x += _period) {
        CGContextMoveToPoint(ctx, x, size.height);
        CGContextAddLineToPoint(ctx, x + size.height, 0);
        CGContextAddLineToPoint(ctx, x + size.height + _period / 2, 0);
        CGContextAddLineToPoint(ctx, x + _period / 2, size.height);
        CGContextClosePath(ctx);
    }
    CGContextFillPath(ctx);
    UIBezierPath *gloss = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, size.width, size.height / 2)];
    DanteFillLinear(ctx, gloss.CGPath, @[DanteHex(0xffffff, 0.45f), DanteHex(0xffffff, 0.1f)], NULL,
                    CGPointZero, CGPointMake(0, size.height / 2));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect inner = CGRectInset(self.bounds, 2, 2);
    _clip.frame = [self clipFrameFor:inner];
    _clip.layer.cornerRadius = inner.size.height / 2;
    CGSize size = CGSizeMake(inner.size.width + _period * 2, inner.size.height);
    if (!CGSizeEqualToSize(_stripes.bounds.size, size)) {
        _stripes.image = [self stripeImageOfSize:size];
        _stripes.frame = CGRectMake(-_period * 2, 0, size.width, size.height);
    }
    [self restartAnimations];
}

- (CGRect)clipFrameFor:(CGRect)inner {
    if (_fraction < 0) return inner;
    CGFloat f = MIN(1, _fraction);
    inner.size.width = MAX(inner.size.height, roundf((float)(inner.size.width * f)));
    return inner;
}

- (void)setFraction:(CGFloat)fraction {
    if (fraction == _fraction) return;
    _fraction = fraction;
    CGRect target = [self clipFrameFor:CGRectInset(self.bounds, 2, 2)];
    [UIView animateWithDuration:0.35 delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self->_clip.frame = target; } completion:nil];
}

- (void)restartAnimations {
    [_stripes.layer removeAllAnimations];
    if (self.hidden) return;
    CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    move.fromValue = @0;
    move.toValue = @(_period);
    move.duration = 0.55;
    move.repeatCount = HUGE_VALF;
    [_stripes.layer addAnimation:move forKey:@"march"];
}

- (void)setHidden:(BOOL)hidden {
    BOOL changed = hidden != self.hidden;
    [super setHidden:hidden];
    if (changed) [self restartAnimations];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    UIBezierPath *track = DanteRoundRect(b, b.size.height / 2);
    CGContextAddPath(ctx, track.CGPath);
    CGContextSetFillColorWithColor(ctx, DanteHex(0x000000, 0.7f).CGColor);
    CGContextFillPath(ctx);
    DanteInnerShadow(ctx, track.CGPath, DanteHex(0x000000, 1), CGSizeMake(0, 1), 3);
}

@end

#pragma mark - LCD

@implementation DanteLCDView {
    UILabel *_headlineLabel;
    UILabel *_detailLabel;
    DanteStripeBar *_bar;
    DanteLEDView *_leds[3];
    UILabel *_captions[3];
}

+ (CGFloat)preferredHeight {
    return kGlassInset + kGlassHeight + kPlateHeight;
}

static UILabel *DanteGlowLabel(UIFont *font, CGFloat alpha) {
    UILabel *l = [[UILabel alloc] init];
    l.backgroundColor = [UIColor clearColor];
    l.font = font;
    l.textColor = DanteHex(kLCDGreen, alpha);
    l.textAlignment = UITextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumFontSize = 10;
    
    
    l.layer.shadowColor = DanteHex(kLCDGreen, 1).CGColor;
    l.layer.shadowOffset = CGSizeZero;
    l.layer.shadowRadius = 4;
    l.layer.shadowOpacity = 0.9f;
    l.layer.shouldRasterize = YES;
    l.layer.rasterizationScale = DanteScreenScale();
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;

        UIFont *mono = [UIFont fontWithName:@"Courier-Bold" size:24] ?: [UIFont boldSystemFontOfSize:22];
        _headlineLabel = DanteGlowLabel(mono, 1);
        [self addSubview:_headlineLabel];
        _detailLabel = DanteGlowLabel([UIFont fontWithName:@"Courier-Bold" size:14] ?: [UIFont systemFontOfSize:13], 0.75f);
        [self addSubview:_detailLabel];

        _progress = -1;
        _bar = [[DanteStripeBar alloc] init];
        _bar.hidden = YES;
        [self addSubview:_bar];

        NSArray *names = @[@"DAEMON", @"TUNNEL", @"SYSTEM"];
        uint32_t colors[3] = {0x5ab4ff, 0x6dff7a, 0xffb238};
        for (int i = 0; i < 3; i++) {
            _leds[i] = [[DanteLEDView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
            _leds[i].color = colors[i];
            [self addSubview:_leds[i]];

            UILabel *cap = [[UILabel alloc] init];
            cap.backgroundColor = [UIColor clearColor];
            cap.font = [UIFont boldSystemFontOfSize:11];
            cap.text = [names objectAtIndex:i];
            
            cap.textColor = DanteHex(0x141414, 0.9f);
            cap.shadowColor = DanteHex(0xffffff, 0.3f);
            cap.shadowOffset = CGSizeMake(0, 1);
            [self addSubview:cap];
            _captions[i] = cap;
        }
    }
    return self;
}

- (CGRect)glassRect {
    return CGRectMake(kGlassInset, kGlassInset, self.bounds.size.width - 2 * kGlassInset, kGlassHeight - kGlassInset);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    
    CGRect body = CGRectInset(self.bounds, 2, 2);
    body.size.height -= 6;
    self.layer.shadowPath = DanteRoundRect(body, 16).CGPath;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 6);
    self.layer.shadowRadius = 7;
    self.layer.shadowOpacity = 0.9f;
    CGRect g = [self glassRect];
    CGFloat pad = 16;
    _headlineLabel.frame = CGRectMake(g.origin.x + pad, g.origin.y + 8, g.size.width - 2 * pad, 30);
    if (_showsProgress) {
        _bar.frame = CGRectMake(g.origin.x + pad + 20, g.origin.y + 42, g.size.width - 2 * pad - 40, 12);
        _detailLabel.frame = CGRectMake(g.origin.x + pad, g.origin.y + 55, g.size.width - 2 * pad, 20);
    } else {
        _detailLabel.frame = CGRectMake(g.origin.x + pad, g.origin.y + 44, g.size.width - 2 * pad, 22);
    }

    
    CGFloat plateTop = kGlassHeight + 2;
    CGFloat slot = (self.bounds.size.width - 60) / 3;
    for (int i = 0; i < 3; i++) {
        CGSize capSize = [_captions[i].text sizeWithFont:_captions[i].font];
        CGFloat groupW = 18 + 7 + capSize.width;
        CGFloat x = 30 + slot * i + (slot - groupW) / 2;
        CGFloat y = plateTop + (kPlateHeight - 18) / 2 - 4;
        _leds[i].frame = CGRectMake(x, y, 18, 18);
        _captions[i].frame = CGRectMake(x + 25, y, capSize.width + 2, 18);
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = CGRectInset(self.bounds, 2, 2);
    b.size.height -= 6;   

    
    UIBezierPath *body = DanteRoundRect(b, 16);
    CGContextAddPath(ctx, body.CGPath);
    CGContextSetFillColorWithColor(ctx, DanteHex(0x333333, 1).CGColor);
    CGContextFillPath(ctx);
    
    DanteFillBrushedMetal(ctx, body.CGPath, b, YES);
    CGFloat bodyLocs[] = {0, 0.5f, 1};
    DanteFillLinear(ctx, body.CGPath, @[DanteHex(0x000000, 0.18f), DanteHex(0x000000, 0.45f), DanteHex(0x000000, 0.7f)],
                    bodyLocs, CGPointMake(0, CGRectGetMinY(b)), CGPointMake(0, CGRectGetMaxY(b)));
    CGFloat edgeLocs[] = {0, 0.15f, 1};
    UIBezierPath *edge = DanteRoundRect(CGRectInset(b, 0.5f, 0.5f), 15.5f);
    DanteStrokeLinear(ctx, edge.CGPath, 1,
                      @[DanteHex(0xffffff, 0.45f), DanteHex(0xffffff, 0.08f), DanteHex(0x000000, 0.6f)],
                      edgeLocs);

    
    CGRect g = [self glassRect];
    UIBezierPath *lipPath = DanteRoundRect(CGRectInset(g, -1.5f, -1.5f), 9.5f);
    DanteStrokeLinear(ctx, lipPath.CGPath, 1.5f,
                      @[DanteHex(0x000000, 0.7f), DanteHex(0x000000, 0.2f), DanteHex(0xffffff, 0.3f)],
                      edgeLocs);
    UIBezierPath *glass = DanteRoundRect(g, 8);
    DanteFillLinear(ctx, glass.CGPath, @[DanteHex(0x0f2a18, 1), DanteHex(0x061209, 1)], NULL,
                    CGPointMake(0, CGRectGetMinY(g)), CGPointMake(0, CGRectGetMaxY(g)));
    
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, glass.CGPath);
    CGContextClip(ctx);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithPatternImage:DanteScanlineImage(0.35f)].CGColor);
    CGContextFillRect(ctx, g);
    CGContextRestoreGState(ctx);
    DanteInnerShadow(ctx, glass.CGPath, DanteHex(0x000000, 1), CGSizeMake(0, 2), 7);
    
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, glass.CGPath);
    CGContextClip(ctx);
    UIBezierPath *sheen = [UIBezierPath bezierPath];
    [sheen moveToPoint:g.origin];
    [sheen addLineToPoint:CGPointMake(CGRectGetMinX(g) + g.size.width * 0.72f, CGRectGetMinY(g))];
    [sheen addLineToPoint:CGPointMake(CGRectGetMinX(g) + g.size.width * 0.42f, CGRectGetMaxY(g))];
    [sheen addLineToPoint:CGPointMake(CGRectGetMinX(g), CGRectGetMaxY(g))];
    [sheen closePath];
    DanteFillLinear(ctx, sheen.CGPath, @[DanteHex(0xffffff, 0.09f), DanteHex(0xffffff, 0.01f)], NULL,
                    g.origin, CGPointMake(CGRectGetMinX(g), CGRectGetMaxY(g)));
    CGContextRestoreGState(ctx);

    
    CGFloat seamY = kGlassHeight + 1;
    CGFloat screwY = seamY + (kPlateHeight - 6) / 2;
    DanteDrawScrew(ctx, CGPointMake(CGRectGetMinX(b) + 16, screwY), 5, 0.6f);
    DanteDrawScrew(ctx, CGPointMake(CGRectGetMaxX(b) - 16, screwY), 5, 2.1f);
}

#pragma mark - Свойства

- (void)setHeadline:(NSString *)headline {
    if ([headline isEqualToString:_headline]) return;
    _headline = [headline copy];
    _headlineLabel.text = headline;
}

- (void)setDetail:(NSString *)detail {
    if ([detail isEqualToString:_detail]) return;
    _detail = [detail copy];
    _detailLabel.text = detail;
}

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
    _bar.fraction = progress;
}

- (void)setShowsProgress:(BOOL)showsProgress {
    if (showsProgress == _showsProgress) return;
    _showsProgress = showsProgress;
    _bar.hidden = !showsProgress;
    [self setNeedsLayout];
}

- (void)setDaemonOn:(BOOL)on { _daemonOn = on; _leds[0].on = on; }
- (void)setTunnelOn:(BOOL)on { _tunnelOn = on; _leds[1].on = on; }
- (void)setSystemOn:(BOOL)on { _systemOn = on; _leds[2].on = on; }

- (void)restartAnimations {
    [_bar restartAnimations];
}

@end
