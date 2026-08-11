import Foundation
import NavigatorCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("""
    usage: replay <events.jsonl> [--speech-interval SECONDS] [--records]

      --speech-interval  seconds between non-blocking utterances (default 300)
      --records          print every decision record as JSON, not just the summary

    """.utf8))
    exit(2)
}

let path = arguments[1]
var config = PolicyConfig.default
if let index = arguments.firstIndex(of: "--speech-interval"),
   index + 1 < arguments.count,
   let seconds = TimeInterval(arguments[index + 1]) {
    config.speechInterval = seconds
}

guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(1)
}

let events: [StampedEvent]
do {
    events = try Replay.parse(jsonl: contents)
} catch {
    FileHandle.standardError.write(Data("cannot parse \(path): \(error)\n".utf8))
    exit(1)
}

let (summary, records) = Replay.run(events: events, config: config)

if arguments.contains("--records") {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for record in records {
        if let data = try? encoder.encode(record),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }
}

print("""
events        \(summary.totalEvents)
spoken        \(summary.spoken)
earcons       \(summary.earcons)
queued        \(summary.queued)
silent        \(summary.silent)
suppressed    \(summary.suppressed)
blocking      \(summary.blocking)
utterances/hr \(String(format: "%.2f", summary.utterancesPerHour))
""")
