import Foundation

public struct TierAssigner: Sendable {
    /// Notification payloads that mean the agent is stopped and waiting on you.
    private static let inputNeededMarkers = ["agent_needs_input", "permission_prompt"]

    public init() {}

    public func assign(
        kind: HookEventKind,
        reversibility: Reversibility,
        route: RouteStatus,
        message: String?
    ) -> TierVerdict {
        switch kind {
        case .preToolUse:
            return assignToolCall(reversibility: reversibility, route: route)

        case .notification:
            let matched = Self.inputNeededMarkers.contains {
                message?.contains($0) ?? false
            }
            return TierVerdict(
                tier: matched ? .needsInput : .silentQueue,
                permission: nil,
                reason: matched ? "agent is waiting on you" : "unmatched notification")

        case .elicitation:
            return TierVerdict(tier: .needsInput, permission: nil, reason: "agent asked a question")

        case .postToolUseFailure, .stopFailure:
            return TierVerdict(tier: .earcon, permission: nil, reason: "failure")

        case .stop, .taskCompleted, .subagentStop, .teammateIdle:
            return TierVerdict(tier: .silentQueue, permission: nil, reason: "completion")

        case .fileChanged:
            guard case .offRoute(let why) = route else {
                return TierVerdict(tier: .silent, permission: nil, reason: "on-route change")
            }
            if case .irreversible(let how) = reversibility {
                return TierVerdict(tier: .speak, permission: nil, reason: "\(why) — \(how)")
            }
            return TierVerdict(tier: .earcon, permission: nil, reason: why)

        case .sessionStart, .sessionEnd, .userPromptSubmit:
            return TierVerdict(tier: .silent, permission: nil, reason: "lifecycle")
        }
    }

    private func assignToolCall(
        reversibility: Reversibility, route: RouteStatus
    ) -> TierVerdict {
        // Uncertainty never speaks. Deferring surfaces the normal on-screen
        // prompt, which already says everything a spoken version would.
        if case .unknown(let why) = reversibility {
            return TierVerdict(tier: .silent, permission: .defer, reason: why)
        }

        switch (reversibility, route) {
        case (.reversible, .onRoute):
            return TierVerdict(tier: .silent, permission: .allow, reason: "reversible, on route")

        case (.reversible, .offRoute(let why)):
            return TierVerdict(tier: .earcon, permission: .defer, reason: why)

        case (.irreversible(let how), .onRoute):
            return TierVerdict(tier: .decisionPoint, permission: .defer, reason: how)

        case (.irreversible(let how), .offRoute(let why)):
            // Lead with the route reason: that it is off-route is the surprising
            // part, and it is what you need first to decide.
            return TierVerdict(tier: .decisionPoint, permission: .defer, reason: "\(why) — \(how)")

        case (.unknown, _):
            return TierVerdict(tier: .silent, permission: .defer, reason: "unknown")
        }
    }
}
