# Usage pool popover

## Observable outcomes

- Four tabs: Overview, Claude, Codex and Spend in a transient native NSPopover.
- AgentMeter mascot, bundled provider logos, existing coral and teal brand colours.
- macOS 26 glassEffect and GlassEffectContainer; NSVisualEffectView on older systems.
- Separate light/dark surfaces, increased-contrast borders and reduced-transparency surfaces.
- Overview pace, expiry banner, separate provider runways, seven-day timeline and chronological events.
- Claude per-login scenarios and roles, with only reported, unexpired five-hour sessions.
- Codex weekly usage, read-only banked reset deadlines, value, expiry and reserve assumptions.
- Spend today/7/28-day dollars and tokens, providers, daily rows, models and known logins.
- Existing hidePersonalInfo setting controls names, including forecasts and accessibility strings.
- Direct key events: 1 to 4, arrows, R, Escape and Command comma, scoped to the popover window.
- Menu bar earliest action and expiry dot; existing minute timer updates local forecasts without polling.

## Boundaries and interpretation

The UI consumes UsagePoolForecast public types only. No account switching
or reset redemption is added by the UI. Claude cache bytes are read during
its existing refresh, from the current user's .claude-swap-backup directory. No new
network request or timer polls a provider.

Pace uses used minus ideal used in weekly points, weighted by engine capacity. Ideal
used is the elapsed fraction of each login's current window, so steady means used
percent equals that fraction. Both providers use this one definition, from readings
and clocks alone. Banked Codex resets are extra capacity and never change pace.
Unknown credit clocks are not invented.

Pace excludes unreadable accounts and dead scenarios from both the denominator
and driver selection. Selected scenarios still affect the separate runway forecast.
Unknown weekly clocks are excluded explicitly. Sizes remain labelled estimated
until calibrated by the engine. Overall pace uses the provider with the largest
absolute deviation. Opposing provider deviations beyond ten percent display red
Mixed with both provider lines. Green requires every reported provider to be
within ten percent, including the boundary.

With the morning fixture, Codex is 18.396825 points ahead on its one weekly clock.
Its three banked resets add nothing to pace. Face-value pace and incremental
forecast reset worth are deliberately distinct values.

## Validation

Commands, output, rendered PNG paths and remaining unverified outcomes are recorded
in .build/usage-pool-validation/ui-validation.md after the final checks.

No dependency was added. Native SwiftUI, AppKit and the installed package are used.

## Engine integration

A fixture with Work-3 set to Full once crashed the old forecast search. The bounded
search fixed it without changing the UI's public API boundary, and the
fullWork3ScenarioEngineReproducer test guards it.
The UI cache reader also supplies the new optional umbrella-state bytes so
personal overflow preserves the hand-chosen work login.

## Verified fixture and remaining checks

The morning quota fixture now excludes unreadable Work-2 and Work-3 from pace:
Claude is Fast by 25 points, driven by reachable Personal, and Codex is Fast by 18.
Overall displays Fast. Scenario choices remain available for runway planning.
Spend uses entirely synthetic daily usage counters with invented login labels.
No price is inferred from a daily total token count. Daily rows display newest first.
The fixture is Tests/CodexBarTests/Fixtures/usage-pool-spend-synthetic.json.

Sixteen native offscreen captures are under .build/ui-review: each tab in light,
dark, light increased contrast and dark increased contrast. ImageRenderer omitted
AppKit-backed controls, so the review harness uses NSHostingView in a window that
is never ordered or activated. Explicit appearance foregrounds keep glass text
legible in both themes. The failed ImageRenderer attempt is archived separately.

The earlier broader run failed its three-second six-account timeout. The search
repeated calendar-day walks even for flat demand. Flat demand now uses exact
arithmetic for its latest-start deadline and skips weekday calendar lookups.
The search budget and three-second assertion are unchanged. Variable weekday
profiles retain the existing calendar calculation.

The popover releases its reference after close, ignores open requests after
shutdown, and has offscreen lifecycle coverage through an injected native popover.
Final check results and any native runtime limits are recorded in the validation
report. Live glass, VoiceOver, older materials and installed-app diagnostics still
require runtime verification.

The exact commands, logs, complete file/commit list and PNG paths are in
.build/usage-pool-validation/ui-validation.md. An independent review should cover
UsagePoolPace, UsagePoolPopoverView and the status-item integration before release.
