#import "LarynxObjC.h"

NSError * _Nullable LarynxCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSError errorWithDomain:@"Larynx.ObjCException" code:1
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]}];
    }
}
