// RapooOperationTracker.swift
import Foundation

/// Tracks pending Rapoo hardware writes so the UI can show
/// pending/success/failure/interrupted without ever inferring completion from
/// the value of a status register (an identical value or a failure would leave
/// a spinner hanging forever).
///
/// Contract (cell UI-00):
/// - every operation carries an `id`, the connection generation it was
///   accepted in, and a token that must come back with the callback;
/// - outcomes arrive only through the explicit callback;
/// - a new connection generation (disconnect/reconnect) interrupts everything
///   pending and makes callbacks from that point stale;
/// - a `begin` with the same `id` replaces the pending operation: the old
///   callback is ignored on arrival (it does not block anything, it just
///   stops mattering), so two writes never race for the same control.
final class RapooOperationTracker {
    struct Snapshot: Equatable {
        var outcome: Outcome
        var generation: Int
        var token: Int
    }

    enum Outcome: Equatable {
        case pending
        case success
        case failure(RapooHidService.RapooError)
        case interrupted
    }

    var onChange: (() -> Void)?

    /// Connection generation, mirrored from `RapooHidService.generation`.
    private(set) var generation = 0
    private(set) var snapshots: [String: Snapshot] = [:]
    private var nextToken = 0

    /// Starts (or restarts) an operation bounded to the current generation,
    /// returning the token for the callback. A previous pending operation with
    /// the same id is invalidated — its stale callback will be ignored.
    @discardableResult
    func begin(_ id: String) -> Int {
        nextToken += 1
        snapshots[id] = Snapshot(outcome: .pending, generation: generation, token: nextToken)
        onChange?()
        return nextToken
    }

    /// Records the outcome. Returns false — touching nothing — when the
    /// callback is stale: token mismatch (invalidated by a newer begin),
    /// generation mismatch (callback from a dead connection), or an operation
    /// already finished.
    @discardableResult
    func finish(_ id: String, token: Int, atGeneration generation: Int,
                failure error: RapooHidService.RapooError?) -> Bool {
        guard var snapshot = snapshots[id],
              snapshot.token == token,
              snapshot.generation == generation,
              snapshot.outcome == .pending else { return false }
        snapshot.outcome = error.map(Outcome.failure) ?? .success
        snapshots[id] = snapshot
        onChange?()
        return true
    }

    /// Adopts the connection generation reported by the service. On any
    /// change, pending operations become `.interrupted` (the connection that
    /// could complete them is gone).
    func adoptConnectionGeneration(_ newGeneration: Int) {
        guard newGeneration != generation else { return }
        generation = newGeneration
        var changed = false
        for id in snapshots.keys where snapshots[id]?.outcome == .pending {
            snapshots[id]?.outcome = .interrupted
            changed = true
        }
        if changed { onChange?() }
    }
}

/// Production hop that delivers a write outcome to the UI. Both the error
/// and the generation were captured **before** this hop (on the serial IO
/// queue); the closure below only carries immutable values — it never
/// re-reads mutable service state at delivery time. That immutability is
/// what makes a callback delivered late (after a disconnect/reconnect or a
/// newer operation) impossible to mislabel with the current generation.
enum RapooOperationDelivery {
    typealias Completion = @Sendable (RapooHidService.RapooError?, Int) -> Void

    static func deliver(_ error: RapooHidService.RapooError?, generation: Int,
                        on queue: DispatchQueue = .main, to completion: Completion?) {
        guard let completion else { return }
        queue.async { completion(error, generation) }
    }
}

/// Pure coordinator used by `setDpiTable` in **production**: it attempts X;
/// Y only when X landed and the firmware keeps a separate Y block
/// (`scale <= 1`); the first (X) error is authoritative and is never replaced
/// by Y's outcome.
enum RapooWritePlan {
    static func dpiWriteOutcome(scale: Int,
                                writeX: () -> RapooHidService.RapooError?,
                                writeY: () -> RapooHidService.RapooError?) -> RapooHidService.RapooError? {
        let xError = writeX()
        // The first error wins: Y is never attempted after a failed X, so no
        // later success can mask it.
        guard xError == nil else { return xError }
        // Newer firmware leaves the Y block all-FF: X alone is complete.
        guard scale <= 1 else { return nil }
        return writeY()
    }
}
