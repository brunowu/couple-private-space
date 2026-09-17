import Foundation

/// Local reminder preferences, never included in shared events.
public struct QuietHours: Equatable, Sendable {
    public let enabled: Bool
    public let startHour: Int
    public let endHour: Int
    public init(enabled: Bool = false, startHour: Int = 22, endHour: Int = 8) {
        self.enabled = enabled; self.startHour = startHour; self.endHour = endHour
    }
    public func validate() throws {
        guard (0..<24).contains(startHour), (0..<24).contains(endHour), !enabled || startHour != endHour else { throw SpaceError.invalidInput }
    }
    public func allows(_ date: Date, calendar: Calendar) -> Bool {
        guard enabled else { return true }
        let hour = calendar.component(.hour, from: date)
        let quiet = startHour < endHour ? (startHour..<endHour).contains(hour) : hour >= startHour || hour < endHour
        return !quiet
    }
    public func allowedIntervals(start: Date, days: Int, calendar: Calendar = .current) throws -> [DateInterval] {
        try validate()
        guard (1...30).contains(days), start.timeIntervalSince1970.isFinite,
              let end = calendar.date(byAdding: .day, value: days, to: start) else { throw SpaceError.invalidInput }
        var result: [DateInterval] = [], cursor = start
        while cursor < end {
            guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { throw SpaceError.invalidInput }
            let next = min(hour.end, end)
            guard next > cursor else { throw SpaceError.invalidInput }
            if allows(cursor, calendar: calendar) {
                if let last = result.last, last.end == cursor {
                    result[result.count - 1] = DateInterval(start: last.start, end: next)
                } else { result.append(DateInterval(start: cursor, end: next)) }
            }
            cursor = next
        }
        return result
    }
}
