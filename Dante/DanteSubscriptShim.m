

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static id DanteArraySubscript(NSArray *self, SEL _cmd, NSUInteger idx) {
    return [self objectAtIndex:idx];
}

static void DanteMutableArraySetSubscript(NSMutableArray *self, SEL _cmd, id obj, NSUInteger idx) {
    if (idx == self.count) {
        [self addObject:obj];
    } else {
        [self replaceObjectAtIndex:idx withObject:obj];
    }
}

static id DanteDictionarySubscript(NSDictionary *self, SEL _cmd, id key) {
    return [self objectForKey:key];
}

static void DanteMutableDictionarySetSubscript(NSMutableDictionary *self, SEL _cmd, id obj, id key) {
    if (obj) {
        [self setObject:obj forKey:key];
    } else {
        [self removeObjectForKey:key];
    }
}

static void DanteAddIfMissing(Class cls, SEL sel, IMP imp, const char *types) {
    if (class_getInstanceMethod(cls, sel)) return;
    class_addMethod(cls, sel, imp, types);
}

__attribute__((constructor))
static void DanteInstallSubscriptShim(void) {
    DanteAddIfMissing([NSArray class], @selector(objectAtIndexedSubscript:),
                      (IMP)DanteArraySubscript, "@@:I");
    DanteAddIfMissing([NSMutableArray class], @selector(setObject:atIndexedSubscript:),
                      (IMP)DanteMutableArraySetSubscript, "v@:@I");
    DanteAddIfMissing([NSDictionary class], @selector(objectForKeyedSubscript:),
                      (IMP)DanteDictionarySubscript, "@@:@");
    DanteAddIfMissing([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:),
                      (IMP)DanteMutableDictionarySetSubscript, "v@:@@");
}
