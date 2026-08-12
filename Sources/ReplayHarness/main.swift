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

// Two shapes are accepted: a recorded event stream (fixtures), and the daemon's
// own decision log. The second is the one that matters — a real day cannot be
// tuned against if the format it is written in cannot be read back.
let summary: ReplaySummary
var records: [DecisionRecord] = []

if let events = try? Replay.parse(jsonl: contents), !events.isEmpty {
    (summary, records) = Replay.run(events: events, config: config)
} else {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let logged = contents
        .split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .compactMap { try? decoder.decode(DecisionRecord.self, from: Data($0.utf8)) }

    guard !logged.isEmpty else {
        FileHandle.standardError.write(Data("""
            cannot read \(path) as either an event stream or a decision log

            expected one JSON object per line, either
              {"at": "...", "event": {...}}                     (fixture)
              {"at": "...", "tierAssigned": "...", ...}          (decision log)

            """.utf8))
        exit(1)
    }

    records = logged
    summary = Replay.rerun(records: logged, config: config)
    FileHandle.standardError.write(
        Data("replaying \(logged.count) recorded decisions at the given budget\n".utf8))
}

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
