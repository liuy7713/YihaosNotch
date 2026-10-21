import Foundation

/// Runs AppleScript in an `osascript` child process, so a slow or hung player can
/// never block the UI. Automation permission is attributed to this app.
enum Osascript {
    /// Returns trimmed stdout, or nil if the script fails. The child process is
    /// terminated if it runs past `deadline` seconds or the calling task is cancelled.
    static func run(_ source: String, deadline: Double = 5) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let reader = stdout.fileHandleForReading
        let output = OutputBuffer()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Drain the pipe as data arrives; a child that filled the pipe buffer
                // would otherwise block forever and never terminate.
                reader.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil } else { output.append(chunk) }
                }
                process.terminationHandler = { proc in
                    reader.readabilityHandler = nil
                    output.append(reader.readDataToEndOfFile())
                    guard proc.terminationStatus == 0, proc.terminationReason == .exit else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let text = String(decoding: output.data, as: UTF8.self)
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                do {
                    try process.run()
                } catch {
                    reader.readabilityHandler = nil
                    continuation.resume(returning: nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// AppleScript numbers come back in the user's locale ("12,5" in some regions).
    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.withLock { storage.append(chunk) }
        }

        var data: Data { lock.withLock { storage } }
    }
}
