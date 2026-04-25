import AppKit

/// Color definitions for sticky note themes — same pastel colors in both light and dark mode
enum NoteColor: String, CaseIterable {
    case yellow, pink, blue, green, purple, orange

    var displayName: String {
        rawValue.capitalized
    }

    var color: NSColor {
        switch self {
        case .yellow: return NSColor(red: 1.0, green: 0.976, blue: 0.769, alpha: 1.0)   // #FFF9C4
        case .pink:   return NSColor(red: 0.988, green: 0.894, blue: 0.925, alpha: 1.0)  // #FCE4EC
        case .blue:   return NSColor(red: 0.891, green: 0.949, blue: 0.992, alpha: 1.0)  // #E3F2FD
        case .green:  return NSColor(red: 0.910, green: 0.961, blue: 0.914, alpha: 1.0)  // #E8F5E9
        case .purple: return NSColor(red: 0.953, green: 0.898, blue: 0.961, alpha: 1.0)  // #F3E5F5
        case .orange: return NSColor(red: 1.0, green: 0.953, blue: 0.878, alpha: 1.0)    // #FFF3E0
        }
    }

    var hex: String {
        switch self {
        case .yellow: return "#FFF9C4"
        case .pink:   return "#FCE4EC"
        case .blue:   return "#E3F2FD"
        case .green:  return "#E8F5E9"
        case .purple: return "#F3E5F5"
        case .orange: return "#FFF3E0"
        }
    }

    static func from(_ name: String) -> NoteColor {
        NoteColor(rawValue: name) ?? .yellow
    }

    static func color(from storedValue: String) -> NSColor {
        if let preset = NoteColor(rawValue: storedValue) {
            return preset.color
        }
        return NSColor(hex: storedValue) ?? .yellow
    }

    static func storageValue(for color: NSColor) -> String {
        let normalized = color.usingColorSpace(.deviceRGB) ?? color

        if let preset = NoteColor.allCases.first(where: { $0.color.isApproximatelyEqual(to: normalized) }) {
            return preset.rawValue
        }

        return normalized.hexString ?? NoteColor.yellow.rawValue
    }

    static func displayName(for storedValue: String) -> String {
        if let preset = NoteColor(rawValue: storedValue) {
            return preset.displayName
        }
        return "Custom"
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = UInt32(cleaned, radix: 16) else {
            return nil
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    func isApproximatelyEqual(to other: NSColor, tolerance: CGFloat = 0.01) -> Bool {
        guard let lhs = usingColorSpace(.deviceRGB),
              let rhs = other.usingColorSpace(.deviceRGB) else {
            return false
        }

        return abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }
}
