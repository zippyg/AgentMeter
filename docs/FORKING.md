# Forking and rebranding AgentMeter

AgentMeter ships under the reverse-DNS prefix `com.zain.agentmeter`. To run your own
build under your own identity, change the items below. They split into Swift code (one
constant covers most of it) and build configuration that a Swift constant cannot reach.

After any change here, run `swift test --filter AgentMeterIdentityTests` to see the pinned
identity expectations; update those expectations to your new prefix so the suite stays green.

## 1. Swift identity prefix (one place)

`Sources/CodexBarCore/AgentMeterIdentity.swift`

```swift
public static let bundlePrefix = "com.zain.agentmeter"
```

Everything derived from it follows automatically: the Keychain service, the cache service,
the App Group ids, the cross-process snapshot notification, and the log subsystem.

## 2. macOS app identity (kept explicit on purpose)

`Sources/CodexBar/AgentMeterProductIdentity.swift` hard-codes the menu-bar bundle id and the
status-item autosave name as literals, and keeps a list of previous identities for one-time
migration/cleanup. These are deliberately not derived: the macOS menu-bar item is sensitive to
identity churn, so the values are pinned and changed by hand.

- `bundleIdentifier` (currently `com.zain.agentmeter.menu`): your macOS app bundle id.
- `statusItemAutosaveRoot`: follows `bundleIdentifier`.
- `previous*` lists: only relevant if you are migrating an existing install; a clean fork can
  empty them.

This value must match `CFBundleIdentifier` in the packaged app (see
`Scripts/agentmeter_package_local_app.sh` and the macOS Info.plist) and your
Apple-registered bundle id. The package script wraps the existing release binary, so run
`swift build -c release --product AgentMeter` before packaging after Swift code changes.

## 3. iOS / widget / Live Activity

`AgentMeteriOS/project.yml`, the per-target `Info.plist`, and `*.entitlements`:

- iOS app + widget bundle ids (currently `com.zain.agentmeter.ios.dev*`).
- App Group (`group.com.zain.agentmeter`) in the entitlements must match
  `AgentMeterIdentity.releaseAppGroupID`.
- Keychain access group, if you enable one.

`AgentMeteriOS/AgentMeteriOS/AgentMeterBridgeClient.swift`:

- `keychainService` (`com.zain.agentmeter.ios.bridge`): the iPhone's stored pairing-token
  service. The iOS app is a separate target and does not import `AgentMeterIdentity`, so this
  is edited directly.

`Sources/CodexBar/AgentMeterLocalAutomationCommand.swift`:

- `defaultSimulatorBundleID` (`com.zain.agentmeter.ios.dev`): only used by the optional,
  off-by-default simulator pairing helper.

## 4. Release configuration

Release automation can use an uncommitted local environment file with your own repo, signing
identity / secret references, Sparkle public key, feed, and download URLs. Treat it as local
config: it should not carry private key bytes, and source-only use does not need it.

## 5. Display name and icons

- Display name `AgentMeter` lives in `AgentMeterProductIdentity.displayName`, the macOS
  Info.plist, and `AgentMeteriOS` config.
- App icon source: `AgentMeteriOS/Shared/Assets.xcassets/AppIcon.appiconset/AgentMeterIconSource.svg`.
  The macOS `Icon.icns` is regenerated from that SVG (rounded squircle).
- Menu-bar glyph: `Sources/CodexBar/Resources/AgentMeterMenuBarIcon.svg` (a template image:
  monochrome, with transparent cut-outs for the eyes).

## 6. Apple-side registration (for signed distribution)

Register your own bundle ids and App Group with your Apple Developer team, set the team id
(`AppGroupSupport.defaultTeamID` / the `AgentMeterTeamID` Info.plist key), and use your own
Developer ID for notarized macOS builds. Source-only use needs none of this.
