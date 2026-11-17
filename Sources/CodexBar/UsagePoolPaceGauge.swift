import CodexBarCore
import SwiftUI

/// A diverging pace bar. The centre tick is on pace (using the week evenly), the green band is
/// the 10 point on-pace tolerance, and each marker is how far a provider's actual usage sits from it.
struct UsagePoolPaceGauge: View {
    struct Marker: Identifiable {
        var id: String { self.provider.rawValue }
        let provider: UsageProvider
        let delta: Double
    }

    struct Row: Identifiable {
        var id: String { self.provider.rawValue }
        let provider: UsageProvider
        let text: String
        let state: UsagePoolViewModel.PaceState
    }

    struct Login: Identifiable {
        let id: String
        let name: String
        let points: Int
        let estimated: Bool
    }

    let title: String
    let status: String
    let state: UsagePoolViewModel.PaceState
    var showsHeader = true
    var markers: [Marker] = []
    var rows: [Row] = []
    var detail: String?
    var logins: [Login] = []

    private static let markerSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: Self.symbol(self.state)).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Self.color(self.state)).accessibilityHidden(true)
                    Text(self.status).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(self.state == .unavailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.color(self.state)))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            self.track.frame(height: Self.markerSize + 2)
            HStack {
                Text("Slow")
                Spacer()
                Text("On pace")
                Spacer()
                Text("Fast")
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            if !self.rows.isEmpty {
                HStack(spacing: 14) {
                    ForEach(self.rows) { row in
                        HStack(spacing: 5) {
                            Circle().fill(UsageMenuCardView.Model.progressColor(for: row.provider))
                                .frame(width: 7, height: 7)
                            Text(row.provider == .claude ? "Claude" : "Codex").foregroundStyle(.primary)
                            Text(row.text).foregroundStyle(row.state == .unavailable
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.color(row.state)))
                        }
                        .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !self.logins.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                    ForEach(self.logins) { login in
                        HStack(spacing: 4) {
                            Text(login.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(Self.signed(login.points))
                                .foregroundStyle(Self.color(Self.state(Double(login.points) / 100)))
                                .fontWeight(.medium)
                            if login.estimated {
                                Text("est.").foregroundStyle(.tertiary)
                            }
                        }
                        .font(.subheadline)
                    }
                }
                if self.logins.contains(where: \.estimated) {
                    Text("est. uses the last reading")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.title)
        .accessibilityValue(([self.status] + self.rows.map {
            "\($0.provider == .claude ? "Claude" : "Codex") \($0.text)"
        } + [self.detail].compactMap { $0 }.filter { !$0.isEmpty } + self.logins.map {
            "\($0.name) \(Self.signed($0.points))\($0.estimated ? ", estimated" : "")"
        }).joined(separator: ", "))
    }

    private var track: some View {
        GeometryReader { proxy in
            let inset = Self.markerSize / 2
            let usable = max(1, proxy.size.width - 2 * inset)
            let x = { (delta: Double) in inset + usable * UsagePoolViewModel.paceGaugeFraction(delta) }
            let mid = x(0)
            let centreY = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.09))
                    .frame(width: proxy.size.width, height: 8)
                    .position(x: proxy.size.width / 2, y: centreY)
                // The 10 percent tolerance either side of expected usage.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.green.opacity(self.state == .unavailable ? 0.10 : 0.30))
                    .frame(width: x(0.10) - x(-0.10), height: 8)
                    .position(x: mid, y: centreY)
                if self.state != .unavailable {
                    ForEach(self.markers) { marker in
                        let end = x(marker.delta)
                        Capsule()
                            .fill(Self.color(Self.state(marker.delta)).gradient)
                            .frame(width: max(0, abs(end - mid)), height: 8)
                            .position(x: (end + mid) / 2, y: centreY)
                    }
                }
                Capsule().fill(Color.primary.opacity(0.6))
                    .frame(width: 2, height: 18)
                    .position(x: mid, y: centreY)
                if self.state != .unavailable {
                    let positions = Self.separated(self.markers.map { marker -> CGFloat in x(marker.delta) }, gap: Self.markerSize + 2,
                                                   lower: inset, upper: proxy.size.width - inset)
                    ForEach(Array(self.markers.enumerated()), id: \.element.id) { index, marker in
                        self.marker(marker.provider)
                            .position(x: positions[index], y: centreY)
                    }
                }
            }
        }
    }

    private func marker(_ provider: UsageProvider) -> some View {
        ZStack {
            Circle().fill(UsageMenuCardView.Model.progressColor(for: provider))
            if let image = ProviderBrandIcon.image(for: provider) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 11, height: 11).foregroundStyle(.white)
            }
        }
        .frame(width: Self.markerSize, height: Self.markerSize)
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    /// Nudges two markers apart when they would overlap, keeping their order and staying in bounds.
    /// Equal positions keep the given order (Claude before Codex).
    static func separated(_ positions: [CGFloat], gap: CGFloat, lower: CGFloat, upper: CGFloat) -> [CGFloat] {
        guard positions.count == 2, abs(positions[0] - positions[1]) < gap, upper - lower >= gap else { return positions }
        let firstIsLeft = positions[0] <= positions[1]
        let mid = min(max((positions[0] + positions[1]) / 2, lower + gap / 2), upper - gap / 2)
        let left = mid - gap / 2, right = mid + gap / 2
        return firstIsLeft ? [left, right] : [right, left]
    }

    nonisolated static func signed(_ points: Int) -> String {
        points > 0 ? "+\(points)" : points < 0 ? "\u{2212}\(-points)" : "0"
    }

    static func state(_ delta: Double) -> UsagePoolViewModel.PaceState {
        abs(delta) <= 0.10 + 0.000000001 ? .onPace : delta > 0 ? .ahead : .behind
    }

    static func color(_ state: UsagePoolViewModel.PaceState) -> Color {
        switch state {
        case .onPace: .green
        case .ahead: .orange
        case .behind: .blue
        case .mixed: .red
        case .unavailable: .secondary
        }
    }

    static func symbol(_ state: UsagePoolViewModel.PaceState) -> String {
        switch state {
        case .onPace: "checkmark.circle.fill"
        case .ahead: "arrow.up.right.circle.fill"
        case .behind: "arrow.down.right.circle.fill"
        case .mixed: "exclamationmark.triangle.fill"
        case .unavailable: "clock"
        }
    }
}
