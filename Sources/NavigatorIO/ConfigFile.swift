import Foundation
import NavigatorCore

/// Reads `~/.claude/navigator/config.json`.
///
/// Exists so the budget can be changed between putting the AirPods in and
/// taking them out. Requiring a rebuild to try a different rate would mean the
/// rate never gets tried.
public enum ConfigFile {
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
        // emitDecisions is deliberately not readable from the file. The closed
        // gate is this build's safety guarantee and should not be reachable by
        // editing JSON.
        return config
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
        speech budget    1 utterance per \(Int(config.speechInterval))s
        failure window   \(Int(config.failureWindow))s
        thrash           \(config.thrashRepeatThreshold) repeats over \(Int(config.thrashMinimumDuration))s
        """
    }
}
