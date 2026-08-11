import Foundation

/// Whether an action can be quietly undone on this machine.
///
/// `.unknown` is a first-class outcome, not a failure. It is the honest answer
/// for anything the rule table does not cover, and it routes to `defer` — which
/// falls back to the on-screen prompt the user would have seen anyway.
public enum Reversibility: Sendable, Equatable {
    case reversible
    case irreversible(reason: String)
    case unknown(reason: String)
}
