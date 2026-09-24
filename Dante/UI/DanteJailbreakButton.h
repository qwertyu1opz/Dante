

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DanteFaceStyle) {
    DanteFaceRed = 0,   
    DanteFaceAmber,     
    DanteFaceGreen,     
    DanteFaceGrey       
};

@interface DanteJailbreakButton : UIControl

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, assign) DanteFaceStyle faceStyle;
@property (nonatomic, assign) BOOL lockOpen;    
@property (nonatomic, assign) BOOL spinning;    
@property (nonatomic, assign) BOOL glowing;     

- (void)restartAnimations;

@end
