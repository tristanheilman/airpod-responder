import Foundation

public struct PolicyEngine: Sendable {
    public private(set) var registry = SessionRegistry()
    public private(set) var log: [DecisionRecord] = []

    private let reversibilityClassifier = ReversibilityClassifier()
    private let routeClassifier = RouteClassifier()
    private let tierAssigner = TierAssigner()

    private var budget: SpeechBudget
    private var coalescer: FailureCoalescer
    private var thrash: ThrashDetector
    private var muted = false
    private var questionInFlight = false

    public init(config: PolicyConfig = .default, startingAt: Date) {
        self.budget = SpeechBudget(
            capacity: config.speechCapacity,
            interval: config.speechInterval,
            startingAt: startingAt)
        self.coalescer = FailureCoalescer(window: config.failureWindow)
        self.thrash = ThrashDetector(
            repeatThreshold: config.thrashRepeatThreshold,
            minimumDuration: config.thrashMinimumDuration)
    }

    public mutating func setMuted(_ muted: Bool) { self.muted = muted }

    /// Called by the daemon once the live question has been answered or timed out.
    public mutating func resolveQuestion() { questionInFlight = false }

    public mutating func decide(_ stamped: StampedEvent) -> Decision {
        registry.apply(stamped)
        let event = stamped.event
        let session = registry.session(id: event.sessionID)!

        // A write is progress, so it clears any thrash streak.
        if event.kind == .preToolUse, event.filePath != nil {
            thrash.noteFileChanged(sessionID: event.sessionID)
        }

        let reversibility = reversibilityClassifier.classify(
            toolName: event.toolName, toolInput: event.toolInput)
        let route = routeClassifier.classify(
            toolName: event.toolName, toolInput: event.toolInput, session: session)
        var verdict = tierAssigner.assign(
            kind: event.kind, reversibility: reversibility, route: route, message: event.message)

        verdict = promoteThrash(verdict, event: event, at: stamped.at)

        let (delivered, suppression) = deliver(verdict, event: event, at: stamped.at)

        if delivered.isBlocking { questionInFlight = true }

        let decision = Decision(
            tier: delivered,
            permission: suppression == nil ? verdict.permission : demote(verdict.permission),
            utterance: delivered.isSpeech ? utterance(for: verdict, event: event) : nil,
            reason: suppression ?? verdict.reason,
            blocking: delivered.isBlocking)

        log.append(DecisionRecord(
            at: stamped.at,
            sessionID: event.sessionID,
            kind: event.kind,
            toolName: event.toolName,
            reversibility: describe(reversibility),
            route: describe(route),
            tierAssigned: verdict.tier,
            delivered: delivered,
            suppressedBecause: suppression,
            permission: decision.permission,
            reason: decision.reason))

        return decision
    }

    // MARK: - Delivery gates

    /// Returns the tier actually delivered, and why it differs if it does.
    private mutating func deliver(
        _ verdict: TierVerdict, event: HookEvent, at now: Date
    ) -> (Tier, String?) {
        if muted, verdict.tier.isSpeech || verdict.tier == .earcon {
            return (.silent, "muted — deferred to screen")
        }

        if verdict.tier.isBlocking, questionInFlight {
            // Stalling an agent behind another agent's ten-second exchange is
            // worse than showing a prompt.
            return (.silent, "another question is already in flight")
        }

        if verdict.tier == .earcon, isFailure(event.kind) {
            guard coalescer.admit(sessionID: event.sessionID, at: now) else {
                return (.silent, "coalesced into a recent failure earcon")
            }
            return (.earcon, nil)
        }

        let admitted = budget.admit(verdict.tier, at: now)
        return (admitted, admitted == verdict.tier ? nil : "speech budget spent")
    }

    private mutating func promoteThrash(
        _ verdict: TierVerdict, event: HookEvent, at now: Date
    ) -> TierVerdict {
        guard isFailure(event.kind) else { return verdict }

        let signature = ThrashDetector.signature(from: event.message)
        guard case .thrashing(_, let elapsed, _) = thrash.recordFailure(
            sessionID: event.sessionID, signature: signature, at: now)
        else { return verdict }

        let minutes = max(1, Int(elapsed / 60))
        return TierVerdict(
            tier: .speak,
            permission: verdict.permission,
            reason: "stuck on the same error for \(minutes) minute\(minutes == 1 ? "" : "s")")
    }

    private func isFailure(_ kind: HookEventKind) -> Bool {
        kind == .postToolUseFailure || kind == .stopFailure
    }

    /// Suppression never grants permission it would not otherwise have.
    private func demote(_ permission: PermissionDecision?) -> PermissionDecision? {
        guard let permission else { return nil }
        return permission == .allow ? .allow : .defer
    }

    // MARK: - Phrasing

    private func utterance(for verdict: TierVerdict, event: HookEvent) -> String {
        let session = registry.session(id: event.sessionID)
        let name = session.map { PathNormalizer.normalize($0.cwd) }
            .flatMap { $0.split(separator: "/").last.map(String.init) } ?? "a session"

        switch verdict.tier {
        case .decisionPoint:
            return "\(name) wants to \(verdict.reason). Approve?"
        case .needsInput:
            return "\(name) needs you."
        case .speak:
            return "\(name) has been \(verdict.reason)."
        case .earcon, .silentQueue, .silent:
            return ""
        }
    }

    private func describe(_ reversibility: Reversibility) -> String {
        switch reversibility {
        case .reversible: "reversible"
        case .irreversible(let reason): "irreversible: \(reason)"
        case .unknown(let reason): "unknown: \(reason)"
        }
    }

    private func describe(_ route: RouteStatus) -> String {
        switch route {
        case .onRoute: "on-route"
        case .offRoute(let reason): "off-route: \(reason)"
        }
    }
}
