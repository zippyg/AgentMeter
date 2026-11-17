import Foundation

/// Watches claude-swap's state folder so a login switch shows within a moment instead of at the next
/// provider refresh. It only notices changes; the caller re-reads the files it already reads.
/// The folder catches atomic replaces (write-new-then-rename); a second source on sequence.json
/// catches in-place writes. Events are coalesced, the file source is re-opened after a replace, and
/// a missing or replaced folder is re-attached: at once when possible, otherwise on a slow retry.
final class ClaudeSwapStateWatcher: @unchecked Sendable {
    private let directory: URL
    private let retryInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.zain.agentmeter.claude-swap-watch")
    private let onChange: @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var stopped = false
    static let debounce: TimeInterval = 0.25

    init(directory: URL, retryInterval: TimeInterval = 5, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.retryInterval = retryInterval
        self.onChange = onChange
        self.queue.async { [self] in self.attach(notify: false) }
    }

    deinit {
        self.stopped = true
        self.directorySource?.cancel()
        self.fileSource?.cancel()
        self.pending?.cancel()
        self.retry?.cancel()
    }

    /// Opens the folder source, or schedules another try while the folder is missing.
    private func attach(notify: Bool) {
        guard !self.stopped else { return }
        self.directorySource?.cancel()
        self.directorySource = self.makeSource(self.directory.path, mask: [.write, .rename, .delete]) { [weak self] event in
            guard let self else { return }
            // The folder itself moved or vanished: its descriptor is stale, so start over.
            if !event.isDisjoint(with: [.rename, .delete]) {
                self.attach(notify: true)
            } else {
                self.changed()
            }
        }
        self.openFileSource()
        if self.directorySource == nil {
            let work = DispatchWorkItem { [weak self] in self?.attach(notify: true) }
            self.retry = work
            self.queue.asyncAfter(deadline: .now() + self.retryInterval, execute: work)
        } else if notify {
            self.changed()
        }
    }

    private func openFileSource() {
        self.fileSource?.cancel()
        self.fileSource = self.makeSource(
            self.directory.appendingPathComponent("sequence.json").path, mask: [.write, .extend, .rename, .delete]
        ) { [weak self] _ in self?.changed() }
    }

    private func makeSource(
        _ path: String, mask: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject?
    {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: self.queue)
        source.setEventHandler { [weak source] in handler(source?.data ?? []) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func changed() {
        // A replaced sequence.json is a new file; follow it.
        self.openFileSource()
        self.pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        self.pending = work
        self.queue.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
