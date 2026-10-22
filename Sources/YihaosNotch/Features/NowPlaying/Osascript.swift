import Foundation

/// Runs AppleScript in an `osascript` child process, so a slow or hung player can
/// never block the UI. Automation permission is attributed to this app.
enum Osascript {
    /// Returns trimmed stdout, or nil if the script fails. The child process is
    /// terminated if it runs past `deadline` seconds or the calling task is cancelled.
    static func run(_ source: String, deadline: Double = 5) async -> String? {
        if Task.isCancelled { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let reader = stdout.fileHandleForReading
        let state = RunState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.begin(continuation)
                // The pipe is drained only here, as data arrives: a child that filled the
                // pipe buffer would otherwise block forever. The result is delivered once
                // both end-of-file and process exit have been seen, so no trailing output
                // can be lost between the two.
                reader.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.sawEndOfFile()
                    } else {
                        state.append(chunk)
                    }
                }
                process.terminationHandler = { proc in
                    state.exited(success: proc.terminationStatus == 0 && proc.terminationReason == .exit)
                }
                // Cancellation may have arrived while we were setting up.
                guard !state.isCancelled else {
                    reader.readabilityHandler = nil
                    state.fail()
                    return
                }
                do {
                    try process.run()
                } catch {
                    reader.readabilityHandler = nil
                    state.fail()
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            state.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    /// AppleScript numbers come back in the user's locale ("12,5" in some regions).
    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// Collects output and resumes the caller exactly once.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var endOfFile = false
        private var exitSuccess: Bool?
        private var cancelled = false
        private var finished = false
        private var continuation: CheckedContinuation<String?, Never>?

        var isCancelled: Bool { lock.withLock { cancelled } }

        func begin(_ continuation: CheckedContinuation<String?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func append(_ chunk: Data) {
            lock.withLock { output.append(chunk) }
        }

        func sawEndOfFile() {
            lock.withLock { endOfFile = true }
            finishIfReady()
        }

        func exited(success: Bool) {
            lock.withLock { exitSuccess = success }
            finishIfReady()
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }

        func fail() {
            resume(with: nil)
        }

        private func finishIfReady() {
            let result: String?? = lock.withLock {
                guard endOfFile, let exitSuccess else { return .none }
                guard exitSuccess else { return .some(nil) }
                let text = String(decoding: output, as: UTF8.self)
                return .some(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let result { resume(with: result) }
        }

        private func resume(with result: String?) {
            let pending: CheckedContinuation<String?, Never>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: result)
        }
    }
}
