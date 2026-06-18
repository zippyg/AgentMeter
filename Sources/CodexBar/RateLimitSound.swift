import AppKit

enum RateLimitSoundLogic {
    /// Used-percent at or above which a tracked window counts as "rate limited".
    static let usedThreshold: Double = 99

    struct Decision: Equatable {
        let play: Bool
        let remembered: Double
    }

    /// Decide whether to play the alert. It fires once on the rising edge across the threshold and is
    /// silent on the first observation (`previousUsed == nil`), so launching while already maxed out
    /// stays quiet. `remembered` is the value to store for the next call.
    static func decision(
        previousUsed: Double?,
        currentUsed: Double,
        threshold: Double = usedThreshold) -> Decision
    {
        guard let previousUsed else {
            return Decision(play: false, remembered: currentUsed)
        }
        let wasOver = previousUsed >= threshold
        let isOver = currentUsed >= threshold
        return Decision(play: isOver && !wasOver, remembered: currentUsed)
    }

    static func clampVolume(_ value: Double) -> Float {
        Float(min(1, max(0, value)))
    }
}

@MainActor
final class RateLimitSoundPlayer {
    static let shared = RateLimitSoundPlayer()

    private lazy var sound: NSSound? = Self.loadSound()
    private var lastPlayedAt: Date?
    private static let minInterval: TimeInterval = 1.5

    /// XCTest links XCTest.framework; the shipping app does not. Stay silent under tests.
    private static let isTestEnvironment = NSClassFromString("XCTestCase") != nil

    func play(volume: Double, now: Date = Date()) {
        guard !Self.isTestEnvironment else { return }
        if let lastPlayedAt, now.timeIntervalSince(lastPlayedAt) < Self.minInterval { return }
        guard let sound else { return }
        self.lastPlayedAt = now
        sound.volume = RateLimitSoundLogic.clampVolume(volume)
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    static func resourceURL() -> URL? {
        self.resourceBundle?.url(forResource: "RateLimitAlert", withExtension: "mp3")
    }

    private static func loadSound() -> NSSound? {
        guard let url = resourceURL() else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }

    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        if let bundleURL = Bundle.main.url(forResource: "AgentMeter_AgentMeter", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        return Bundle.main
    }()
}
