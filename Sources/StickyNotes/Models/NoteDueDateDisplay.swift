import Foundation

enum NoteDueDateDisplay {
    static func date(from rawValue: String) -> Date? {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        return Calendar.current.date(from: DateComponents(
            year: year,
            month: month,
            day: day
        ))
    }

    static func dayOffset(for rawValue: String, now: Date = Date()) -> Int? {
        guard let dueDate = date(from: rawValue) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: today, to: dueDay).day
    }

    static func compactText(for rawValue: String, now: Date = Date()) -> String? {
        guard let dayOffset = dayOffset(for: rawValue, now: now) else { return nil }
        switch dayOffset {
        case 0:
            return "Today"
        case 1:
            return "Tomorrow"
        case 2...:
            return "\(dayOffset)d left"
        case -1:
            return "1d late"
        default:
            return "\(abs(dayOffset))d late"
        }
    }

    static func fullText(for rawValue: String, now: Date = Date()) -> String? {
        guard let dayOffset = dayOffset(for: rawValue, now: now) else { return nil }
        switch dayOffset {
        case 0:
            return "Due today"
        case 1:
            return "Due in 1 day"
        case 2...:
            return "Due in \(dayOffset) days"
        case -1:
            return "Overdue by 1 day"
        default:
            return "Overdue by \(abs(dayOffset)) days"
        }
    }
}
