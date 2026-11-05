# Claude accounts and upstream maintenance

## Sources and scope

AgentMeter's inherited upstream is https://github.com/steipete/CodexBar, remote
`codexbar-upstream`. claude-swap lives at https://github.com/realiti4/claude-swap.

The supplied 19 September 2026 comparison reports 3199 upstream commits since the
common ancestor `1033a6ad2` (14 June 2026). The comparison target is `e30054646`,
"docs: prepare CodexBar 0.62.0 release". Both objects are present locally. No merge,
cherry-pick, fetch, commit or push was performed for this change.

For a later sync, fetch `codexbar-upstream`, inspect the diff from those anchors in
an isolated worktree, select individual fixes, and cherry-pick only reviewed
commits. Preserve AgentMeter's bundle identity, status-item recovery veto, bridge
privacy and iOS schema. Rebuild and rerun focused tests after each group.

Promising areas visible in the cached upstream history:

- Claude account history, measurement timestamps, outage retention and privacy labels.
- Verified per-account widget pins and quota-aligned local cost history.
- Codex workspace-scoped credit reconciliation and selected-workspace ownership.
- Claude probe isolation, web-session recovery and OAuth refresh handling.

The optional `scoped`, `spend` and `lastGoodFetchedAt` shapes below were checked
against `e30054646:Sources/CodexBarCore/Providers/Claude/ClaudeSwap/ClaudeSwapAccountList.swift`.
This is schema evidence, not a live cswap verification or the broader upstream sync.

## Feed contract

`ClaudeSwapUsage` searches PATH and the current user's `.local/bin`, `.bun/bin`,
plus `/opt/homebrew/bin` and `/usr/local/bin`. It runs only the fixed argv
`["list", "--json"]`, with null stdin, a 30-second timeout and the existing
subprocess runner's bounded output capture. It does not switch accounts, inspect
credential storage, log raw output or persist the source's email, alias or errors.
The brief specifies `list`; upstream's adapter uses `--list`. Verify command
compatibility against the installed binary during the separately authorized live check.

Required top-level fields: `schemaVersion: 1`, `accounts: [...]`. Each row must
have a unique positive integer `number`. `activeAccountNumber` and row `active`
flags establish CLI activity; conflicting or missing evidence yields unknown.
Optional `usageStatus`, `disabled`, `usageFetchedAt`, `usageAgeSeconds`,
`lastGoodUsage` and `lastGoodFetchedAt` control freshness and availability.

- `usage.fiveHour` and `usage.sevenDay`: `{pct, resetsAt?}`.
- `usage.scoped`: `[{name, pct, resetsAt?}]` for per-model quotas.
- `usage.spend`: `{used, limit, currency?, resetsAt?}`. Positive limits and finite,
  nonnegative amounts are required. Upstream's absent-currency default is USD.
- Unknown fields are ignored. Missing quotas or spend stay absent, never zero-filled.
- Invalid feeds preserve prior account windows as stale and clear the active flag.
  No previous feed means an explicit error entry. Raw errors are replaced by a safe message.
- A missing executable or an empty registered-account list resumes the legacy
  single-account provider path. No additional sign-in is introduced.

Disabled accounts remain listed as unavailable. Cached usage remains stale even
when returned by a new list call; source measurement dates are retained. Account
labels are deliberately `Account N`, matching cswap slot numbers. Plans and seat
names are not inferred from account order. No provider-level token history, spend
or identity is copied into another account's card.

## Snapshot and display contract

Summary and phone snapshots now emit schema version 3. `providers` stays an array.
Claude account entries have unique IDs `claude:cswap:N`, `providerID: "claude"`,
`accountID: "cswap:N"`, `accountLabel: "Account N"` and optional `isActiveCLI`.
The legacy `claude` and `codex` entries retain their IDs. Added fields decode as
optional, so new consumers continue reading versions 1 and 2.

Both writers carry monetary `spend` when supplied by the provider, and Codex
`creditsRemaining` and `creditsUsed` when reported. `creditsUsed` sums the returned
credit-history events, not a billing month or a currency amount. An empty history
means unknown, not zero spend. Local token-cost estimates are separate.

The Mac overview and Claude tab show each account and its active marker. The iOS
projection now groups by provider family without discarding account entries. The
dashboard and large widget expose separate accounts and available spend. Small
and medium widgets use compact rows when three accounts are present. The expanded
Live Activity keeps every account; the narrow Dynamic Island Claude slot selects
the active Claude account. Old iOS builds filter the new Claude IDs out, so rebuild
and install the accompanying iOS app/widget before relying on multi-account sync.

## Rebuild and reinstall

From the reviewed AgentMeter source checkout, with ordinary build permissions:

```sh
swift build -c release --product AgentMeter
Scripts/agentmeter_package_local_app.sh
Scripts/agentmeter_install_local_artifact.sh
Scripts/agentmeter_verify_local_app.sh /Applications/AgentMeter.app
```

Packaging does not compile. Always build release first. The installer selects the
newest release artifact, archives the prior installation and installs the shared
`/Applications/AgentMeter.app`. Quit AgentMeter in both sessions first; the
installer refuses replacement while another user's instance is running. Each
user then launches the shared app in their own session. Do not copy user data or
credentials between accounts. Rebuild the iOS app from `AgentMeteriOS.xcodeproj`.

This implementation lane does not install, launch the app, run cswap or access the
other account. Live cswap output, labels, per-model/spend availability and packaged
UI layout still require an authorized check in the account where cswap is installed.


## Validation on 19 September 2026

The Mac product builds. Focused coverage includes 35 tests for cswap parsing,
account isolation, missing-feed fallback, stale/error handling, overview rows,
spend and both writers, plus five Codex account-projection regression tests.
The phone's new projection/round-trip XCTest also passes in a standalone macOS
harness compiling the actual shared iOS model. Both iOS app and widget Swift
modules compile for the simulator SDK with Swift 6.

A full iOS Xcode build could not finish: asset compilation reports
`No available simulator runtimes for platform iphonesimulator`. A broader Codex
menu-interaction run did not finish its `fresh menu open` test; the five isolated
projection tests did finish. These results do not verify packaged UI or devices.

The worktree initially had no build cache. An ordinary build failed on the
compiler's external cache path, then dependency downloads failed DNS resolution.
Existing dependency checkouts and artifacts were copied from the sibling
worktree into this worktree's ignored `.build` directory. Successful builds/tests
used these flags, without changing Package.swift or Package.resolved:

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --disable-keychain --disable-experimental-prebuilts \
  --disable-automatic-resolution --cache-path "$PWD/.build/cache" --product AgentMeter
swift test --disable-sandbox --disable-keychain --disable-experimental-prebuilts \
  --disable-automatic-resolution --cache-path "$PWD/.build/cache" \
  --filter 'ClaudeSwapUsageTests|UsageStoreClaudeSwapTests|AgentMeterSnapshotTests|UsageStoreWidgetSnapshotTests|AgentMeterMenuSummaryTests'
```

Here `--disable-sandbox` disables SwiftPM's nested build sandbox, not the lane's
filesystem restrictions. Logs are retained locally in `.build/validation/`.

At final verification, `command -v cswap` resolved the current user's
`.local/bin/cswap`, contrary to the brief's earlier absence report. It was not
executed or installed by this lane. The absent-feed test injects nil rather than
running a live binary. No credentials or other-account files were accessed.
