

#import "DanteChrome.h"
#import "DanteSkin.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Металлическая кнопка

@implementation DanteMetalButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    [self setNeedsDisplay];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect b = CGRectInset(self.bounds, 4, 3);
    b.size.height -= 3;
    BOOL down = self.highlighted;
    UIBezierPath *pill = DanteRoundRect(b, 11);

    
    
    self.layer.shadowPath = pill.CGPath;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, down ? 1 : 3);
    self.layer.shadowRadius = down ? 1.5f : 3;
    self.layer.shadowOpacity = 0.85f;

    
    DanteFillBrushedMetal(ctx, pill.CGPath, b, YES);
    CGFloat locs[] = {0, 0.5f, 1};
    NSArray *colors = down
        ? @[DanteHex(0x000000, 0.4f), DanteHex(0x000000, 0.62f), DanteHex(0x000000, 0.8f)]
        : @[DanteHex(0x000000, 0.18f), DanteHex(0x000000, 0.45f), DanteHex(0x000000, 0.7f)];
    DanteFillLinear(ctx, pill.CGPath, colors, locs,
                    CGPointMake(0, CGRectGetMinY(b)), CGPointMake(0, CGRectGetMaxY(b)));
    CGFloat edgeLocs[] = {0, 0.15f, 1};
    UIBezierPath *edge = DanteRoundRect(CGRectInset(b, 0.5f, 0.5f), 10.5f);
    DanteStrokeLinear(ctx, edge.CGPath, 1,
                      down ? @[DanteHex(0xffffff, 0.2f), DanteHex(0xffffff, 0.04f), DanteHex(0x000000, 0.6f)]
                           : @[DanteHex(0xffffff, 0.45f), DanteHex(0xffffff, 0.08f), DanteHex(0x000000, 0.6f)],
                      edgeLocs);

    UIFont *font = DanteFitFont(_title, @"HelveticaNeue-Bold", 16, 11, b.size.width - 24);
    CGRect textRect = CGRectMake(b.origin.x, CGRectGetMidY(b) - font.lineHeight / 2 + (down ? 1 : 0),
                                 b.size.width, font.lineHeight);
    
    DanteDrawText(_title, textRect, font, DanteHex(self.enabled ? 0xd6d6d6 : 0x6a6a6a, 1),
                  DanteHex(0x000000, 0.85f), CGSizeMake(0, -1));
}

@end

#pragma mark - Хромированная надпись

@implementation DanteChromeLabel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setText:(NSString *)text {
    _text = [text copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (_text.length == 0 || !_font) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGSize size = [_text sizeWithFont:_font];
    CGPoint origin = CGPointMake(0, (self.bounds.size.height - size.height) / 2);

    
    [DanteHex(0x000000, 0.9f) set];
    [_text drawAtPoint:CGPointMake(origin.x, origin.y + 3) withFont:_font];

    
    
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, 0);
    CGContextRef tctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] set];
    [_text drawAtPoint:origin withFont:_font];
    CGContextSetBlendMode(tctx, kCGBlendModeSourceIn);
    CGFloat locs[] = {0, 0.45f, 0.52f, 0.8f, 1};
    UIBezierPath *all = [UIBezierPath bezierPathWithRect:self.bounds];
    DanteFillLinear(tctx, all.CGPath,
                    @[DanteHex(0xffffff, 1), DanteHex(0xd4d4d4, 1), DanteHex(0x7a7a7a, 1),
                      DanteHex(0xb8b8b8, 1), DanteHex(0xf2f2f2, 1)],
                    locs, CGPointMake(0, origin.y + size.height * 0.2f),
                    CGPointMake(0, origin.y + size.height * 0.85f));
    UIImage *chrome = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [chrome drawInRect:self.bounds];
    (void)ctx;
}

@end

#pragma mark - Иконка

UIImage *DanteGlossyIcon(UIImage *source, CGFloat side) {
    if (!source) return nil;
    CGRect r = CGRectMake(0, 0, side, side);
    UIGraphicsBeginImageContextWithOptions(r.size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *shape = DanteRoundRect(r, side * 0.175f);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, shape.CGPath);
    CGContextClip(ctx);
    [source drawInRect:r];
    
    UIBezierPath *gloss = [UIBezierPath bezierPath];
    [gloss moveToPoint:CGPointMake(0, 0)];
    [gloss addLineToPoint:CGPointMake(side, 0)];
    [gloss addLineToPoint:CGPointMake(side, side * 0.42f)];
    [gloss addQuadCurveToPoint:CGPointMake(0, side * 0.42f) controlPoint:CGPointMake(side / 2, side * 0.56f)];
    [gloss closePath];
    DanteFillLinear(ctx, gloss.CGPath, @[DanteHex(0xffffff, 0.5f), DanteHex(0xffffff, 0.08f)], NULL,
                    CGPointZero, CGPointMake(0, side * 0.5f));
    CGContextRestoreGState(ctx);
    UIBezierPath *border = DanteRoundRect(CGRectInset(r, 0.5f, 0.5f), side * 0.175f);
    CGContextAddPath(ctx, border.CGPath);
    CGContextSetLineWidth(ctx, 1);
    CGContextSetStrokeColorWithColor(ctx, DanteHex(0x000000, 0.5f).CGColor);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}
