

#import <Foundation/Foundation.h>

extern const uint16_t kDanteControlPort;   
extern const uint16_t kDanteSOCKSPort;     

NSString *DanteControlSend(NSString *command, NSTimeInterval timeout);

NSString *DanteLocalRequest(uint16_t port, NSString *line, BOOL readToEOF,
                            NSTimeInterval timeout);
