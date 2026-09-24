

#import <UIKit/UIKit.h>

@interface DanteLCDView : UIView

@property (nonatomic, copy) NSString *headline;   
@property (nonatomic, copy) NSString *detail;     
@property (nonatomic, assign) BOOL showsProgress;

@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) BOOL daemonOn;
@property (nonatomic, assign) BOOL tunnelOn;
@property (nonatomic, assign) BOOL systemOn;

+ (CGFloat)preferredHeight;
- (void)restartAnimations;

@end
