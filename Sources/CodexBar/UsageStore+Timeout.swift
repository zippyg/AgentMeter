import Foundation

extension UsageStore {
    private final class ProbeTimeoutRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        private var result: String?
        private var tasks: [Task<Void, Never>] = []
        private var timers: [DispatchSourceTimer] = []

        func install(_ continuation: CheckedContinuation<String, Never>) {
            let result: String? = self.lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(returning: result)
            }
        }

        func install(_ task: Task<Void, Never>) {
            let shouldCancel = self.lock.withLock {
                guard self.result == nil else { return true }
                self.tasks.append(task)
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        func install(_ timer: DispatchSourceTimer) {
            let shouldCancel = self.lock.withLock {
                guard self.result == nil else { return true }
                self.timers.append(timer)
                return false
            }
            if shouldCancel {
                timer.cancel()
            }
        }

        func complete(with result: String) {
            let completion = self.lock.withLock {
                guard self.result == nil else {
                    return (
                        nil as CheckedContinuation<String, Never>?,
                        [] as [Task<Void, Never>],
                        [] as [DispatchSourceTimer])
                }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                let tasks = self.tasks
                self.tasks.removeAll()
                let timers = self.timers
                self.timers.removeAll()
                return (continuation, tasks, timers)
            }
            completion.1.forEach { $0.cancel() }
            completion.2.forEach { $0.cancel() }
            completion.0?.resume(returning: result)
        }
    }

    private nonisolated static let probeTimeoutQueue = DispatchQueue(
        label: "com.zain.agentmeter.probe-timeouts",
        qos: .userInitiated)

    nonisolated static func runWithTimeout(
        seconds: Double,
        operation: @escaping @Sendable () async -> String) async -> String
    {
        let timeoutMessage = "Probe timed out after \(Int(seconds))s"
        let race = ProbeTimeoutRace()
        let timeoutDelay = max(seconds, 0)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)

                race.install(Task(priority: .userInitiated) {
                    let result = await operation()
                    race.complete(with: result)
                })

                let timer = DispatchSource.makeTimerSource(queue: Self.probeTimeoutQueue)
                timer.schedule(deadline: .now() + timeoutDelay, leeway: .milliseconds(1))
                timer.setEventHandler {
                    race.complete(with: timeoutMessage)
                }
                timer.resume()
                race.install(timer)
            }
        } onCancel: {
            race.complete(with: timeoutMessage)
        }
    }
}
