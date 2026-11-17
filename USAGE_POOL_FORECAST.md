# Usage pool forecast engine

`CodexBarCore` exposes a synchronous, deterministic engine with no UI, disk reads,
network requests, account switches or reset redemption. The UI supplies bytes from
its existing cache read and provider snapshots. No additional polling is needed.

## Observable outcomes

- Decode usage.json, sequence.json and umbrella.json into separate, sanitized tanks.
- Model weekly top-ups, reported session limits, automatic overflow and manual switches.
- Keep unreadable login scenarios separate and attach all assumptions to the result.
- Recommend banked Codex resets without consuming them or mixing purchased credits.
- Return own and acting runway, chronological events, waste and credit values.
- Calibrate sizes from valid solo stretches and use local demand history when convertible.
- Validate the morning fixture and boundary cases with focused Swift tests.

## UI integration API

- `UsagePoolClaudeCache.accounts(usage:sequence:umbrella:umbrellaState:now:calibratedCapacities:)`
  accepts the cache files as Data. The optional `umbrellaState` is the contents of
  `~/.claude-swap-backup/umbrella-state.json`. While the active slot is personal,
  its `chosen_work` pair identifies the hand-chosen work login. Match its email
  inside the decoder only. Slot IDs are `claude:cswap:N`.
  Display names use a nonempty alias, otherwise Personal or Work-N. Work numbering
  follows sorted work slots, excluding personal. Email addresses are used only
  inside the decoder to match umbrella membership and never enter exported state.
  An alias containing an email address falls back to the slot label.
- `UsagePoolForecast.codexAccount(snapshot:)` selects the explicitly weekly
  `RateWindow` from the existing `UsageSnapshot`. Pass its `codexResetCredits`
  separately to `forecast`. Purchased credits never participate.
- `UsagePoolForecast.forecast(provider:accounts:now:pace:scenarios:credits:history:kappa:continuationDays:)`
  returns a `Result`. Supply providers separately. `ownRunwayUntil` and
  `actingRunwayUntil` are first unmet-demand dates. Nil means coverage through
  `evaluatedUntil`, not infinite runway. The default continuation is 28 days.
- `Result.assumptions` applies to every nested number and timestamp. Keep it with
  any extracted display value: scenarios by account, daily pace/shape and source,
  size label, and manual effort cost. `comingUp` and `wasteByAccount` cover the
  first seven days; `redemptions` includes continuation. `unplannedCreditCount`
  reports summary-only credits whose details are unavailable, never invented expiry.
- `Pace.localHistory` consumes existing `CostUsageDailyReport.Entry` values for
  28 complete UTC days. Claude costNanos have already become costUSD at this
  boundary; Codex uses totalTokens. It estimates a weekday pattern, flat within
  each day. Missing days remain unknown. A measured conversion into tank capacity
  units is required. Without one, call `forecast` without a pace to use the active
  readable weekly window's used capacity divided by elapsed hours. Ignore windows
  younger than six hours, trying another readable account before reporting no pace.
- `calibratedCapacity(stretches:)` returns 100 times median spend/used-points,
  requiring at least three solo stretches with at least ten points and no top-up.
  Capacity and pace must share units. Default capacity is 100 points for every
  tank, labelled `size estimated`.
- `History` accepts 28-day demand and optional observed waste in the same units.
  Historical utilisation is absent without history. Waste-based utilisation stays
  absent without observed historical waste; forecast waste is never substituted.

## Policy and boundaries

The event search considers reachable tanks, ordered by discard risk then automatic
reach and earliest weekly top-up. It compares schedules lexicographically by unmet
capacity, then discarded capacity plus kappa times manual actions. Kappa defaults
to one hour at mean pace. Events include tank/session exhaustion, weekly top-ups,
reported session end, weekday demand changes and latest switch deadlines that can
consume capacity before a top-up. Search uses dominance pruning, not time steps.
The selected terminal state continues through successive seven-day horizons.
Each search has a 4096-node budget and starts with a complete greedy plan. When
the budget is exhausted it keeps the best complete plan found, so large pools
have bounded search effort without a guarantee of the global optimum.

