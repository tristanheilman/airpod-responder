import Foundation
import Testing
@testable import NavigatorAudio

@Suite struct InputDeviceMonitoring {
    @Test func neverTrapsAndAlwaysAnswers() {
        // Whatever the machine's audio configuration, this must return rather
        // than trap. Probed on a machine with no default input device, where the
        // CoreAudio query errors — so nil is a real outcome, not a bug.
        let result = InputDeviceMonitor.isInputInUse()
        #expect(result == nil || result == true || result == false)
    }

    @Test func failsOpenWhenItCannotTell() {
        // A detector that mutes on failure is indistinguishable from a broken
        // daemon: you would hear nothing and have no way to know why.
        #expect(InputDeviceMonitor.suppress(given: nil) == false)
    }

    @Test func suppressesOnlyWhenDefinitelyInUse() {
        #expect(InputDeviceMonitor.suppress(given: true) == true)
        #expect(InputDeviceMonitor.suppress(given: false) == false)
    }

    @Test func repeatedQueriesAreStable() {
        // Called before every utterance, so it must not be one-shot.
        let a = InputDeviceMonitor.isInputInUse()
        let b = InputDeviceMonitor.isInputInUse()
        #expect(a == b)
    }
}
