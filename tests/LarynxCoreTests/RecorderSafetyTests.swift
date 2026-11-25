import Foundation
import Testing
import LarynxObjC

/// AVAudioEngine reports some failures (a microphone whose format changed under it) as Objective-C exceptions, which
/// Swift can't catch: uncaught, a key press ended silently with nothing recorded. The recorder runs those calls inside
/// LarynxCatch, which must turn the exception into an error and let the caller go on.
@Test func anAudioEngineExceptionBecomesAnError() {
    let error = LarynxCatch {
        NSException(name: .internalInconsistencyException, reason: "required condition is false: format.sampleRate == hwFormat.sampleRate").raise()
    }
    #expect(error?.localizedDescription.contains("required condition is false") == true)
    var ran = false
    #expect(LarynxCatch { ran = true } == nil)
    #expect(ran)
}
