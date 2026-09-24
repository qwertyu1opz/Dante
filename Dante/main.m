

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "DanteDaemon.h"

int main(int argc, char *argv[]) {
    
    FILE *f = fopen("/tmp/dante_boot.log", "a");
    if (f) { fprintf(f, "main() entered\n"); fclose(f); }
    
    
    if (argc > 1 && strcmp(argv[1], "--daemon") == 0) {
        @autoreleasepool {
            [DanteDaemon runForever];
        }
        return 0;
    }
    @autoreleasepool {
        int ret = UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
        f = fopen("/tmp/dante_boot.log", "a");
        if (f) { fprintf(f, "UIApplicationMain returned %d\n", ret); fclose(f); }
        return ret;
    }
}
