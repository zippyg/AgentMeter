import AppKit
import Charts
import CodexBarCore
import SwiftUI

struct UsagePoolPopoverView: View {
    @Bindable var state: UsagePoolPresentation
    /// The tallest the panel may grow: the room between the menu bar and the Dock, capped at 680pt.
    /// Shorter tabs size to their content; taller ones scroll inside this height.
    var maxHeight: CGFloat = 680
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    var privacyChanged: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    // Hierarchical styles keep text vibrant on the glass surface and follow Increase Contrast.
    private var secondaryText: HierarchicalShapeStyle { .secondary }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0

    private var model: UsagePoolViewModel { self.state.model }
    private var claudeColor: Color { UsageMenuCardView.Model.progressColor(for: .claude) }
    private var codexColor: Color { UsageMenuCardView.Model.progressColor(for: .codex) }

    /// Header height plus a few points: a y inside the tab strip but above every tab glyph.
    static let tabStripProbeY: CGFloat = 41

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AgentMeter").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: self.refresh) {
                    if self.state.refreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).disabled(self.state.refreshing).accessibilityLabel("Refresh usage")
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            self.tabs
            Divider().padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch self.state.tab {
                    case .overview: self.overview
                    case .claude: self.claude
                    case .codex: self.codex
                    case .spend: self.spend
                    }
                    ForEach(self.state.errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(self.secondaryText)
                    }
                }
                // Pinned, not proposed: a relayout after an in-place tab switch lays the scroll content
                // out at its ideal width, and the segmented period picker's ideal is 368pt, which
                // widened Analytics to 424pt and shifted it left. A fixed width makes every open identical.
                .frame(width: Self.panelWidth - 2 * Self.panelMargin, alignment: .leading)
                .padding(.horizontal, Self.panelMargin).padding(.vertical, 12)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PoolContentHeightKey.self, value: proxy.size.height)
                })
            }
            .scrollIndicators(.hidden)
            // Ideal height is the content; when space runs short the scroll view gives way first.
            .frame(minHeight: 0, idealHeight: self.contentHeight,
                   maxHeight: self.contentHeight > 0 ? self.contentHeight : .infinity)
            .onPreferenceChange(PoolContentHeightKey.self) { self.contentHeight = $0 }
            Divider()
            HStack {
                Button("Settings…", action: self.settings)
                    .help("Settings, Command comma")
                Spacer()
                Text("Updated \(self.time(self.model.now))").font(.subheadline).foregroundStyle(self.secondaryText)
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: self.maxHeight)
        .font(.system(size: 14)).monospacedDigit()
        .foregroundStyle(.primary)
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.16), value: self.state.tab)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(UsagePoolViewModel.Tab.allCases) { tab in
                let provider: UsageProvider? = tab == .claude ? .claude : tab == .codex ? .codex : nil
                let color = provider.map { UsageMenuCardView.Model.progressColor(for: $0) } ?? .primary
                let labelColor = provider.map { provider in
                    let base = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
                    let shade = self.colorScheme == .dark ? 0.8 : 0.45
                    let lift = self.colorScheme == .dark ? 0.2 : 0.0
                    return Color(red: base.red * shade + lift, green: base.green * shade + lift, blue: base.blue * shade + lift)
                } ?? Color.primary
                Button { self.state.tab = tab } label: {
                    VStack(spacing: 4) {
                        if let provider, let image = ProviderBrandIcon.image(for: provider) {
                            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: tab == .overview ? "square.grid.2x2" : "chart.bar.xaxis")
                                .frame(height: 16)
                        }
                        Text(tab.rawValue).font(.system(size: 12, weight: self.state.tab == tab ? .semibold : .regular))
                            .foregroundStyle(self.state.tab == tab ? AnyShapeStyle(labelColor) : AnyShapeStyle(self.secondaryText))
                    }
                    .foregroundStyle(self.state.tab == tab ? AnyShapeStyle(color) : AnyShapeStyle(self.secondaryText))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(self.state.tab == tab ? color.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    // A plain button only hit-tests drawn pixels; without this, clicks between
                    // the icon and the label of an unselected tab fell through.
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityAddTraits(self.state.tab == tab ? .isSelected : [])
                .help("\(tab.rawValue), Command \(UsagePoolViewModel.Tab.allCases.firstIndex(of: tab)! + 1)")
            }
        }.padding(.horizontal, 10).padding(.bottom, 8)
    }

    @ViewBuilder private var overview: some View {
        self.overallPaceGauge.poolCard()
        if let account = self.state.activeClaudeAccount {
            self.overviewCard(account, provider: .claude)
        } else if !self.state.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                self.brand(.claude, showsPlan: false)
                Label("No active login", systemImage: "person.crop.circle.badge.questionmark")
                    .fontWeight(.medium)
            }.poolCard()
        } else { self.empty("Claude").poolCard() }
        if self.state.codexAccounts.isEmpty { self.empty("Codex").poolCard() }
        if let account = self.state.codexAccount, UsagePoolViewModel.isInUse(account) {
            self.overviewCard(account, provider: .codex)
        } else if !self.state.codexAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                self.brand(.codex, showsPlan: false)
                Label("No active login", systemImage: "person.crop.circle.badge.questionmark")
                    .fontWeight(.medium)
            }.poolCard()
        }
    }

    @ViewBuilder private var claude: some View {
        if !self.state.accounts.isEmpty {
            let fleet = self.state.claudeFleet
            self.fleetHeader(.claude)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(fleet.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    UsagePoolAccountRowView(row: row, tint: self.claudeColor, now: self.model.now)
                }
            }.poolCard()
            VStack(alignment: .leading, spacing: 10) {
                self.bankedResetsTitle(self.model.claudeBankedResetTotal,
                                       help: "Read-only grants; refill scope varies by reset kind.")
                ForEach(Array(self.state.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider() }
                    let rows = self.model.claudeBankedResets(account)
                    self.bankedResetLogin(name: self.state.name(account, index: index),
                                          count: self.model.claudeResetCount(account), rows: rows ?? [], advice: nil,
                                          detail: self.model.claudeResetDetail(account))
                }
            }.poolCard()
            VStack(alignment: .leading, spacing: 8) {
                self.costLine(.claude)
                if let result = self.model.claude { self.runwayLine(result) }
            }.poolCard()
            self.comingUp.poolCard()
        } else { self.empty("Claude").poolCard() }
    }

    private func overviewCard(_ account: UsagePoolForecast.Account, provider: UsageProvider) -> some View {
        let accounts = provider == .claude ? self.state.accounts : self.state.codexAccounts
        let index = accounts.firstIndex { $0.id == account.id } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            self.brand(provider, showsPlan: false)
            self.loginHeader(account, index: index)
            self.accountUsage(account, provider: provider == .claude ? .claude : .codex,
                              result: nil, includesScoped: false)
        }.poolCard()
    }

    private func loginHeader(_ account: UsagePoolForecast.Account, index: Int) -> some View {
        let row = UsagePoolFleet.row(account, name: self.state.name(account, index: index), now: self.model.now)
        return HStack {
            UsagePoolAccountDot(status: UsagePoolViewModel.isInUse(account) ? row.status : .idle, hasReading: row.hasReading)
            Text(row.name).font(.system(size: 14, weight: .medium))
            Spacer()
            if UsagePoolViewModel.isInUse(account) {
                Text("Active").font(.subheadline).foregroundStyle(self.secondaryText)
            }
        }
    }

    private var overallPaceGauge: some View {
        let rows = [UsageProvider.claude, .codex].compactMap { provider -> UsagePoolPaceGauge.Row? in
            let available = provider == .claude ? !self.state.accounts.isEmpty : self.state.codexAccount != nil
            guard available else { return nil }
            let position = self.providerPosition(provider)
            let state = position.map(UsagePoolViewModel.paceState) ?? .unavailable
            let text = state == .unavailable
                ? UsagePoolViewModel.paceUnavailableTitle(self.paceAccount(provider), now: self.model.now)
                : UsagePoolViewModel.paceShort(position!)
            return .init(provider: provider, text: text, state: state)
        }
        let markers = [UsageProvider.claude, .codex].compactMap { provider in
            self.providerPosition(provider)?.delta.map { UsagePoolPaceGauge.Marker(provider: provider, delta: $0) }
        }
        return UsagePoolPaceGauge(
            title: "Overall pace", status: self.model.overallPaceTitle, state: self.model.overallPaceState,
            markers: markers, rows: rows,
            detail: self.model.overallPaceDetail)
    }

    private func providerPosition(_ provider: UsageProvider) -> UsagePoolForecast.PacePosition? {
        provider == .claude ? self.model.claudePosition : self.model.codexPosition
    }

    private func paceAccount(_ provider: UsageProvider) -> UsagePoolForecast.Account? {
        provider == .claude ? self.state.activeClaudeAccount : self.state.codexAccount
    }

    private func providerPaceGauge(_ provider: UsageProvider, showsLogins: Bool = true) -> some View {
        let position = self.providerPosition(provider)
        let state = position.map(UsagePoolViewModel.paceState) ?? .unavailable
        return UsagePoolPaceGauge(
            title: "", status: "", state: state, showsHeader: showsLogins,
            markers: position?.delta.map { [.init(provider: provider, delta: $0)] } ?? [],
            detail: state == .unavailable
                ? UsagePoolViewModel.paceUnavailableDetail(self.paceAccount(provider), now: self.model.now) : nil)
    }

    private func fleetHeader(_ provider: UsageProvider) -> some View {
        let fleet = provider == .claude ? self.state.claudeFleet : self.state.codexFleet
        let total = provider == .claude ? self.state.accounts.count : self.state.codexAccounts.count
        return VStack(alignment: .leading, spacing: 8) {
            self.brand(provider, showsPlan: false, showsPace: true)
            UsagePoolFleetStrip(fleet: fleet, total: total, now: self.model.now) {
                self.providerPaceGauge(provider, showsLogins: false)
            }
        }.poolCard()
    }

    @ViewBuilder private var codex: some View {
        if !self.state.codexAccounts.isEmpty {
            self.fleetHeader(.codex)
        } else { self.empty("Codex").poolCard() }
        ForEach(self.model.codexSections) { section in
            VStack(alignment: .leading, spacing: 10) {
                switch section {
                case .status:
                    self.codexStatus
                case .bankedResets:
                    self.bankedResetsTitle(
                        "\(self.state.codexModels.values.reduce(0) { $0 + $1.bankedResetCount })",
                        help: "Resets are read-only; pace assumes a full weekly allowance.")
                    ForEach(Array(self.model.orderedCodexAccounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        if let model = self.state.codexModels[account.id] {
                            self.bankedResets(model, name: self.state.name(account, index: index))
                        }
                    }
                case .accountDetails:
                    Text(section.rawValue).fontWeight(.semibold)
                    ForEach(Array(self.model.orderedCodexAccounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        Text(self.state.name(account, index: index)).fontWeight(.medium)
                        if self.state.codexAccountCredits[account.id] == nil {
                            Text("No credits reported.").font(.subheadline).foregroundStyle(self.secondaryText)
                        }
                        self.creditsRow(self.state.codexAccountCredits[account.id], canPurchase: account.isActive,
                                        cap: self.state.creditCapForAccount(account))
                    }
                    Divider()
                    Text("All Codex accounts on this Mac").fontWeight(.medium)
                    self.costLine(.codex)
                    Text("Local spend history is not split by account.")
                        .font(.subheadline).foregroundStyle(self.secondaryText)
                }
            }.poolCard()
        }
    }

    private var codexStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(self.model.orderedCodexAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider() }
                self.codexRow(account, index: index)
            }
        }
    }

    private func bankedResetsTitle(_ total: String, help: String) -> some View {
        HStack {
            Text("Banked resets").font(.system(size: 14, weight: .semibold)).help(help)
            Spacer()
            Text(total).foregroundStyle(self.secondaryText)
        }
    }

    @ViewBuilder private func bankedResets(_ model: UsagePoolViewModel, name: String) -> some View {
        self.bankedResetLogin(name: name, count: model.bankedResetCount,
                              rows: model.bankedResets, advice: model.codexResetAdvice)
        if let result = model.codex, result.unplannedCreditCount > 0 {
            Text("\(result.unplannedCreditCount) more, no details")
                .font(.system(size: 12)).foregroundStyle(self.secondaryText)
        }
    }

    @ViewBuilder private func bankedResetLogin(
        name: String, count: Int?, rows: [UsagePoolViewModel.BankedReset], advice: String?,
        detail: String? = nil) -> some View
    {
        HStack {
            Text(name).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(count.map { $0 == 0 ? "None" : "\($0)" } ?? "Unknown")
                .foregroundStyle(self.secondaryText)
        }
        if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(self.secondaryText) }
        ForEach(rows, id: \.number) { reset in
            HStack(spacing: 6) {
                Text(reset.title).foregroundStyle(self.secondaryText)
                if let redemption = reset.redemption {
                    Text("\(Int(redemption.valuePercent.rounded()))%").foregroundStyle(self.secondaryText)
                }
                let kind = reset.availability.map { "\(reset.kind ?? "Reset") · \($0)" } ?? reset.kind
                Text(kind ?? advice ?? reset.redemption.map { UsagePoolViewModel.resetUseText($0.at, now: self.model.now) } ?? "No redeem time")
                Spacer(minLength: 0)
                Text(reset.expiresAt.map { "Expires \(self.time($0))" } ?? "No expiry")
                    .foregroundStyle(self.secondaryText)
            }
            .font(.system(size: 12)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            .help(reset.redemption?.paceToUseBeforeExpiry.map {
                String(format: "Use %.1f%% per hour before expiry", $0)
            } ?? "")
        }
    }

    @ViewBuilder var creditsRow: some View {
        self.creditsRow(self.state.codexCredits, canPurchase: true, cap: nil)
    }

    @ViewBuilder private func creditsRow(_ snapshot: CreditsSnapshot?, canPurchase: Bool,
                                         cap: UsagePoolCreditCap?) -> some View {
        if let credits = snapshot {
            VStack(alignment: .leading, spacing: 5) {
                Text("Credits").font(.system(size: 14)).fontWeight(.medium).foregroundStyle(Color.primary)
                Text(credits.remaining.formatted(.number.precision(.fractionLength(0...2))) + " credits left")
                    .monospacedDigit()
                if cap != nil, let accountCap = UsagePoolCredits(balance: credits.remaining, cap: cap) {
                    UsagePoolCreditsView(credits: accountCap, tint: self.codexColor, showsBalance: false)
                }
                if !credits.events.isEmpty {
                    let used = credits.events.reduce(0) { $0 + $1.creditsUsed }
                    Text("Used so far: \(used.formatted()) credits")
                }
                if canPurchase, let url = self.state.creditsPurchaseURL {
                    Link("Buy credits…", destination: url).foregroundStyle(.link)
                }
            }.font(.subheadline).foregroundStyle(self.secondaryText)
        }
    }

    /// Same insets as every other tab: each block sits in a card, 12pt inside the 16pt panel margin.
    @ViewBuilder private var spend: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Usage & spend").fontWeight(.semibold)
                Spacer()
                Toggle("Hide names", isOn: self.$state.hideNames).toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: self.state.hideNames) { _, value in self.privacyChanged(value) }
            }
            Picker("Period", selection: self.$state.analyticsWindow) {
                ForEach(AllAccountsDashboardModel.Window.allCases) { window in Text(window.rawValue).tag(window) }
            }.pickerStyle(.segmented).labelsHidden()
            // At regular size the control's ideal width is 368pt, wider than the 324pt card, and a
            // relayout let it draw at that width. At small size its ideal is 316pt, so it always fits.
            .controlSize(.small)
            .frame(width: Self.analyticsCardWidth)
        }.poolCard()
        VStack(alignment: .leading, spacing: 10) {
            if let analytics = self.state.analytics {
                AllAccountsUsageCard(
                    model: analytics, width: Self.analyticsCardWidth, showsDetails: true, hideNames: self.state.hideNames)
            } else {
                Text("No local usage history yet.").foregroundStyle(self.secondaryText)
            }
        }.poolCard()
        if !self.state.scanStatus.isEmpty {
            // Skipped or unreadable logs are reported as counts, never as missing tokens.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(self.state.scanStatus, id: \.provider) { status in
                    Label(UsagePoolPresentation.scanStatusText(status),
                          systemImage: status.unread + status.skipped > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(self.secondaryText)
                }
            }.poolCard()
        }
    }

    static let panelWidth: CGFloat = 380
    static let panelMargin: CGFloat = 16
    /// The panel, less its margins and a card's 12pt insets on each side.
    static let analyticsCardWidth: CGFloat = panelWidth - 2 * panelMargin - 2 * 12

    @ViewBuilder private func codexRow(_ account: UsagePoolForecast.Account, index: Int) -> some View {
        UsagePoolAccountRowView(
            row: self.model.codexRow(account, name: self.state.name(account, index: index)),
            tint: self.codexColor, now: self.model.now)
    }

    static func codexRowName(plan: String?) -> String {
        plan.flatMap { $0.isEmpty ? nil : $0 } ?? "Login"
    }

    private func brand(
        _ provider: UsageProvider, showsPlan: Bool = false, showsPace: Bool = false) -> some View
    {
        HStack(spacing: 7) {
            if let image = ProviderBrandIcon.image(for: provider) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(UsageMenuCardView.Model.progressColor(for: provider)).accessibilityHidden(true)
            }
            Text(provider == .claude ? "Claude" : "Codex").font(.system(size: 16, weight: .semibold))
            Spacer()
            if showsPace {
                let position = self.providerPosition(provider)
                let state = position.map(UsagePoolViewModel.paceState) ?? .unavailable
                Image(systemName: UsagePoolPaceGauge.symbol(state)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UsagePoolPaceGauge.color(state))
                Text(position.map(UsagePoolViewModel.paceTitle)
                    ?? UsagePoolViewModel.paceUnavailableTitle(self.paceAccount(provider), now: self.model.now))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UsagePoolPaceGauge.color(state))
            }
        }
    }

    @ViewBuilder private func accountUsage(
        _ account: UsagePoolForecast.Account, provider: UsagePoolForecast.Provider,
        result: UsagePoolForecast.Result?, includesScoped: Bool = true) -> some View
    {
        let tint = provider == .claude ? self.claudeColor : self.codexColor
        let creditsRemaining = provider == .codex ? self.state.codexAccountCredits[account.id]?.remaining : nil
        let unreadable = account.refusedSince != nil
        let estimated = unreadable || account.measuredAt.map { self.model.now.timeIntervalSince($0) > 900 } == true
        if includesScoped && unreadable {
            Text(UsagePoolViewModel.lastReadText(account, now: self.model.now))
                .font(.subheadline).foregroundStyle(self.secondaryText)
        }
        if let session = account.session, session.windowMinutes == 300,
           session.resetsAt.map({ $0 > self.model.now }) == true {
            self.usageBar(title: "Session", window: session, tint: tint, estimated: estimated, unreadable: unreadable,
                          creditsRemaining: creditsRemaining)
        }
        if let weekly = account.weekly {
            self.usageBar(title: "Weekly", window: weekly, tint: tint, estimated: estimated, unreadable: unreadable,
                          creditsRemaining: creditsRemaining)
        }
        ForEach(includesScoped ? account.scoped : [], id: \.id) { scoped in
            if scoped.usageKnown {
                self.usageBar(title: scoped.title, window: scoped.window, tint: tint, estimated: estimated, unreadable: unreadable,
                              creditsRemaining: creditsRemaining)
            } else {
                Text("\(scoped.title): usage unavailable").font(.subheadline).foregroundStyle(self.secondaryText)
            }
        }
        if account.weekly == nil && account.session == nil {
            Text("No last reading available").font(.subheadline).foregroundStyle(self.secondaryText)
        }
    }

    private func usageBar(title: String, window: RateWindow, tint: Color, estimated: Bool, unreadable: Bool = false,
                          creditsRemaining: Double? = nil) -> some View {
        let value = window.usedPercent
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14, weight: .medium))
            // The green line is where usage would sit at an even pace through this window.
            UsageProgressBar(percent: value, tint: estimated ? tint.opacity(0.55) : tint, accessibilityLabel: title,
                             pacePercent: UsagePoolViewModel.steadyPercent(window, now: self.model.now))
            HStack {
                Text(UsagePoolViewModel.usageText(window, unreadable: unreadable, estimated: estimated, now: self.model.now,
                                                  creditsRemaining: creditsRemaining))
                Spacer(minLength: 4)
                if let text = UsagePoolViewModel.topUpText(window, unreadable: unreadable, now: self.model.now) {
                    Text(text)
                        .foregroundStyle(self.secondaryText)
                }
            }.font(.subheadline).lineLimit(1).minimumScaleFactor(0.85)
            if UsagePoolViewModel.isAwaitingTopUpRead(window, unreadable: unreadable, now: self.model.now) {
                Text("Awaiting read")
                    .font(.subheadline).foregroundStyle(self.secondaryText)
            }
        }.accessibilityElement(children: .combine)
    }

    /// Thirty days of API-equivalent cost as a small daily bar chart, today highlighted.
    private func costLine(_ provider: UsageProvider) -> some View {
        let tint = UsageMenuCardView.Model.progressColor(for: provider)
        let cost = self.state.providerCosts[provider]
        let daily = cost?.days.map { (id: $0.id, cost: $0.costs.reduce(0, +)) } ?? []
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("API-equivalent").font(.subheadline).fontWeight(.medium)
                Spacer()
                if let cost {
                    Text("30 days: \(UsageFormatter.tokenCountString(cost.tokens)) tokens · \(UsageFormatter.usdString(cost.cost))")
                        .font(.subheadline).foregroundStyle(self.secondaryText)
                } else { Text("No local history").font(.subheadline).foregroundStyle(self.secondaryText) }
            }
            if let cost, cost.cost > 0 {
                Chart(daily, id: \.id) { day in
                    BarMark(x: .value("Day", day.id), y: .value("Cost", day.cost), width: .ratio(0.7))
                        .foregroundStyle(tint.opacity(day.id == daily.last?.id ? 1 : 0.55))
                        .cornerRadius(1.5)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartXScale(domain: cost.chartDomain)
                .frame(height: 34)
                .accessibilityLabel("Daily API-equivalent cost, last 30 days")
                HStack {
                    Text(cost.days.first.map { UsagePoolViewModel.axisDateText($0.id) } ?? "")
                    Spacer()
                    Text("Today \(UsageFormatter.usdString(daily.last?.cost ?? 0))")
                }
                .font(.system(size: 11)).foregroundStyle(self.secondaryText)
            }
        }
    }

    @ViewBuilder private func runwayLine(_ result: UsagePoolForecast.Result) -> some View {
        if result.assumptions.pace != nil {
            Text("On its own: \(UsagePoolViewModel.runway(result.ownRunwayUntil, result: result, now: self.model.now)) · If you act: \(UsagePoolViewModel.runway(result.actingRunwayUntil, result: result, now: self.model.now))")
            .font(.subheadline).foregroundStyle(self.secondaryText)
        }
    }

    @ViewBuilder private func expiryNotice(_ model: UsagePoolViewModel) -> some View {
        if let reset = model.expiringReset {
            Label("Codex reset expires \(self.time(reset.expiresAt ?? reset.at))",
                  systemImage: "clock.badge.exclamationmark")
                .font(.subheadline).foregroundStyle(self.secondaryText)
        } else if let credit = model.expiringCredit, let expiry = credit.expiresAt {
            Label("Codex reset expires \(self.time(expiry)). No redeem time.", systemImage: "clock.badge.exclamationmark")
                .font(.subheadline).foregroundStyle(self.secondaryText)
        }
    }

    private var comingUp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coming up").fontWeight(.medium)
            ForEach(Array((self.model.claude?.comingUp ?? []).enumerated()), id: \.offset) { _, event in
                HStack(alignment: .firstTextBaseline) {
                    Text(self.state.eventWording(event))
                    Spacer()
                    Text(self.time(event.at)).foregroundStyle(self.secondaryText)
                }.font(.subheadline).accessibilityElement(children: .combine)
            }
            if self.model.claude?.comingUp.isEmpty != false { Text("No scheduled actions yet.").font(.subheadline).foregroundStyle(self.secondaryText) }
        }
    }

    private func time(_ date: Date) -> String { UsagePoolViewModel.dateText(date, now: self.model.now) }
    private func countdown(to date: Date) -> String {
        UsagePoolViewModel.countdown(to: date, now: self.model.now)
    }
    private func empty(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(provider) unavailable").fontWeight(.medium)
            Text("Check Settings").font(.subheadline).foregroundStyle(self.secondaryText)
        }
    }
}

private struct PoolContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// A quiet grouped platter on the single panel glass; a fill, never a second glass layer.
    func poolCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct UsagePoolAccountDot: View {
    let status: UsagePoolAccountRow.Status
    var hasReading = false

    var color: Color {
        switch self.status {
        case .active: .green
        case .idle: .secondary
        case .stale: self.hasReading ? .secondary : .red.opacity(0.75)
        }
    }
    var label: String {
        switch self.status {
        case .active: "Active account"
        case .idle: "Not active"
        case .stale: self.hasReading ? "Not read" : "Never read"
        }
    }

    var body: some View {
        Circle().fill(self.color).frame(width: 7, height: 7)
            .accessibilityLabel(self.label)
    }
}
