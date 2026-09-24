

#import "DanteJailbreakButton.h"
#import "DanteSkin.h"
#import <QuartzCore/QuartzCore.h>

typedef struct {
    uint32_t top, mid, bottom, glow;
} DanteFacePalette;

static DanteFacePalette DantePalette(DanteFaceStyle style) {
    switch (style) {
        case DanteFaceAmber: return (DanteFacePalette){0xffd564, 0xe58f10, 0x7a4300, 0xffc24a};
        case DanteFaceGreen: return (DanteFacePalette){0x8ff58b, 0x25ad37, 0x0b5616, 0x6dff7a};
        case DanteFaceGrey:  return (DanteFacePalette){0xb4b4b4, 0x6b6b6b, 0x2c2c2c, 0x9a9a9a};
        default:             return (DanteFacePalette){0xff5d52, 0xc4161c, 0x640709, 0xff3b30};
    }
}

#pragma mark - Корпус

@interface DanteButtonBodyView : UIView
@property (nonatomic, weak) DanteJailbreakButton *owner;
@end

@implementation DanteButtonBodyView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.userInteractionEnabled = NO;
    }
    return self;
}

static void DanteDrawPadlock(CGContextRef ctx, CGPoint c, CGFloat s, BOOL open) {
    
    CGRect body = CGRectMake(c.x - s / 2, c.y - s * 0.1f, s, s * 0.78f);
    CGFloat shackleW = s * 0.62f;
    CGFloat lift = open ? s * 0.22f : 0;
    CGFloat shift = open ? s * 0.28f : 0;

    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1.5f), 2, DanteHex(0x000000, 0.55f).CGColor);

    CGMutablePathRef shackle = CGPathCreateMutable();
    CGFloat left = c.x - shackleW / 2 + shift;
    CGFloat baseY = body.origin.y + s * 0.05f;
    CGPathMoveToPoint(shackle, NULL, left, baseY - lift);
    CGPathAddLineToPoint(shackle, NULL, left, baseY - s * 0.32f - lift);
    CGPathAddArc(shackle, NULL, left + shackleW / 2, baseY - s * 0.32f - lift,
                 shackleW / 2, (CGFloat)M_PI, 0, false);
    CGPathAddLineToPoint(shackle, NULL, left + shackleW, open ? baseY - s * 0.45f - lift : baseY);
    CGContextAddPath(ctx, shackle);
    CGContextSetLineWidth(ctx, s * 0.14f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, DanteHex(0xffffff, 0.92f).CGColor);
    CGContextStrokePath(ctx);
    CGPathRelease(shackle);

    UIBezierPath *bodyPath = DanteRoundRect(body, s * 0.14f);
    CGContextAddPath(ctx, bodyPath.CGPath);
    CGContextSetFillColorWithColor(ctx, DanteHex(0xffffff, 0.95f).CGColor);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);

    
    CGContextSetFillColorWithColor(ctx, DanteHex(0x000000, 0.45f).CGColor);
    CGFloat kr = s * 0.09f;
    CGPoint k = CGPointMake(CGRectGetMidX(body), CGRectGetMidY(body) - kr * 0.4f);
    CGContextFillEllipseInRect(ctx, CGRectMake(k.x - kr, k.y - kr, 2 * kr, 2 * kr));
    CGContextFillRect(ctx, CGRectMake(k.x - kr * 0.45f, k.y, kr * 0.9f, kr * 2.2f));
}

