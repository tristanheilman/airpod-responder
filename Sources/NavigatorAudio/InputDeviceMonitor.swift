import CoreAudio
import Foundation

/// Detects whether something else is using the microphone — a call, most likely.
///
/// Uses CoreAudio property queries rather than `AVCaptureDevice`, which can
/// trigger a microphone permission prompt. A background daemon asking for mic
/// access on first run would be alarming and unnecessary: nothing here records.
public enum InputDeviceMonitor {
    /// `nil` means the question could not be answered. That is a real and
    /// ordinary outcome — a machine with no default input device returns it,
    /// which is exactly what the development machine did when this was probed.
    public static func isInputInUse() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let found = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)

        guard found == noErr, device != AudioDeviceID(0) else { return nil }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let queried = AudioObjectGetPropertyData(
            device, &runningAddress, 0, nil, &runningSize, &running)

        guard queried == noErr else { return nil }
        return running != 0
    }

    /// Fails open by design.
    ///
    /// An undetectable state must not silence the tool: a daemon that goes quiet
    /// because a CoreAudio query returned an unexpected status is
    /// indistinguishable from a daemon that has crashed, and you would have no
    /// way to tell which.
    public static func suppress(given inUse: Bool?) -> Bool {
        inUse ?? false
    }

    public static func shouldSuppressAudio() -> Bool {
        suppress(given: isInputInUse())
    }
}
