import AVFoundation
import AppKit
import Foundation

/// Speaks through `AVSpeechSynthesizer` and plays system sounds as earcons.
///
/// Verified to work from a plain command-line daemon with no `NSApplication`;
/// the callbacks need a run loop, which `dispatchMain()` provides.
public final class SystemSpeaker: NSObject, Speaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let rate: Float

    /// System sounds rather than bundled assets: no files to ship, and they are
    /// already distinct from one another by design.
    private static let sounds: [Earcon: String] = [
        .offRoute: "Tink",
        .failure: "Basso",
        .acknowledged: "Pop",
    ]

    public init(
        voiceIdentifier: String? = nil,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate
    ) {
        self.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        self.rate = rate
        super.init()
    }

    public func say(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        // AVSpeechSynthesizer queues rather than overlapping, which is exactly
        // the one-utterance-at-a-time behaviour wanted here.
        synthesizer.speak(utterance)
    }

    public func play(_ earcon: Earcon) {
        guard let name = Self.sounds[earcon], let sound = NSSound(named: name) else { return }
        sound.play()
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
