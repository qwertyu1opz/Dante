

#ifdef __OBJC__

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if !defined(NS_ENUM)
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#define NS_OPTIONS(_type, _name) enum _name : _type _name; enum _name : _type
#endif

#endif 
