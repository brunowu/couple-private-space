import Foundation
import Domain

public enum ReminderState: String, Codable, Sendable { case needsPlanning, planned, scheduled, permissionBlocked, cancelled, elapsedUnknown, opened }
public struct ReminderIntent: Codable, Equatable, Sendable {
    public let wishID: UUID
    public let requestID: UUID
    public let receivedAt: Date
    public var fireAt: Date?
    public var state: ReminderState
    public init(wishID: UUID, receivedAt: Date) {
        self.wishID = wishID; self.receivedAt = receivedAt; self.requestID = UUID()
        self.fireAt = nil; self.state = .needsPlanning
    }
}
public struct ReminderPlanner {
    public init() {}
    /// Sample a persisted absolute instant from allowed intervals. Never called again on retry.
    public func plan(_ intent: ReminderIntent, allowed: [DateInterval], sample: Double) throws -> ReminderIntent {
        guard (0..<1).contains(sample), !allowed.isEmpty else { throw SpaceError.invalidInput }
        let sorted = allowed.sorted { $0.start < $1.start }
        guard sorted.allSatisfy({ $0.duration > 0 && $0.start >= intent.receivedAt && $0.duration.isFinite }) else { throw SpaceError.invalidInput }
        for i in 1..<sorted.count { guard sorted[i].start >= sorted[i-1].end else { throw SpaceError.invalidInput } }
        guard intent.state == .needsPlanning || intent.state == .permissionBlocked else { return intent }
        if intent.fireAt != nil { return intent }
        let total = sorted.reduce(0) { $0 + $1.duration }
        guard total.isFinite else { throw SpaceError.invalidInput }
        var offset = sample * total
        for interval in sorted {
            if offset < interval.duration {
                var planned = intent; planned.fireAt = interval.start.addingTimeInterval(offset); planned.state = .planned
                return planned
            }
            offset -= interval.duration
        }
        throw SpaceError.invalidInput
    }
}

public protocol ReminderScheduler: Sendable {
    func upsert(_ reminder: ReminderIntent) async throws
    func cancel(requestID: UUID) async
}
