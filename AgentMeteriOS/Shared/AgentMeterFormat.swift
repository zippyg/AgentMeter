import Foundation

enum AgentMeterFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "NA" }
        return "\(Int(value.rounded()))%"
    }

    static func compactNumber(_ value: Int?) -> String {
        guard let value else { return "NA" }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func money(_ value: Double?, currencyCode: String = "USD") -> String {
        guard let value else { return "NA" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func relative(_ date: Date, from reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    static func resetText(for window: AgentMeterPhoneUsageWindow, from reference: Date) -> String? {
        self.resetText(
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            from: reference)
    }

    static func resetText(resetsAt: Date?, resetDescription: String?, from reference: Date) -> String? {
        if let resetsAt {
            let seconds = resetsAt.timeIntervalSince(reference)
            if seconds > 0 {
                return "Resets in \(Self.duration(seconds))"
            }
            return "Reset \(Self.relative(resetsAt, from: reference))"
        }

        guard let resetDescription = resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resetDescription.isEmpty
        else {
            return nil
        }

        let lowercased = resetDescription.lowercased()
        if lowercased.hasPrefix("resets ") || lowercased.hasPrefix("reset ") {
            return resetDescription
        }
        if Self.looksLikeDuration(resetDescription) {
            return "Resets in \(resetDescription)"
        }
        return "Resets \(resetDescription)"
    }

    static func resetMetricText(resetsAt: Date?, resetDescription: String?, from reference: Date) -> String? {
        guard let text = self.resetText(
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            from: reference)
        else {
            return nil
        }

        for prefix in ["Resets in ", "Resets ", "Reset "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func looksLikeDuration(_ value: String) -> Bool {
        let compact = value
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard compact.contains(where: \.isNumber),
              compact.contains(where: { $0 == "m" || $0 == "h" || $0 == "d" || $0 == "w" })
        else {
            return false
        }
        return compact.allSatisfy { character in
            character.isNumber || character == "." || character == "m" || character == "h" ||
                character == "d" || character == "w"
        }
    }
}
