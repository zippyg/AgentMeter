import Foundation

extension UsagePoolForecast {
    public struct SoloStretch: Sendable {
        public let spend: Double
        public let usedPoints: Double
        public let includesTopUp: Bool
        public let isSolo: Bool
        public init(spend: Double, usedPoints: Double, includesTopUp: Bool = false, isSolo: Bool = true) {
            self.spend = spend
            self.usedPoints = usedPoints
            self.includesTopUp = includesTopUp
            self.isSolo = isSolo
        }
    }

    /// Spend must share the units of demand. Mixed/default point sizes must not be mixed with dollar sizes.
    public static func calibratedCapacity(stretches: [SoloStretch]) -> Double? {
        let ratios = stretches.filter {
            $0.isSolo && !$0.includesTopUp && $0.usedPoints.isFinite && (10...100).contains($0.usedPoints)
                && $0.spend.isFinite && $0.spend > 0
        }.map { $0.spend / $0.usedPoints }.sorted()
        guard ratios.count >= 3 else { return nil }
        let mid = ratios.count / 2
        return 100 * (ratios.count.isMultiple(of: 2) ? (ratios[mid - 1] + ratios[mid]) / 2 : ratios[mid])
    }

    public struct Pace: Sendable {
        /// Capacity units/hour, Sunday first. Local day aggregates cannot establish an hourly shape.
        public let weekdayRates: [Double]
        public let assumption: String
        public var meanPerHour: Double { self.weekdayRates.reduce(0, +) / 7 }

        public init(unitsPerDay: Double, assumption: String) throws {
            try self.init(weekdayRates: Array(repeating: unitsPerDay / 24, count: 7), assumption: assumption)
        }

        public init(weekdayRates: [Double], assumption: String) throws {
            guard weekdayRates.count == 7, weekdayRates.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  weekdayRates.reduce(0, +).isFinite else {
                throw ForecastError.invalidInput
            }
            self.weekdayRates = weekdayRates
            self.assumption = assumption
        }

        /// Claude costNanos are already converted to costUSD by CostUsageDailyReport.
        /// Supply 1 for dollar-calibrated Claude tanks, or 100/tokensPerTank for Codex.
        /// Without a measured conversion, raw dollars/tokens cannot be used as quota points.
        public static func localHistory(
            _ entries: [CostUsageDailyReport.Entry], provider: Provider, now: Date,
            capacityUnitsPerRawUnit: Double) throws -> Pace?
        {
            guard capacityUnitsPerRawUnit.isFinite, capacityUnitsPerRawUnit > 0 else {
                throw ForecastError.invalidInput
            }
            let calendar = Self.calendar
            let today = calendar.startOfDay(for: now)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            var values: [Date: Double] = [:]
            for entry in entries {
                guard let date = formatter.date(from: entry.date), date < today,
                      date >= today.addingTimeInterval(-28 * day) else { continue }
                let raw = provider == .claude ? entry.costUSD : entry.totalTokens.map(Double.init)
                guard let raw, raw.isFinite, raw >= 0 else { continue }
                values[date, default: 0] += raw * capacityUnitsPerRawUnit
            }
            // Missing days are unknown, not zero demand. Explicit zero entries are accepted.
            guard values.count == 28 else { return nil }
            var rates = Array(repeating: 0.0, count: 7)
            for (date, units) in values { rates[calendar.component(.weekday, from: date) - 1] += units / (4 * 24) }
            return try Pace(
                weekdayRates: rates,
                assumption: "28 complete UTC days of local \(provider == .claude ? "cost" : "token") aggregates; flat within each day")
        }

        public static func windowAverage(accounts: [Account], now: Date) throws -> Pace {
            let readable = accounts.filter {
                guard $0.refusedSince == nil, let window = $0.weekly, let reset = window.resetsAt else { return false }
                let duration = Double(window.windowMinutes ?? 10080) * 60
                let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-duration))
                return reset > now && elapsed >= 0 && elapsed < duration
            }
            let mature = readable.filter { account in
                let window = account.weekly!
                let duration = Double(window.windowMinutes ?? 10080) * 60
                return now.timeIntervalSince(window.resetsAt!.addingTimeInterval(-duration)) >= 6 * 3600
            }
            guard let account = mature.first(where: { $0.isActive }) ?? mature.first else {
                throw readable.isEmpty ? ForecastError.invalidInput : ForecastError.insufficientHistory
            }
            let window = account.weekly!
            let duration = Double(window.windowMinutes ?? 10080) * 60
            let elapsed = now.timeIntervalSince(window.resetsAt!.addingTimeInterval(-duration)) / 3600
            return try Pace(
                unitsPerDay: window.usedPercent / 100 * account.capacity / elapsed * 24,
                assumption: "Window average for \(account.displayName): used capacity / elapsed weekly hours")
        }

        static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }

        func rate(at date: Date) -> Double {
            if self.weekdayRates.allSatisfy({ $0 == self.weekdayRates[0] }) { return self.weekdayRates[0] }
            return self.weekdayRates[Self.calendar.component(.weekday, from: date) - 1]
        }

        func nextChange(after date: Date) -> Date {
            guard !self.weekdayRates.allSatisfy({ $0 == self.weekdayRates[0] }) else { return .distantFuture }
            return Self.calendar.startOfDay(for: date).addingTimeInterval(day)
        }

        /// Latest action deadline that can consume this tank before a known top-up.
        func latestStart(consuming units: Double, before end: Date, after start: Date) -> Date? {
            // Flat demand has an exact deadline without walking calendar days at every search node.
            if self.weekdayRates.allSatisfy({ $0 == self.weekdayRates[0] }) {
                let rate = self.weekdayRates[0]
                guard units > epsilon, rate > 0 else { return nil }
                let deadline = end.addingTimeInterval(-units / rate * 3600)
                return deadline >= start ? deadline : nil
            }
            var remaining = units
            var cursor = end
            while cursor > start, remaining > epsilon {
                let previousDay = Self.calendar.startOfDay(for: cursor.addingTimeInterval(-0.001))
                let lower = max(start, previousDay)
                let rate = self.rate(at: cursor.addingTimeInterval(-0.001))
                let available = rate * cursor.timeIntervalSince(lower) / 3600
                if rate > 0, remaining <= available {
                    return cursor.addingTimeInterval(-remaining / rate * 3600)
                }
                remaining -= available
                cursor = lower
            }
            return nil
        }
    }
}
