import Foundation

/// Why a peer of this Mac's agent daemon (a chat opened with `--host`) did not count an allow
/// signed by this Mac (peer-route approvals, ``AcpmuxMacApprover``).
public nonisolated enum AgentPanePeerApprovals: Sendable, Equatable {
    /// The peer, by this Mac's daemon's name for it, has not enrolled this Mac.
    case notEnrolled(peer: String)
    /// The allow was not a one-time allow: only those count from this Mac.
    case onceOnly

    /// Enrolls this Mac's approver key on `peer` (`acpmux host approvals enroll PEER`, over the
    /// person's own ssh to that machine): nil once enrolled, else what failed, in that command's
    /// words. The app sets it at launch; nil offers no Enroll button.
    @MainActor public static var enroll: ((_ peer: String) async -> String?)?
}
