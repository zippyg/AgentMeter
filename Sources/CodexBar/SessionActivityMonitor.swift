import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SessionActivityMonitor {
    typealias Handler = @MainActor (_ active: Bool, _ reason: String) -> Void

    private let notificationCenter: NotificationCenter
    private let activeStateProvider: @MainActor () -> Bool
    private var tokens: [NSObjectProtocol] = []
    private var handler: Handler?

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        activeStateProvider: @escaping @MainActor () -> Bool = SessionActivityMonitor.currentSessionIsActive)
    {
        self.notificationCenter = notificationCenter
        self.activeStateProvider = activeStateProvider
    }

    var isSessionActive: Bool {
        self.activeStateProvider()
    }

    func start(handler: @escaping Handler) {
        self.stop()
        self.handler = handler
        self.tokens = [
            self.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handler?(false, "session-resign")
                }
            },
            self.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handler?(self?.isSessionActive ?? true, "session-become-active")
                }
            },
        ]
    }

    func stop() {
        for token in self.tokens {
            self.notificationCenter.removeObserver(token)
        }
        self.tokens.removeAll()
        self.handler = nil
    }

    static func currentSessionIsActive() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool
        else {
            return true
        }
        return onConsole
    }
}