- (void)drawRect:(CGRect)rect {
    DanteJailbreakButton *b = self.owner;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGPoint c = CGPointMake(w / 2, h / 2);
    CGFloat R = MIN(w, h) / 2 - 14;
    BOOL down = b.highlighted;
    DanteFacePalette pal = DantePalette(b.faceStyle);

    
    UIBezierPath *bezel = DanteCircle(c, R);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 9), 20, DanteHex(0x000000, 0.9f).CGColor);
    CGContextAddPath(ctx, bezel.CGPath);
    CGContextSetFillColorWithColor(ctx, DanteHex(0x6a6a6a, 1).CGColor);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
    CGFloat bezelLocs[] = {0, 0.3f, 0.62f, 1};
    DanteFillLinear(ctx, bezel.CGPath,
                    @[DanteHex(0xf7f7f7, 1), DanteHex(0xc2c2c2, 1), DanteHex(0x777777, 1), DanteHex(0x3b3b3b, 1)],
                    bezelLocs, CGPointMake(0, c.y - R), CGPointMake(0, c.y + R));
    
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, bezel.CGPath);
    CGContextClip(ctx);
    CGContextSetLineWidth(ctx, 0.5f);
    for (CGFloat r = R - 22; r < R; r += 0.75f) {
        int k = (int)(r * 4) % 7;
        UIColor *line = (k < 2) ? DanteHex(0xffffff, 0.16f)
                      : (k == 5) ? DanteHex(0x000000, 0.10f) : nil;
        if (!line) continue;
        CGContextSetStrokeColorWithColor(ctx, line.CGColor);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r));
    }
    CGContextRestoreGState(ctx);
    CGFloat edgeLocs[] = {0, 0.5f, 1};
    UIBezierPath *edge = DanteCircle(c, R - 0.75f);
    DanteStrokeLinear(ctx, edge.CGPath, 1.5f,
                      @[DanteHex(0xffffff, 0.85f), DanteHex(0xffffff, 0.1f), DanteHex(0x000000, 0.5f)],
                      edgeLocs);

    
    CGFloat Rg = R - 20;
    UIBezierPath *groove = DanteCircle(c, Rg);
    DanteFillLinear(ctx, groove.CGPath, @[DanteHex(0x050505, 1), DanteHex(0x262626, 1)], NULL,
                    CGPointMake(0, c.y - Rg), CGPointMake(0, c.y + Rg));
    DanteInnerShadow(ctx, groove.CGPath, DanteHex(0x000000, 1), CGSizeMake(0, 3), 8);
    UIBezierPath *lip = DanteCircle(c, Rg + 0.75f);
    DanteStrokeLinear(ctx, lip.CGPath, 1.5f,
                      @[DanteHex(0x000000, 0.55f), DanteHex(0x000000, 0.0f), DanteHex(0xffffff, 0.55f)],
                      edgeLocs);

    
    CGFloat Rf = Rg - 8;
    CGPoint fc = CGPointMake(c.x, c.y + (down ? 2.0f : 0));
    UIBezierPath *face = DanteCircle(fc, Rf);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, down ? 1 : 4), down ? 3 : 7,
                                DanteHex(0x000000, 0.9f).CGColor);
    CGContextAddPath(ctx, face.CGPath);
    CGContextSetFillColorWithColor(ctx, DanteHex(pal.bottom, 1).CGColor);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);

    CGFloat faceLocs[] = {0, 0.55f, 1};
    DanteFillLinear(ctx, face.CGPath,
                    @[DanteHex(pal.top, 1), DanteHex(pal.mid, 1), DanteHex(pal.bottom, 1)],
                    faceLocs, CGPointMake(0, fc.y - Rf), CGPointMake(0, fc.y + Rf));
    
    CGFloat rimLocs[] = {0, 0.72f, 1};
    DanteFillRadial(ctx, face.CGPath,
                    @[DanteHex(0x000000, 0), DanteHex(0x000000, 0.05f), DanteHex(0x000000, 0.45f)],
                    rimLocs, fc, Rf);
    
    CGFloat glowLocs[] = {0, 1};
    DanteFillRadial(ctx, face.CGPath, @[DanteHex(pal.glow, 0.65f), DanteHex(pal.glow, 0)],
                    glowLocs, CGPointMake(fc.x, fc.y + Rf * 0.78f), Rf * 0.85f);
    if (down) {
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, face.CGPath);
        CGContextSetFillColorWithColor(ctx, DanteHex(0x000000, 0.2f).CGColor);
        CGContextFillPath(ctx);
        CGContextRestoreGState(ctx);
    }

    
    DanteDrawPadlock(ctx, CGPointMake(fc.x, fc.y - Rf * 0.36f), Rf * 0.24f, b.lockOpen);
    CGFloat maxTextW = Rf * 1.55f;
    UIFont *titleFont = DanteFitFont(b.title, @"HelveticaNeue-Bold", Rf * 0.21f, 14, maxTextW);
    CGFloat th = titleFont.lineHeight;
    CGFloat titleY = (b.subtitle.length > 0) ? (fc.y + Rf * 0.02f) : (fc.y + Rf * 0.08f);
    DanteDrawText(b.title, CGRectMake(fc.x - maxTextW / 2, titleY, maxTextW, th),
                  titleFont, DanteHex(0xffffff, 0.97f), DanteHex(0x000000, 0.5f), CGSizeMake(0, 1.5f));
    if (b.subtitle.length > 0) {
        UIFont *subFont = DanteFitFont(b.subtitle, @"HelveticaNeue-Bold", Rf * 0.085f, 9, maxTextW * 0.9f);
        DanteDrawText(b.subtitle,
                      CGRectMake(fc.x - maxTextW / 2, titleY + th + 2, maxTextW, subFont.lineHeight),
                      subFont, DanteHex(0xffffff, 0.78f), DanteHex(0x000000, 0.45f), CGSizeMake(0, 1));
    }

    
    CGRect glossRect = CGRectMake(fc.x - Rf * 0.84f, fc.y - Rf * 0.97f, Rf * 1.68f, Rf * 1.0f);
    UIBezierPath *gloss = [UIBezierPath bezierPathWithOvalInRect:glossRect];
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, face.CGPath);
    CGContextClip(ctx);
    DanteFillLinear(ctx, gloss.CGPath,
                    @[DanteHex(0xffffff, down ? 0.4f : 0.62f), DanteHex(0xffffff, 0.06f)], NULL,
                    CGPointMake(0, CGRectGetMinY(glossRect)), CGPointMake(0, CGRectGetMaxY(glossRect)));
    CGContextRestoreGState(ctx);

    
    CGContextAddPath(ctx, face.CGPath);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetStrokeColorWithColor(ctx, DanteHex(0x000000, 0.55f).CGColor);
    CGContextStrokePath(ctx);
}

