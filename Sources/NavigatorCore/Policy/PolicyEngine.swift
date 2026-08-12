import Foundation

public struct PolicyEngine: Sendable {
    public private(set) var registry = SessionRegistry()
    public private(set) var log: [DecisionRecord] = []

    private let reversibilityClassifier: ReversibilityClassifier
    private let routeClassifier = RouteClassifier()
    private let tierAssigner = TierAssigner()

    private var budget: SpeechBudget
    private var coalescer: FailureCoalescer
    private var thrash: ThrashDetector
    private var muted = false
    /// When the live question was asked. Nil means none is outstanding.
    private var questionAskedAt: Date?
    private let questionDeadline: TimeInterval
    private let recentLogCapacity: Int

    public init(
        config: PolicyConfig = .default,
        userRules: UserRules = UserRules(),
        startingAt: Date
    ) {
        self.reversibilityClassifier = ReversibilityClassifier(userRules: userRules)
        self.questionDeadline = config.questionDeadline
        self.recentLogCapacity = max(1, config.recentLogCapacity)
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

    /// Called by the daemon once the live question has been answered.
    public mutating func resolveQuestion() { questionAskedAt = nil }

    public mutating func decide(_ stamped: StampedEvent) -> Decision {
        registry.apply(stamped)
        let event = stamped.event
        let session = registry.session(id: event.sessionID)!

        // Per-session bookkeeping outlives the session unless it is told not to.
        // Each of these is one small entry, which is exactly why nobody notices
        // them accumulating for the life of the daemon.
        if event.kind == .sessionEnd {
            coalescer.forget(sessionID: event.sessionID)
            thrash.forget(sessionID: event.sessionID)
        }

        // A write is progress, so it clears any thrash streak.
        if event.kind == .preToolUse, event.filePath != nil {
            thrash.noteFileChanged(sessionID: event.sessionID)
        }

        let reversibility = reversibilityClassifier.classify(
            toolName: event.toolName, toolInput: event.toolInput)
        let route = routeClassifier.classify(
            toolName: event.toolName, toolInput: event.toolInput, session: session)
        var verdict = tierAssigner.assign(
            kind: event.kind, reversibility: reversibility, route: route,
            notificationType: event.notificationType)

        verdict = promoteThrash(verdict, event: event, at: stamped.at)

        let (delivered, suppression) = deliver(verdict, event: event, at: stamped.at)

        if delivered.isBlocking { questionAskedAt = stamped.at }

        let decision = Decision(
            tier: delivered,
            intendedTier: verdict.tier,
            permission: suppression == nil ? verdict.permission : demote(verdict.permission),
            // Phrased from the *intended* tier, not the delivered one. A muted
            // or budget-suppressed decision still needs its words written down,
            // or catch-up has nothing to read back — only the reason it was
            // suppressed, which is not the part you missed.
            utterance: verdict.tier.isSpeech ? utterance(for: verdict, event: event) : nil,
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

        // Only the newest record is ever read from here, and the durable copy is
        // on disk. Keeping the rest is a leak in a process that now runs for
        // weeks rather than the seconds it used to live in tests.
        if log.count > recentLogCapacity {
            log.removeFirst(log.count - recentLogCapacity)
        }

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

        if verdict.tier.isBlocking, let asked = questionAskedAt,
           now.timeIntervalSince(asked) < questionDeadline {
            // Stalling an agent behind another agent's ten-second exchange is
            // worse than showing a prompt. Bounded by the deadline: an
            // unanswered question must stop counting, or the first one ever
            // asked silences every one that follows.
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

        // `error`, not `message` — failures carry their detail in `error`, and
        // fingerprinting the always-nil field would collapse every failure to
        // one signature, firing thrash on three unrelated errors.
        let signature = ThrashDetector.signature(from: event.failureDetail)
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
