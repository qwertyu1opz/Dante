

#import <UIKit/UIKit.h>

UIColor *DanteHex(uint32_t rgb, CGFloat alpha);

void DanteFillLinear(CGContextRef ctx, CGPathRef path, NSArray *colors,
                     const CGFloat *locations, CGPoint start, CGPoint end);

void DanteFillRadial(CGContextRef ctx, CGPathRef path, NSArray *colors,
                     const CGFloat *locations, CGPoint center, CGFloat radius);

void DanteStrokeLinear(CGContextRef ctx, CGPathRef path, CGFloat lineWidth,
                       NSArray *colors, const CGFloat *locations);

void DanteInnerShadow(CGContextRef ctx, CGPathRef path, UIColor *color,
                      CGSize offset, CGFloat blur);

void DanteDrawText(NSString *text, CGRect rect, UIFont *font, UIColor *color,
                   UIColor *shadowColor, CGSize shadowOffset);

void DanteDrawScrew(CGContextRef ctx, CGPoint center, CGFloat r, CGFloat angle);

UIBezierPath *DanteCircle(CGPoint center, CGFloat r);
UIBezierPath *DanteRoundRect(CGRect rect, CGFloat radius);

UIFont *DanteFitFont(NSString *text, NSString *fontName, CGFloat size,
                     CGFloat minSize, CGFloat maxWidth);

UIImage *DanteScanlineImage(CGFloat alpha);

void DanteFillBrushedMetal(CGContextRef ctx, CGPathRef path, CGRect rect, BOOL horizontal);

CGFloat DanteScreenScale(void);