The active work login is used automatically until its weekly tank is empty or its
reported session is at 100%. Only then is umbrella personal automatic overflow.
Overflow returns to the hand-chosen work login when its weekly tank tops up or its
session ends. Selecting personal while work is available costs a manual action
and emits a switch event, as does selecting another work login. A manual personal
selection persists until it empties or another login is selected.
Session percentages are never converted to weekly capacity units: below 100% they
do not constrain the forecast. A 100% session blocks only until its reported end;
sessions without a reset time are dropped. No new five-hour window is invented.
Scoped windows remain reported metadata:
model-specific demand is not available from daily aggregates.

Unreadable logins default to full only after a known top-up since their last good
reading and less than seven days of refusal, otherwise dead. Overrides select full,
last reading or dead independently, never average them. A dead login contributes
neither capacity nor future top-ups. A lastGood.fetchedAt timestamp takes precedence
over the reading's fetchedAt, which is usable only without lastError. Refusal age
uses lastAttemptAt. Missing evidence stays unknown and defaults to dead.
Last-reading scenarios keep the last balance and resume their known weekly top-ups.

Available Codex resets are ordered by expiry, with no-expiry resets last. Redeem
when empty or five minutes before expiry, whichever comes first, unless a natural
weekly top-up is due within the next hour. The action fills
the tank, discards its remainder and moves the weekly clock to action time plus
seven days. Zero-percent-used redemption has no value and does not move the clock.
Credit values are incremental capacity; `paceToUseBeforeExpiry` is percentage
points/hour at the time that credit first became next in the plan. Dead Codex
accounts cannot use credits. Already expired detailed credits are excluded from
planning and do not count as unknown, unplanned credits.

## Design fixture interpretation

The synthetic fixture uses 51 Claude points/day: 17 per work-equivalent
across three work logins. Sixty-six automatic points last until about Saturday 17:00,
consistent with the mockup's approximate 17:00. Seventeen total points/day would
instead last about 93 hours and cannot produce that headline.

The formal default makes Work-3 dead before its Monday top-up. With Work-2 full,
acting runway is about Monday 16:00, with a gap until Work-1 tops up at 19:00. Selecting
Work-3's last-reading scenario makes its Monday top-up usable and produces the
mockup's coverage past 19:00. The UI must retain that scenario qualification.

Codex at 32 points/day runs out on its own Sunday 12:05. Expiry at 23:21 minus
five minutes is 23:16, rather than the mockup's rounded 23:15. That reset is worth
50.91%, then the next two are worth 100% at Tuesday 10 November 02:16 and Friday
13 November 05:16. The resulting continuous runway reaches Monday 16 November
08:16. These tests follow the equations rather than rounding action deadlines.

## Remaining integration

TODO: connect existing accountBreakdowns/switch history to
solo stretches with exact quota deltas and evidence that no top-up occurred.
Daily per-account totals exist, but are not sufficient to prove solo activity or
the matching percentage movement. No per-login spend attribution is inferred.

TODO: retain observed top-up waste over 28 days before displaying
waste-based historical utilisation. Use a measured tokens-per-tank conversion for
Codex, or dollar capacities for Claude, before using raw demand aggregates.

## Pace position

`UsagePoolForecast.pacePosition(results:now:)` computes signed, capacity-weighted
used-minus-ideal usage across separate provider results. Positive is ahead,
negative is behind; the UI treats absolute deltas up to 0.10 as on pace.
`PacePosition` retains per-tank contributions, excluded account IDs and the
largest account contribution, grouping its banked resets under that account.

Ideal use is elapsed/window, using the reported clock of each login's current window.
The UI computes pace from readings and clocks alone (`poolPacePosition`) for both
providers. Banked Codex resets never move pace: they are capacity, not usage.
Unreadable logins count from their last reading, marked estimated. Only unknown
clocks are excluded explicitly. Credit worth remains the separate incremental value
from the forecast. See USAGE_POOL_UI.md for the morning fixture arithmetic.