@end

#pragma mark - Кнопка

@implementation DanteJailbreakButton {
    UIImageView *_glowView;
    DanteButtonBodyView *_body;
    CAShapeLayer *_spinner;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _title = @"JAILBREAK";
        _subtitle = @"";

        _glowView = [[UIImageView alloc] init];
        _glowView.userInteractionEnabled = NO;
        [self addSubview:_glowView];

        _body = [[DanteButtonBodyView alloc] initWithFrame:self.bounds];
        _body.owner = self;
        _body.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_body];

        _spinner = [CAShapeLayer layer];
        _spinner.fillColor = nil;
        _spinner.lineWidth = 4;
        _spinner.lineCap = kCALineCapRound;
        _spinner.strokeStart = 0;
        _spinner.strokeEnd = 0.24f;
        _spinner.shadowOffset = CGSizeZero;
        _spinner.shadowRadius = 5;
        _spinner.shadowOpacity = 1;
        
        _spinner.shouldRasterize = YES;
        _spinner.rasterizationScale = DanteScreenScale();
        _spinner.hidden = YES;
        [self.layer addSublayer:_spinner];

        [self applyStyle];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _glowView.frame = CGRectInset(b, -60, -60);
    _spinner.frame = b;
    CGFloat R = MIN(b.size.width, b.size.height) / 2 - 14;
    CGFloat Rs = R - 20 - 4;
    CGPoint c = CGPointMake(b.size.width / 2, b.size.height / 2);
    _spinner.path = [UIBezierPath bezierPathWithArcCenter:c radius:Rs startAngle:(CGFloat)-M_PI_2
                                                 endAngle:(CGFloat)(1.5 * M_PI) clockwise:YES].CGPath;
    [self rebuildGlowImage];
}

- (void)rebuildGlowImage {
    CGSize size = _glowView.bounds.size;
    if (size.width <= 0) return;
    DanteFacePalette pal = DantePalette(_faceStyle);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(size.width / 2, size.height / 2);
    CGFloat locs[] = {0, 0.55f, 1};
    UIBezierPath *all = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, size.width, size.height)];
    DanteFillRadial(ctx, all.CGPath,
                    @[DanteHex(pal.glow, 0.55f), DanteHex(pal.glow, 0.18f), DanteHex(pal.glow, 0)],
                    locs, c, MIN(size.width, size.height) / 2);
    _glowView.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
}

- (void)applyStyle {
    DanteFacePalette pal = DantePalette(_faceStyle);
    _spinner.strokeColor = DanteHex(pal.glow, 1).CGColor;
    _spinner.shadowColor = DanteHex(pal.glow, 1).CGColor;
    [self rebuildGlowImage];
    [_body setNeedsDisplay];
    [self restartAnimations];
}

- (void)restartAnimations {
    [_spinner removeAllAnimations];
    _spinner.hidden = !_spinning;
    if (_spinning) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(2 * M_PI);
        spin.duration = 1.1;
        spin.repeatCount = HUGE_VALF;
        [_spinner addAnimation:spin forKey:@"spin"];
    }

    [_glowView.layer removeAllAnimations];
    _glowView.hidden = (_faceStyle == DanteFaceGrey);
    _glowView.alpha = _glowing ? 1.0f : 0.45f;
    if (_glowing) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @0.4f;
        pulse.toValue = @1.0f;
        pulse.duration = 1.6;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_glowView.layer addAnimation:pulse forKey:@"pulse"];
    }
}

- (void)setTitle:(NSString *)title {
    if ([title isEqualToString:_title]) return;
    _title = [title copy];
    [_body setNeedsDisplay];
}

- (void)setSubtitle:(NSString *)subtitle {
    if ([subtitle isEqualToString:_subtitle]) return;
    _subtitle = [subtitle copy];
    [_body setNeedsDisplay];
}

- (void)setLockOpen:(BOOL)lockOpen {
    if (lockOpen == _lockOpen) return;
    _lockOpen = lockOpen;
    [_body setNeedsDisplay];
}

- (void)setFaceStyle:(DanteFaceStyle)faceStyle {
    if (faceStyle == _faceStyle) return;
    _faceStyle = faceStyle;
    [self applyStyle];
}

- (void)setSpinning:(BOOL)spinning {
    if (spinning == _spinning) return;
    _spinning = spinning;
    [self restartAnimations];
}

- (void)setGlowing:(BOOL)glowing {
    if (glowing == _glowing) return;
    _glowing = glowing;
    [self restartAnimations];
}

- (void)setHighlighted:(BOOL)highlighted {
    BOOL changed = (highlighted != self.highlighted);
    [super setHighlighted:highlighted];
    if (changed) [_body setNeedsDisplay];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect b = self.bounds;
    CGFloat R = MIN(b.size.width, b.size.height) / 2 - 14;
    CGFloat dx = point.x - b.size.width / 2, dy = point.y - b.size.height / 2;
    return dx * dx + dy * dy <= R * R;
}

@end
