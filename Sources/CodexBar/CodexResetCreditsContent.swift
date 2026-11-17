import CodexBarCore
import SwiftUI

struct CodexResetCreditsContent: View {
    struct Presentation {
        let count: Int
        let expiryLines: [String]
        let warning: String?

        static func make(
            credits: CodexResetCredits,
            weeklyUsedPercent: Double?,
            now: Date,
            calendar: Calendar = .current) -> Self
        {
            let available = (credits.credits ?? []).filter {
                $0.status?.lowercased() == "available" && ($0.expiresAt == nil || $0.expiresAt! > now)
            }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            let lines = available.enumerated().map { index, credit in
                let expiry = credit.expiresAt.map { UsageFormatter.resetCountdownDescription(from: $0, now: now) }
                    ?? "Does not expire"
                return "Full reset \(index + 1): \(expiry)"
            }
            var warning: String?
            if let expiry = available.first?.expiresAt,
               expiry.timeIntervalSince(now) <= 24 * 3600,
               let used = weeklyUsedPercent, used.isFinite, used >= 0, used < 95
            {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_GB")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "HH:mm"
                let sameDayLabel = calendar.component(.hour, from: expiry) < 18 ? "today" : "tonight"
                let day = calendar.isDate(expiry, inSameDayAs: now) ? sameDayLabel : "tomorrow"
                let unused = 100 - used
                let pace = unused / (expiry.timeIntervalSince(now) / 3600)
                warning = String(
                    format: "Reset expires %@ %@. %.0f%% unused. Burn about %.1f%%/h, then redeem it yourself.",
                    formatter.string(from: expiry), day, unused, pace)
            }
            // Known spent or expired details still override a stale summary count.
            let hasUsableDetails = (credits.credits ?? []).contains {
                ["available", "redeeming", "redeemed", "expired"].contains($0.status?.lowercased() ?? "")
            }
            let count = hasUsableDetails ? available.count : max(0, credits.availableCount ?? 0)
            return Self(count: count, expiryLines: lines, warning: warning)
        }
    }

    let credits: CodexResetCredits
    let weeklyUsedPercent: Double?
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = Presentation.make(
                credits: self.credits,
                weeklyUsedPercent: self.weeklyUsedPercent,
                now: context.date)
            if presentation.count > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full reset credits: \(presentation.count) available").monospacedDigit()
                        .font(.body.weight(.medium))
                    ForEach(presentation.expiryLines, id: \.self) { line in
                        Text(line).monospacedDigit()
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    }
                    if presentation.expiryLines.isEmpty {
                        Text("Expiry details unavailable")
                            .font(.caption)
                    }
                    if let warning = presentation.warning {
                        Text(warning).monospacedDigit()
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(self.isHighlighted ? Color.white : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
