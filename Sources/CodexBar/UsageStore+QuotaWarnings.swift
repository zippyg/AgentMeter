import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func handleQuotaWarningTransitions(provider: UsageProvider, snapshot: UsageSnapshot) {
        guard self.settings.quotaWarningNotificationsEnabled else { return }

        let accountDisplayName = self.quotaWarningAccountDisplayName(provider: provider, snapshot: snapshot)
        let source: SessionQuotaWindowSource? = if provider == .antigravity {
            Self.hasAntigravityQuotaSummaryWindows(snapshot: snapshot)
                ? .antigravityQuotaSummary
                : .antigravityLegacy
        } else {
            nil
        }
        let primaryWindow: RateWindow?
        let secondaryWindow: RateWindow?
        if provider == .antigravity {
            primaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 5 * 60)
            secondaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 7 * 24 * 60)
        } else {
            primaryWindow = provider == .mimo ? nil : snapshot.primary
            secondaryWindow = provider == .mimo ? nil : snapshot.secondary
        }
        self.handleQuotaWarningTransition(
            provider: provider,
            window: .session,
            rateWindow: primaryWindow,
            source: source,
            accountDisplayName: accountDisplayName)
        self.handleQuotaWarningTransition(
            provider: provider,
            window: .weekly,
            rateWindow: secondaryWindow,
            source: source,
            accountDisplayName: accountDisplayName)
    }

    /// Plays the rate-limit alert sound once when a provider's highest tracked window crosses the
    /// rage threshold (>= 99% used). Independent of quota-warning notifications so it works on its
    /// own toggle; silent on the first snapshot per provider so launching while maxed out stays quiet.
    func handleRateLimitSound(provider: UsageProvider, snapshot: UsageSnapshot) {
        guard self.settings.rateLimitSoundEnabled else {
            self.rateLimitLastUsedPercent.removeValue(forKey: provider)
            return
        }
        guard let used = AgentMeterMascotMoodResolver.providerPressure(snapshot: snapshot) else {
            self.rateLimitLastUsedPercent.removeValue(forKey: provider)
            return
        }
        let decision = RateLimitSoundLogic.decision(
            previousUsed: self.rateLimitLastUsedPercent[provider],
            currentUsed: used)
        self.rateLimitLastUsedPercent[provider] = decision.remembered
        if decision.play {
            RateLimitSoundPlayer.shared.play(volume: self.settings.rateLimitSoundVolume)
        }
    }

    private func handleQuotaWarningTransition(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        rateWindow: RateWindow?,
        source: SessionQuotaWindowSource?,
        accountDisplayName: String?)
    {
        let key = QuotaWarningStateKey(provider: provider, window: window)
        guard self.settings.quotaWarningEnabled(provider: provider, window: window) else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }
        guard let rateWindow else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }

        let thresholds = self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
        let currentRemaining = rateWindow.remainingPercent
        let previousState = self.quotaWarningState[key]
        if let previousState, previousState.source != source {
            self.quotaWarningState[key] = QuotaWarningState(
                lastRemaining: currentRemaining,
                source: source)
            return
        }
        var state = previousState ?? QuotaWarningState(source: source)
        let cleared = QuotaWarningNotificationLogic.thresholdsToClear(
            currentRemaining: currentRemaining,
            alreadyFired: state.firedThresholds)
        state.firedThresholds.subtract(cleared)

        if let threshold = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: state.lastRemaining,
            currentRemaining: currentRemaining,
            thresholds: thresholds,
            alreadyFired: state.firedThresholds)
        {
            state.firedThresholds.formUnion(QuotaWarningNotificationLogic.firedThresholdsAfterWarning(
                threshold: threshold,
                thresholds: thresholds))
            self.postQuotaWarning(
                QuotaWarningEvent(
                    window: window,
                    threshold: threshold,
                    currentRemaining: currentRemaining,
                    accountDisplayName: accountDisplayName),
                provider: provider)
        }

        state.lastRemaining = currentRemaining
        self.quotaWarningState[key] = state
    }

    private func quotaWarningAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
