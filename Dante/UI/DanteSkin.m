

#import "DanteSkin.h"

UIColor *DanteHex(uint32_t rgb, CGFloat alpha) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0f
                           green:((rgb >> 8) & 0xff) / 255.0f
                            blue:(rgb & 0xff) / 255.0f
                           alpha:alpha];
}

CGFloat DanteScreenScale(void) {
    return [[UIScreen mainScreen] scale];
}

static CGGradientRef DanteGradientCreate(NSArray *colors, const CGFloat *locations) {
    NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *c in colors) [cg addObject:(__bridge id)c.CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, locations);
    CGColorSpaceRelease(space);
    return g;
}

void DanteFillLinear(CGContextRef ctx, CGPathRef path, NSArray *colors,
                     const CGFloat *locations, CGPoint start, CGPoint end) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGGradientRef g = DanteGradientCreate(colors, locations);
    CGContextDrawLinearGradient(ctx, g, start, end,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGContextRestoreGState(ctx);
}

void DanteFillRadial(CGContextRef ctx, CGPathRef path, NSArray *colors,
                     const CGFloat *locations, CGPoint center, CGFloat radius) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGGradientRef g = DanteGradientCreate(colors, locations);
    CGContextDrawRadialGradient(ctx, g, center, 0, center, radius,
                                kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGContextRestoreGState(ctx);
}

void DanteStrokeLinear(CGContextRef ctx, CGPathRef path, CGFloat lineWidth,
                       NSArray *colors, const CGFloat *locations) {
    CGRect box = CGPathGetBoundingBox(path);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextSetLineWidth(ctx, lineWidth);
    CGContextReplacePathWithStrokedPath(ctx);
    CGContextClip(ctx);
    CGGradientRef g = DanteGradientCreate(colors, locations);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, CGRectGetMinY(box)),
                                CGPointMake(0, CGRectGetMaxY(box)), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(ctx);
}

void DanteInnerShadow(CGContextRef ctx, CGPathRef path, UIColor *color,
                      CGSize offset, CGFloat blur) {
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    
    
    CGFloat pad = blur * 3 + fabsf((float)offset.width) + fabsf((float)offset.height) + 10;
    CGMutablePathRef outer = CGPathCreateMutable();
    CGPathAddRect(outer, NULL, CGRectInset(CGPathGetBoundingBox(path), -pad, -pad));
    CGPathAddPath(outer, NULL, path);
    CGContextSetShadowWithColor(ctx, offset, blur, color.CGColor);
    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextAddPath(ctx, outer);
    CGContextEOFillPath(ctx);
    CGPathRelease(outer);
    CGContextRestoreGState(ctx);
}

void DanteDrawText(NSString *text, CGRect rect, UIFont *font, UIColor *color,
                   UIColor *shadowColor, CGSize shadowOffset) {
    if (text.length == 0) return;
    if (shadowColor) {
        [shadowColor set];
        [text drawInRect:CGRectOffset(rect, shadowOffset.width, shadowOffset.height)
                withFont:font lineBreakMode:UILineBreakModeClip
               alignment:UITextAlignmentCenter];
    }
    [color set];
    [text drawInRect:rect withFont:font lineBreakMode:UILineBreakModeClip
           alignment:UITextAlignmentCenter];
}

void DanteDrawScrew(CGContextRef ctx, CGPoint center, CGFloat r, CGFloat angle) {
    
    UIBezierPath *socket = DanteCircle(center, r + 1.0f);
    DanteFillLinear(ctx, socket.CGPath, @[DanteHex(0x000000, 0.55f), DanteHex(0xffffff, 0.18f)],
                    NULL, CGPointMake(0, center.y - r), CGPointMake(0, center.y + r));
    
    UIBezierPath *head = DanteCircle(center, r);
    CGFloat locs[] = {0, 0.6f, 1};
    DanteFillRadial(ctx, head.CGPath, @[DanteHex(0xf4f4f4, 1), DanteHex(0xa9a9a9, 1), DanteHex(0x5c5c5c, 1)],
                    locs, CGPointMake(center.x - r * 0.3f, center.y - r * 0.35f), r * 1.4f);
    
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, center.x, center.y);
    CGContextRotateCTM(ctx, angle);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineWidth(ctx, MAX(1.0f, r * 0.28f));
    CGContextSetStrokeColorWithColor(ctx, DanteHex(0x2a2a2a, 0.9f).CGColor);
    CGContextMoveToPoint(ctx, -r * 0.7f, 0);
    CGContextAddLineToPoint(ctx, r * 0.7f, 0);
    CGContextStrokePath(ctx);
    CGContextSetStrokeColorWithColor(ctx, DanteHex(0xffffff, 0.45f).CGColor);
    CGContextSetLineWidth(ctx, 0.5f);
    CGContextMoveToPoint(ctx, -r * 0.7f, r * 0.2f);
    CGContextAddLineToPoint(ctx, r * 0.7f, r * 0.2f);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

UIBezierPath *DanteCircle(CGPoint center, CGFloat r) {
    return [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(center.x - r, center.y - r, 2 * r, 2 * r)];
}

UIBezierPath *DanteRoundRect(CGRect rect, CGFloat radius) {
    return [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
}

UIFont *DanteFitFont(NSString *text, NSString *fontName, CGFloat size,
                     CGFloat minSize, CGFloat maxWidth) {
    UIFont *font = nil;
    for (CGFloat s = size; s >= minSize; s -= 1.0f) {
        font = fontName ? [UIFont fontWithName:fontName size:s] : [UIFont boldSystemFontOfSize:s];
        if (!font) font = [UIFont boldSystemFontOfSize:s];
        if ([text sizeWithFont:font].width <= maxWidth) return font;
    }
    return font;
}

static CGImageRef DanteMetalImage(BOOL horizontal) {
    
    
    static CGImageRef vertical, rotated;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *src = [UIImage imageNamed:@"DanteMetal.jpg"];
        if (!src.CGImage) return;
        vertical = CGImageRetain(src.CGImage);
        size_t w = CGImageGetWidth(vertical), h = CGImageGetHeight(vertical);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef c = CGBitmapContextCreate(NULL, h, w, 8, h * 4, cs,
                                               kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(cs);
        if (!c) return;
        CGContextTranslateCTM(c, h, 0);
        CGContextRotateCTM(c, (CGFloat)M_PI_2);
        CGContextDrawImage(c, CGRectMake(0, 0, w, h), vertical);
        rotated = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
    });
    return horizontal ? rotated : vertical;
}

void DanteFillBrushedMetal(CGContextRef ctx, CGPathRef path, CGRect rect, BOOL horizontal) {
    CGImageRef img = DanteMetalImage(horizontal);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    if (img) {
        
        CGFloat iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
        CGFloat scale = MAX(rect.size.width / iw, rect.size.height / ih);
        CGRect draw = CGRectMake(CGRectGetMidX(rect) - iw * scale / 2,
                                 CGRectGetMidY(rect) - ih * scale / 2, iw * scale, ih * scale);
        
        CGContextTranslateCTM(ctx, 0, CGRectGetMinY(draw) * 2 + draw.size.height);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, draw, img);
    } else {
        CGContextSetFillColorWithColor(ctx, DanteHex(0x8a8a8a, 1).CGColor);
        CGContextFillRect(ctx, rect);
    }
    CGContextRestoreGState(ctx);
}

UIImage *DanteScanlineImage(CGFloat alpha) {
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 3), NO, 0);
    [[UIColor colorWithWhite:0 alpha:alpha] setFill];
    UIRectFill(CGRectMake(0, 2, 1, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}
