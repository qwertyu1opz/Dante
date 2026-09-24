

#import <UIKit/UIKit.h>

@interface DanteMetalButton : UIControl
@property (nonatomic, copy) NSString *title;
@end

@interface DanteChromeLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@end

UIImage *DanteGlossyIcon(UIImage *source, CGFloat side);
