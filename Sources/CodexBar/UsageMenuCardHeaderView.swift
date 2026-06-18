import AppKit
import CodexBarCore
import SwiftUI

struct UsageMenuCardHeaderView: View {
    let model: UsageMenuCardView.Model
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerLineSpacing) {
            HStack(alignment: .center, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                HStack(alignment: .center, spacing: 6) {
                    if self.model.provider == .claude,
                       let mascot = AgentMeterMascotIcon.claudeCreature()
                    {
                        AgentMeterClaudeMascotView(image: mascot)
                    }
                    if let wordmark = ProviderBrandIcon.wordmark(
                        for: self.model.provider,
                        dark: self.colorScheme == .dark)
                    {
                        Image(nsImage: wordmark)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 15)
                            .accessibilityLabel(self.model.providerName)
                    } else {
                        if let brand = ProviderBrandIcon.image(for: self.model.provider) {
                            Image(nsImage: brand)
                                .renderingMode(ProviderBrandIcon
                                    .usesTemplateRendering(for: self.model.provider) ? .template : .original)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 14, height: 14)
                                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                                .accessibilityHidden(true)
                        }
                        Text(self.model.providerName).font(.headline)
                            .fontWeight(.semibold)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .layoutPriority(1)
                Spacer()
                Text(self.model.email).font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1).truncationMode(.middle)
            }
            let liveSubtitle = self.liveSubtitle
            // Keep the geometry AppKit measured for this hosted row. A new error stays one line
            // until the next rebuild; a recovered error keeps its reserved height until then.
            let usesErrorLayout = self.model.subtitleStyle == .error
            let subtitleAlignment: VerticalAlignment = usesErrorLayout ? .top : .firstTextBaseline
            HStack(alignment: subtitleAlignment, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                if usesErrorLayout {
                    Text(self.model.subtitleText)
                        .font(.footnote)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .hidden()
                        .overlay(alignment: .topLeading) {
                            Text(liveSubtitle.text)
                                .font(.footnote)
                                .foregroundStyle(self.subtitleColor(for: liveSubtitle.style))
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .clipped()
                        .layoutPriority(1)
                } else {
                    Text(liveSubtitle.text)
                        .font(.footnote)
                        .foregroundStyle(self.subtitleColor(for: liveSubtitle.style))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                Spacer()
                if usesErrorLayout {
                    let showsCopyButton = liveSubtitle.style == .error && !liveSubtitle.text.isEmpty
                    CopyIconButton(copyText: liveSubtitle.text, isHighlighted: self.isHighlighted)
                        .opacity(showsCopyButton ? 1 : 0)
                        .allowsHitTesting(showsCopyButton)
                        .accessibilityHidden(!showsCopyButton)
                }
                if let plan = self.model.planText {
                    Text(plan)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
    }

    private var liveSubtitle: MenuCardLiveSubtitle {
        let fallback = MenuCardLiveSubtitle(text: self.model.subtitleText, style: self.model.subtitleStyle)
        guard self.model.usesLiveSubtitle else { return fallback }
        return self.refreshMonitor?.subtitle(for: self.model.provider, fallback: fallback) ?? fallback
    }

    private func subtitleColor(for style: UsageMenuCardView.Model.SubtitleStyle) -> Color {
        switch style {
        case .info: MenuHighlightStyle.secondary(self.isHighlighted)
        case .loading: MenuHighlightStyle.secondary(self.isHighlighted)
        case .error: MenuHighlightStyle.error(self.isHighlighted)
        }
    }
}
