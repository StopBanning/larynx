#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, as an NSError, or nil. Swift can't catch these, and
/// AVAudioEngine raises them (a microphone whose format changed under it, for one); uncaught, they end the call
/// silently and the next press does the same.
NSError * _Nullable LarynxCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
