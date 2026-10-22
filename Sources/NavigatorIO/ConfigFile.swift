import Foundation
import NavigatorCore

/// Reads `~/.claude/navigator/config.json`.
///
/// Exists so the budget can be changed between putting the AirPods in and
/// taking them out. Requiring a rebuild to try a different rate would mean the
/// rate never gets tried.
public enum ConfigFile {
    /// The second key the gate needs. Named so it cannot be set by accident,
    /// by copying an example, or by a typo while changing a number next to it.
    public static let acknowledgementKey = "iUnderstandThisAnswersClaudeCode"

    public static func load(from url: URL) -> PolicyConfig {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .default }

        // Applied over the defaults rather than decoded wholesale, so a file
        // naming one key leaves the rest alone.
        var config = PolicyConfig.default
        if let v = raw["speechCapacity"] as? Double { config.speechCapacity = v }
        if let v = raw["speechInterval"] as? Double { config.speechInterval = v }
        if let v = raw["failureWindow"] as? Double { config.failureWindow = v }
        if let v = raw["thrashRepeatThreshold"] as? Int { config.thrashRepeatThreshold = v }
        if let v = raw["thrashMinimumDuration"] as? Double { config.thrashMinimumDuration = v }
        if let v = raw["autoAllow"] as? Bool { config.autoAllow = v }

        // The gate opens only when both keys say so. One is the switch; the
        // other is proof the switch was meant. Either alone does nothing.
        config.emitDecisions = raw["emitDecisions"] as? Bool == true
            && raw[acknowledgementKey] as? Bool == true

        // Derived, never read. It drifted from reality once when it was set by
        // hand; now it follows the gate, and the terminal — which always
        // exists while the daemon runs — is the answer source it assumes.
        config.canAcceptAnswers = config.emitDecisions
        return config
    }

    /// The raw file with just the gate keys changed. Everything else — a
    /// hand-tuned budget, a rule — is left exactly as it was.
    public static func gate(_ raw: [String: Any], open: Bool) -> [String: Any] {
        var result = raw
        if open {
            result["emitDecisions"] = true
            result[acknowledgementKey] = true
        } else {
            result.removeValue(forKey: "emitDecisions")
            result.removeValue(forKey: acknowledgementKey)
        }
        return result
    }

    public static func rawContents(of url: URL) -> [String: Any] {
        (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    public static func writeRaw(_ raw: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    public static func write(_ config: PolicyConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url)
    }

    public static func describe(_ config: PolicyConfig) -> String {
        """
        wire gate        \(config.emitDecisions
            ? "OPEN — your answers reach Claude Code"
            : "CLOSED — no decisions are returned to Claude Code")
        auto-allow       \(config.autoAllow && config.emitDecisions ? "on" : "off")
        speech budget    1 utterance per \(Int(config.speechInterval))s
        failure window   \(Int(config.failureWindow))s
        thrash           \(config.thrashRepeatThreshold) repeats over \(Int(config.thrashMinimumDuration))s
        """
    }
}
