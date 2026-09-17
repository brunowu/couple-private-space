import Foundation

/// Civil dates stay unchanged when either partner travels to a different time zone.
public enum CivilDate {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    public static func parse(_ value: String) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard value.count == 10, let date = f.date(from: value), f.string(from: date) == value else { return nil }
        return date
    }
    public static var localCalendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = .current; return value
    }
    public static func string(_ date: Date, calendar source: Calendar = localCalendar) -> String {
        let c = source.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func localDate(_ value: String) -> Date? {
        guard let date = parse(value) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: calendar.dateComponents([.year, .month, .day], from: date))
    }
    public static func adding(days: Int, to value: String) -> String? {
        guard let date = parse(value), let next = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return string(next, calendar: calendar)
    }
    public static func distance(from: String, to: String) -> Int? {
        guard let a = parse(from), let b = parse(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}

/// Never encoded in an event. Sharing produces a separate, deliberately limited projection.
public struct CycleEntry: Codable, Equatable, Sendable {
    public var record: PrivateCycleRecord
    public var usualLength: Int
    public var shareDates: Bool
    public var shareEstimate: Bool
    public var shareStage: Bool
    public init(record: PrivateCycleRecord, usualLength: Int = 28, shareDates: Bool = false,
                shareEstimate: Bool = false, shareStage: Bool = false) {
        self.record = record; self.usualLength = usualLength; self.shareDates = shareDates
        self.shareEstimate = shareEstimate; self.shareStage = shareStage
    }
    public func validate(today: String) throws {
        guard CivilDate.parse(record.startDate) != nil, record.startDate <= today,
              (1...180).contains(usualLength), (record.note?.utf8.count ?? 0) <= 16_384 else { throw SpaceError.invalidInput }
        if let end = record.endDate {
            guard CivilDate.parse(end) != nil, end >= record.startDate, end <= today else { throw SpaceError.invalidInput }
        }
    }
    public var estimatedNextDate: String? { CivilDate.adding(days: usualLength, to: record.startDate) }
    public var stage: String { record.endDate == nil ? "尚未记录结束" : "已记录结束" }
    public func projection(owner: UUID, generation: UInt64) -> SharedCycleProjection {
        SharedCycleProjection(owner: owner, generation: generation, revision: 1,
            startDate: shareDates ? record.startDate : nil, endDate: shareDates ? record.endDate : nil,
            revoked: !shareDates && !shareEstimate && !shareStage,
            estimatedNextDate: shareEstimate ? estimatedNextDate : nil, stage: shareStage ? stage : nil)
    }
}

public struct AnniversaryContent: Codable, Equatable, Sendable {
    public static let relationshipID = UUID(uuidString: "9140EF09-9698-4D41-9537-4033AA987720")!
    public var title: String
    public var date: String
    public var repeatsYearly: Bool
    public var deleted: Bool
    public init(title: String, date: String, repeatsYearly: Bool = true, deleted: Bool = false) {
        self.title = title; self.date = date; self.repeatsYearly = repeatsYearly; self.deleted = deleted
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
              CivilDate.parse(date) != nil else { throw SpaceError.invalidInput }
    }
    /// February 29 is observed on February 28 in non-leap years.
    public func nextOccurrence(today: String) -> String? {
        guard let original = CivilDate.parse(date), let now = CivilDate.parse(today) else { return nil }
        if !repeatsYearly { return date >= today ? date : nil }
        let cal = CivilDate.calendar
        let parts = cal.dateComponents([.year, .month, .day], from: original)
        let year = max(parts.year!, cal.component(.year, from: now))
        for candidateYear in year...(year + 1) {
            let first = cal.date(from: DateComponents(year: candidateYear, month: parts.month!, day: 1))!
            let day = min(parts.day!, cal.range(of: .day, in: .month, for: first)!.count)
            let candidate = String(format: "%04d-%02d-%02d", candidateYear, parts.month!, day)
            if candidate >= today { return candidate }
        }
        return nil
    }
}
